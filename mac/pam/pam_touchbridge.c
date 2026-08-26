/*
 * pam_touchbridge.c — TouchBridge PAM module
 *
 * Connects to the TouchBridge daemon via a Unix domain socket and
 * requests biometric authentication on the user's paired iOS device.
 *
 * PAM config line:
 *   auth  sufficient  pam_touchbridge.so [timeout=15] [ignore_ssh]
 *
 * If "sufficient", a successful TouchBridge auth skips the password prompt.
 * If TouchBridge fails (timeout, no device, etc.), PAM falls through to
 * the next module (typically password).
 *
 * Security notes:
 * - Never logs nonces, keys, or passwords
 * - Socket path derived from target user's home directory (not env vars)
 * - Fixed-size buffers prevent overflow
 * - All socket fds closed on all code paths
 */

#include "pam_touchbridge.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <errno.h>
#include <syslog.h>

/*
 * Escape a string for safe inclusion in a JSON string value.
 * Escapes: " \ / \b \f \n \r \t and U+0000–U+001F as \uXXXX.
 * Writes the escaped output to `out` (at most outlen-1 chars + NUL).
 * Returns the number of bytes written (excluding NUL), or -1 if the
 * output buffer is too small.
 */
static int json_escape(const char *in, char *out, size_t outlen)
{
    size_t i = 0;

    if (outlen == 0) return -1;

    for (const char *p = in; *p != '\0'; p++) {
        unsigned char c = (unsigned char)*p;
        const char *esc = NULL;
        char ubuf[8];

        switch (c) {
            case '"':  esc = "\\\""; break;
            case '\\': esc = "\\\\"; break;
            case '\b': esc = "\\b";  break;
            case '\f': esc = "\\f";  break;
            case '\n': esc = "\\n";  break;
            case '\r': esc = "\\r";  break;
            case '\t': esc = "\\t";  break;
            default:
                if (c < 0x20) {
                    snprintf(ubuf, sizeof(ubuf), "\\u%04x", c);
                    esc = ubuf;
                }
                break;
        }

        if (esc != NULL) {
            size_t len = strlen(esc);
            if (i + len >= outlen) return -1;
            memcpy(out + i, esc, len);
            i += len;
        } else {
            if (i + 1 >= outlen) return -1;
            out[i++] = (char)c;
        }
    }

    out[i] = '\0';
    return (int)i;
}

/*
 * Send an info message to the user's terminal via PAM conversation.
 * This is how PAM modules display "Check your phone..." type messages.
 */
static void pam_notify(pam_handle_t *pamh, const char *msg)
{
    const struct pam_conv *conv = NULL;
    struct pam_message pmsg;
    const struct pam_message *pmsgp = &pmsg;
    struct pam_response *resp = NULL;

    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS
        || conv == NULL || conv->conv == NULL) {
        return;
    }

    pmsg.msg_style = PAM_TEXT_INFO;
    pmsg.msg = (char *)msg;

    conv->conv(1, &pmsgp, &resp, conv->appdata_ptr);

    if (resp != NULL) {
        free(resp);
    }
}

/* Maximum sizes */
#define MAX_SOCK_PATH  256
#define MAX_REQUEST    512
#define MAX_RESPONSE   512
#define DEFAULT_TIMEOUT 15

/*
 * Build the socket path for the target user.
 * Path: <homedir>/Library/Application Support/TouchBridge/daemon.sock
 */
static int build_socket_path(const char *username, char *path, size_t pathlen)
{
    struct passwd *pw = getpwnam(username);
    if (pw == NULL) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: getpwnam failed for user %s", username);
        return -1;
    }

    int ret = snprintf(path, pathlen,
        "%s/Library/Application Support/TouchBridge/daemon.sock",
        pw->pw_dir);

    if (ret < 0 || (size_t)ret >= pathlen) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket path too long");
        return -1;
    }

    return 0;
}

/*
 * Parse the timeout=N argument from PAM module arguments.
 * Returns the timeout in seconds, or DEFAULT_TIMEOUT if not specified.
 */
static int parse_timeout(int argc, const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= 300) {
                return t;
            }
        }
    }
    return DEFAULT_TIMEOUT;
}

/*
 * Parse the ignore_ssh argument from PAM module arguments.
 * When enabled, the module skips TouchBridge auth when invoked over SSH
 * (checks SSH_CLIENT, SSH_CONNECTION, SSH_TTY env vars) and falls through
 * to the next PAM module (typically password).
 * Returns 1 if ignore_ssh is enabled, 0 otherwise.
 */
static int parse_ignore_ssh(int argc, const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "ignore_ssh") == 0) {
            return 1;
        }
    }
    return 0;
}

/*
 * Check if the current session is an SSH session by examining environment
 * variables set by sshd. Returns 1 if over SSH, 0 otherwise.
 */
static int is_ssh_session(void)
{
    /* sshd sets these in the PAM environment */
    if (getenv("SSH_CLIENT") != NULL) return 1;
    if (getenv("SSH_CONNECTION") != NULL) return 1;
    if (getenv("SSH_TTY") != NULL) return 1;
    return 0;
}

/*
 * Connect to the daemon's Unix domain socket.
 * Returns the socket fd on success, -1 on failure.
 */
