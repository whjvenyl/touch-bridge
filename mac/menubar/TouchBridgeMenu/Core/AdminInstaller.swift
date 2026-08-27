import Foundation

/// Fallback installer for builds that cannot use SMAppService.daemon.
///
/// SMAppService.daemon requires the app and helper to share a Team ID inside
/// the same signed bundle. Ad-hoc signed builds (CODE_SIGN_IDENTITY="-") have
/// no Team ID, so `SMAppService.daemon(...).register()` fails.
///
/// This fallback uses the Security framework's `AuthorizationCopyRights` API
/// (via `PrivilegedTask`), which shows a native macOS admin-password dialog
/// and runs the privileged commands as root. It works with ad-hoc signing
/// and provides the same install/uninstall functionality as the privileged
/// helper.
///
/// When the app is properly signed with a Developer ID (for distribution), the
/// SMAppService path is preferred because it avoids repeated password prompts.
enum AdminInstaller {

    // MARK: - Install

    /// Install TouchBridge system components via an admin-privileged shell script.
    /// - Parameters:
    ///   - daemonPath: Path to the bundled daemon binary to copy to /usr/local/bin/
    ///   - pamModulePath: Path to the bundled PAM module to copy to /usr/local/lib/pam/
    ///   - patchSudo: Whether to patch the sudo PAM config
    ///   - patchScreensaver: Whether to patch the screensaver PAM config
    ///   - ignoreSSH: Whether to add the ignore_ssh flag to the PAM line
    /// - Returns: (success, message)
    static func install(daemonPath: String,
                        pamModulePath: String,
                        patchSudo: Bool,
                        patchScreensaver: Bool,
                        ignoreSSH: Bool) async -> (success: Bool, message: String) {
        let pamLine = ignoreSSH
            ? "auth       sufficient     pam_touchbridge.so ignore_ssh"
            : "auth       sufficient     pam_touchbridge.so"

        var commands: [String] = []

        // 1. Copy daemon binary
        if !daemonPath.isEmpty && FileManager.default.fileExists(atPath: daemonPath) {
            commands.append("mkdir -p /usr/local/bin")
            commands.append("rm -f /usr/local/bin/touchbridge")
            commands.append("cp '\(shellEscape(daemonPath))' /usr/local/bin/touchbridge")
            commands.append("chmod 755 /usr/local/bin/touchbridge")
        }

        // 2. Copy PAM module
        if FileManager.default.fileExists(atPath: pamModulePath) {
            commands.append("mkdir -p /usr/local/lib/pam")
            commands.append("rm -f /usr/local/lib/pam/pam_touchbridge.so")
            commands.append("cp '\(shellEscape(pamModulePath))' /usr/local/lib/pam/pam_touchbridge.so")
            commands.append("chmod 444 /usr/local/lib/pam/pam_touchbridge.so")
            // Ad-hoc sign the PAM module at its final location (after copy)
            // so the code signature mtime matches the file mtime. Signing
            // before copying causes a cs_mtime mismatch that AMFI rejects.
            commands.append("codesign -s - --force /usr/local/lib/pam/pam_touchbridge.so 2>/dev/null || true")
        }

        // 3. Patch sudo PAM config
        if patchSudo {
            commands.append(patchSudoScript(line: pamLine))
        }

        // 4. Patch screensaver PAM config
        if patchScreensaver {
            commands.append(patchPAMFileDirectlyScript(file: "/etc/pam.d/screensaver", line: pamLine))
        }

        // 5. Create app support and log directories for the current user
        let home = NSHomeDirectory()
        let appSupport = "\(home)/Library/Application Support/TouchBridge"
        let logDir = "\(home)/Library/Logs/TouchBridge"
        commands.append("mkdir -p '\(shellEscape(appSupport))'")
        commands.append("chmod 700 '\(shellEscape(appSupport))'")
        commands.append("mkdir -p '\(shellEscape(logDir))'")

        return await runAdminScript(commands)
    }

    // MARK: - Uninstall

    /// Uninstall TouchBridge system components via an admin-privileged shell script.
    /// - Parameter removeBinary: Whether to also remove /usr/local/bin/touchbridge
    /// - Returns: (success, message)
    static func uninstall(removeBinary: Bool) async -> (success: Bool, message: String) {
        var commands: [String] = []

        // 1. Remove PAM hooks (BEFORE removing the module to avoid lockout)
        commands.append(removeSudoHookScript())
        commands.append(restorePAMFileScript(file: "/etc/pam.d/screensaver"))

        // 2. Remove PAM module
        commands.append("rm -f /usr/local/lib/pam/pam_touchbridge.so")

        // 3. Optionally remove daemon binary
        if removeBinary {
            commands.append("rm -f /usr/local/bin/touchbridge")
        }

        return await runAdminScript(commands)
    }

