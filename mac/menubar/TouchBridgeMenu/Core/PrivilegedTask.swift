import Foundation

/// Runs shell commands with administrator privileges.
///
/// On macOS 26 (Tahoe) and later, `do shell script ... with administrator
/// privileges` (the `NSAppleScript` / `AuthorizationCopyRights` path) is
/// blocked from writing to protected system directories such as
/// `/etc/pam.d/`.  Every attempt fails with `EPERM` ("Operation not
/// permitted") even though the process is running as root.
///
/// To work around this we use `sudo -A` with a custom askpass helper.
/// `sudo -A` reads the password from an askpass program (set via the
/// `SUDO_ASKPASS` environment variable) instead of the terminal.  Our
/// askpass helper shows a native `osascript` password dialog, so the user
/// experience is the same as before — a system-style password prompt —
/// but the actual privileged work is performed by `sudo`, which has
/// unrestricted root access.
///
/// When the app is signed with a Developer ID, the `HelperClient` /
/// `SMAppService` path is preferred because it avoids repeated password
/// prompts.
enum PrivilegedTask {

    // MARK: - Run

    /// Run a list of shell commands with administrator privileges.
    ///
    /// Commands are joined with `;` and executed as a single script by
    /// `/bin/sh` via `sudo -A`.  The user sees a native dialog asking for
    /// an admin password (shown by the askpass helper).
    ///
    /// - Parameter commands: Shell commands to execute as root.
    /// - Returns: `(success, message)` where message is stdout on success
    ///   or an error description on failure.
    static func run(_ commands: [String]) async -> (success: Bool, message: String) {
        guard !commands.isEmpty else {
            return (true, "Nothing to do")
        }

        // Join all commands into a single script.
        let script = commands.joined(separator: " ; ")

        // Create the askpass helper script that shows a password dialog.
        let askpassURL = createAskpassHelper()
        guard let askpassURL else {
            return (false, "Could not create askpass helper")
        }
        defer { try? FileManager.default.removeItem(at: askpassURL) }

        // Run the script via `sudo -A` so it uses our askpass helper.
        // `-A` = read password from SUDO_ASKPASS program
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-A", "/bin/sh", "-c", script]

        var environment = ProcessInfo.processInfo.environment
        environment["SUDO_ASKPASS"] = askpassURL.path
        process.environment = environment

        // Capture stdout and stderr.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: (true, stdout.isEmpty ? "Done" : stdout))
                } else {
                    // Check if the user canceled the password dialog.
                    // sudo returns exit code 1 when askpass fails/cancels.
                    let message = stderr.isEmpty ? "Failed (exit \(process.terminationStatus))" : stderr
                    if message.contains("No password was provided") || message.contains("askpass") {
                        continuation.resume(returning: (false, "Authentication canceled"))
                    } else {
                        continuation.resume(returning: (false, message))
                    }
                }
            } catch {
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }

    // MARK: - Askpass helper

    /// Create a temporary askpass helper script that displays a native
    /// macOS password dialog via `osascript`.
    ///
    /// `sudo -A` calls this script when it needs a password.  The script
    /// shows a `display dialog` with a hidden answer field and prints the
    /// result to stdout.  If the user cancels, `osascript` exits non-zero
    /// and sudo treats it as "no password provided".
    private static func createAskpassHelper() -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let askpassURL = tempDir.appendingPathComponent("touchbridge_askpass_\(UUID().uuidString).sh")

        let script = """
        #!/bin/sh
        osascript -e 'display dialog "TouchBridge needs your administrator password to modify system configuration:" default answer "" with hidden answer with title "TouchBridge Administrator Access"' -e 'text returned of result' 2>/dev/null
        """

        do {
            try script.write(to: askpassURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: askpassURL.path
            )
            return askpassURL
        } catch {
            return nil
        }
    }
}