static int connect_to_daemon(const char *sock_path, int timeout_sec)
{
    int fd = -1;
    struct sockaddr_un addr;
    struct timeval tv;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket() failed: %s", strerror(errno));
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: socket path too long");
        close(fd);
        return -1;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        syslog(LOG_AUTH | LOG_WARNING,
            "pam_touchbridge: connect failed: %s (daemon may not be running)",
            strerror(errno));
        close(fd);
        return -1;
    }

    /* Set receive timeout with a 2s grace margin over the daemon's auth
     * window (both default to 15s). Without the margin they race: PAM can
     * give up at the exact moment the daemon sends its result, losing an
     * approval that already happened. */
    tv.tv_sec = timeout_sec + 2;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    return fd;
}

/*
 * pam_sm_authenticate — main authentication entry point.
 *
 * Connects to the TouchBridge daemon socket, sends an auth request,
 * and waits for the daemon to verify the user via their companion device.
 */
PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    const char *user = NULL;
    const char *service = NULL;
    char sock_path[MAX_SOCK_PATH];
    char request[MAX_REQUEST];
    char response[MAX_RESPONSE];
    int fd = -1;
    int ret = PAM_AUTH_ERR;
    int timeout_sec;
    ssize_t bytes;

    (void)flags; /* unused */

    /* Get the target username */
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: failed to get username");
        return PAM_AUTH_ERR;
    }

    /* Get the PAM service name */
    if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS
        || service == NULL) {
        service = "unknown";
    }

    /* Parse timeout from module arguments */
    timeout_sec = parse_timeout(argc, argv);

    /* Check ignore_ssh policy */
    int ignore_ssh = parse_ignore_ssh(argc, argv);
    if (ignore_ssh && is_ssh_session()) {
        syslog(LOG_AUTH | LOG_INFO,
            "pam_touchbridge: SSH session detected, ignore_ssh enabled — falling through for user=%s",
            user);
        return PAM_AUTH_ERR;
    }

    syslog(LOG_AUTH | LOG_INFO,
        "pam_touchbridge: auth request for user=%s service=%s timeout=%d",
        user, service, timeout_sec);

    /* Build socket path from the target user's home directory */
    if (build_socket_path(user, sock_path, sizeof(sock_path)) != 0) {
        goto cleanup;
    }

    /* Connect to daemon */
    fd = connect_to_daemon(sock_path, timeout_sec);
    if (fd < 0) {
        pam_notify(pamh, "TouchBridge: daemon not running — falling through to password");
        goto cleanup;
    }

    pam_notify(pamh, "TouchBridge: check your phone or watch...");

    /* Build JSON request with proper escaping of user-controlled strings.
     * Without escaping, a username containing " or \ could break the JSON
     * payload sent to the daemon (defense-in-depth — macOS usernames are
     * typically restricted, but this prevents injection if restrictions
     * are ever loosened or bypassed). */
    char escaped_user[256];
    char escaped_service[256];

    if (json_escape(user, escaped_user, sizeof(escaped_user)) < 0) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: username too long to escape");
        goto cleanup;
    }
    if (json_escape(service, escaped_service, sizeof(escaped_service)) < 0) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: service name too long to escape");
        goto cleanup;
    }

    bytes = snprintf(request, sizeof(request),
        "{\"action\":\"authenticate\",\"user\":\"%s\",\"service\":\"%s\",\"pid\":%d}\n",
        escaped_user, escaped_service, getpid());

    if (bytes < 0 || (size_t)bytes >= sizeof(request)) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: request too large");
        goto cleanup;
    }

    /* Send request */
    if (send(fd, request, (size_t)bytes, 0) != bytes) {
        syslog(LOG_AUTH | LOG_ERR, "pam_touchbridge: send failed: %s", strerror(errno));
        goto cleanup;
    }

    /* Receive response */
    memset(response, 0, sizeof(response));
    bytes = recv(fd, response, sizeof(response) - 1, 0);

    if (bytes <= 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            syslog(LOG_AUTH | LOG_WARNING,
                "pam_touchbridge: timeout waiting for companion device");
            pam_notify(pamh, "TouchBridge: timed out — no response from phone");
        } else {
            syslog(LOG_AUTH | LOG_ERR,
                "pam_touchbridge: recv failed: %s", strerror(errno));
            pam_notify(pamh, "TouchBridge: connection error");
        }
        goto cleanup;
    }

    response[bytes] = '\0';

    /* Check for success — simple string search, no JSON parser needed */
    if (strstr(response, "\"result\":\"success\"") != NULL) {
        syslog(LOG_AUTH | LOG_INFO,
            "pam_touchbridge: authentication succeeded for user=%s", user);
        pam_notify(pamh, "TouchBridge: ✓ authenticated");
        ret = PAM_SUCCESS;
    } else {
        syslog(LOG_AUTH | LOG_INFO,
            "pam_touchbridge: authentication failed for user=%s service=%s reason=%s",
            user, service, response);

        /*
         * Show a reason-specific message so the user knows what happened
         * and what to do, rather than a generic "denied" for all failures.
         */
        if (strstr(response, "\"key_invalidated\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ signing key invalid — open TouchBridge on your "
                "phone and re-pair (Settings → Unpair → Pair)");
        } else if (strstr(response, "\"invalid_signature\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ signature verification failed — try again or re-pair");
        } else if (strstr(response, "\"challenge_expired\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ request timed out on phone — try again");
        } else {
            pam_notify(pamh, "TouchBridge: ✗ denied — falling through to password");
        }
        ret = PAM_AUTH_ERR;
    }

cleanup:
    if (fd >= 0) {
        close(fd);
    }
    return ret;
}

/*
 * pam_sm_setcred — credential management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

/*
 * pam_sm_acct_mgmt — account management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
