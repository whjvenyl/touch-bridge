import Foundation

/// Runs shell commands with administrator privileges.
///
/// Uses `NSAppleScript`'s `do shell script ... with administrator privileges`,
/// which invokes the Security framework's native authentication dialog under
/// the hood — the same dialog System Settings and other Apple apps use for
/// one-off privileged operations.
///
/// This is the standard approach for apps that cannot use `SMAppService.daemon`
/// (which requires a Team ID from a valid Apple Developer certificate). When
/// the app is signed with a Developer ID, the `HelperClient`/`SMAppService`
/// path is preferred because it avoids repeated password prompts.
///
/// - Note: The dialog shown is **not** an AppleScript dialog — it's the
///   native Security framework auth dialog. `NSAppleScript` is just the
///   transport; `do shell script ... with administrator privileges` is
///   implemented by the system using `AuthorizationCopyRights`.
enum PrivilegedTask {

    // MARK: - Run

    /// Run a list of shell commands with administrator privileges.
    ///
    /// Commands are joined with `;` and executed as a single script by `/bin/sh`.
    /// The user sees a native Security dialog asking for an admin password.
    ///
    /// - Parameter commands: Shell commands to execute as root.
    /// - Returns: `(success, message)` where message is stdout on success or
    ///   an error description on failure.
    static func run(_ commands: [String]) async -> (success: Bool, message: String) {
        guard !commands.isEmpty else {
            return (true, "Nothing to do")
        }

        // Join all commands into a single script.
        let script = commands.joined(separator: " ; ")

        // Escape for AppleScript string context.
        let escapedScript = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        do shell script "\(escapedScript)" with administrator privileges
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                let result = NSAppleScript(source: appleScript)?
                    .executeAndReturnError(&errorDict)

                if let error = errorDict {
                    let message = (error[NSAppleScript.errorMessage] as? String)
                        ?? "Unknown error"
                    // User canceled the auth dialog (AppleScript error -128)
                    if let number = error["number"] as? Int,
                       number == -128 {
                        continuation.resume(returning: (false, "Authentication canceled"))
                    } else {
                        continuation.resume(returning: (false, message))
                    }
                } else {
                    let output = result?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (true, output.isEmpty ? "Done" : output))
                }
            }
        }
    }
}