    // MARK: - Admin script execution

    /// Run a list of shell commands with administrator privileges via the
    /// Security framework. Shows a native macOS admin-password dialog.
    private static func runAdminScript(_ commands: [String]) async -> (success: Bool, message: String) {
        return await PrivilegedTask.run(commands)
    }

    // MARK: - PAM patching scripts (mirrors pam-common.sh logic)

    /// Build a shell script fragment that patches the sudo PAM config.
    /// Uses /etc/pam.d/sudo_local on Sonoma+ (unprotected, safe), falls back
    /// to editing /etc/pam.d/sudo directly with a backup.
    private static func patchSudoScript(line: String) -> String {
        let escapedLine = shellEscape(line)
        // Check if sudo includes sudo_local; if so, write to sudo_local (safe).
        // Otherwise, do a direct edit of /etc/pam.d/sudo with backup.
        return """
        if grep -qE '^[[:space:]]*auth[[:space:]]+include[[:space:]]+sudo_local' /etc/pam.d/sudo 2>/dev/null; then \
            if ! grep -q 'pam_touchbridge' /etc/pam.d/sudo_local 2>/dev/null; then \
                tmp=$(mktemp); printf '%s\\n' '\(escapedLine)' > "$tmp"; \
                [ -f /etc/pam.d/sudo_local ] && cat /etc/pam.d/sudo_local >> "$tmp"; \
                cat "$tmp" > /etc/pam.d/sudo_local; rm -f "$tmp"; chmod 644 /etc/pam.d/sudo_local; \
            fi \
        else \
            \(patchPAMFileDirectlyScript(file: "/etc/pam.d/sudo", line: line)); \
        fi
        """
    }

    /// Build a shell script fragment that directly edits a PAM file:
    /// backs up the original, inserts our line before the first "auth" line.
    private static func patchPAMFileDirectlyScript(file: String, line: String) -> String {
        let escapedLine = shellEscape(line)
        let escapedFile = shellEscape(file)
        return """
        if [ -f '\(escapedFile)' ] && ! grep -q 'pam_touchbridge' '\(escapedFile)'; then \
            cp '\(escapedFile)' '\(escapedFile).touchbridge-backup' 2>/dev/null || true; \
            tmp=$(mktemp); inserted=0; \
            while IFS= read -r l; do \
                if [ $inserted -eq 0 ] && echo "$l" | grep -q '^auth'; then \
                    echo '\(escapedLine)' >> "$tmp"; inserted=1; \
                fi; \
                echo "$l" >> "$tmp"; \
            done < '\(escapedFile)'; \
            [ $inserted -eq 0 ] && echo '\(escapedLine)' >> "$tmp"; \
            cat "$tmp" > '\(escapedFile)'; rm -f "$tmp"; \
        fi
        """
    }

    /// Build a shell script fragment that removes the sudo PAM hook.
    /// Removes our line from sudo_local (deleting the file if empty) and
    /// restores /etc/pam.d/sudo from backup if one exists.
    private static func removeSudoHookScript() -> String {
        return """
        if [ -f /etc/pam.d/sudo_local ] && grep -q 'pam_touchbridge' /etc/pam.d/sudo_local 2>/dev/null; then \
            tmp=$(mktemp); grep -v 'pam_touchbridge' /etc/pam.d/sudo_local > "$tmp" 2>/dev/null || true; \
            if grep -qE '[^[:space:]]' "$tmp" 2>/dev/null; then \
                cat "$tmp" > /etc/pam.d/sudo_local; \
            else \
                rm -f /etc/pam.d/sudo_local; \
            fi; \
            rm -f "$tmp"; \
        fi; \
        \(restorePAMFileScript(file: "/etc/pam.d/sudo"))
        """
    }

    /// Build a shell script fragment that restores a PAM file from backup,
    /// or strips our line if no backup exists.
    private static func restorePAMFileScript(file: String) -> String {
        let escapedFile = shellEscape(file)
        let backup = "\(escapedFile).touchbridge-backup"
        return """
        if [ -f '\(backup)' ]; then \
            cp '\(backup)' '\(escapedFile)'; rm -f '\(backup)'; \
        elif [ -f '\(escapedFile)' ] && grep -q 'pam_touchbridge' '\(escapedFile)' 2>/dev/null; then \
            tmp=$(mktemp); grep -v 'pam_touchbridge' '\(escapedFile)' > "$tmp" 2>/dev/null || true; \
            cat "$tmp" > '\(escapedFile)'; rm -f "$tmp"; \
        fi
        """
    }

    // MARK: - Shell escaping

    /// Escape a string for use inside single quotes in a shell script.
    /// Single quotes themselves are escaped via the '\'' sequence.
    private static func shellEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
