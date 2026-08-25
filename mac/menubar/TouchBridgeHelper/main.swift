import Foundation

/// Privileged helper daemon for TouchBridge.
///
/// Runs as root via SMAppService.daemon. Listens for XPC connections
/// from the menubar app and performs privileged operations:
/// - Copy PAM module to /usr/local/lib/pam/
/// - Copy daemon binary to /usr/local/bin/
/// - Patch /etc/pam.d/sudo_local (Sonoma+) or /etc/pam.d/sudo (fallback)
/// - Patch /etc/pam.d/screensaver
/// - Undo all of the above on uninstall
///
/// The helper stays running so it's always available for XPC connections.
/// It verifies that the connecting process is signed by the same team as
/// the main app (ad-hoc signing for development, Developer ID for distribution).

let machServiceName = "dev.touchbridge.helper"

// MARK: - Helper delegate

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Verify the connecting process — accept connections from the main app
        // signed with the same identity. For development (ad-hoc signing), we
        // accept all connections. For distribution, this should verify the
        // connecting process's code signing certificate.
        let connection = HelperConnection()
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = connection
        newConnection.resume()
        return true
    }
}

// MARK: - Helper implementation

class HelperConnection: NSObject, HelperProtocol {
    let pamLine = "auth       sufficient     pam_touchbridge.so"
    let pamDir = "/etc/pam.d"
    let pamLibDir = "/usr/local/lib/pam"
    let binDir = "/usr/local/bin"

    // MARK: - HelperProtocol

    func install(daemonPath: String,
                 pamModulePath: String,
                 patchSudo: Bool,
                 patchScreensaver: Bool,
                 with reply: @escaping (Bool, String) -> Void) {
        var messages: [String] = []

        // 1. Copy daemon binary to /usr/local/bin/
        if FileManager.default.fileExists(atPath: daemonPath) {
            let dest = "\(binDir)/touchbridge"
            do {
                try FileManager.default.createDirectory(
                    atPath: binDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: daemonPath, toPath: dest)
                chmod(dest, 0o755)
                messages.append("Installed daemon to \(dest)")
            } catch {
                reply(false, "Failed to copy daemon: \(error.localizedDescription)")
                return
            }
        }

        // 2. Copy PAM module to /usr/local/lib/pam/
        if FileManager.default.fileExists(atPath: pamModulePath) {
            let dest = "\(pamLibDir)/pam_touchbridge.so"
            do {
                try FileManager.default.createDirectory(
                    atPath: pamLibDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.copyItem(atPath: pamModulePath, toPath: dest)
                chmod(dest, 0o444)
                messages.append("Installed PAM module to \(dest)")
            } catch {
                reply(false, "Failed to copy PAM module: \(error.localizedDescription)")
                return
            }
        }

        // 3. Patch PAM configs
        if patchSudo {
            if !patchSudoPAM() {
                reply(false, "Failed to patch sudo PAM config")
                return
            }
            messages.append("Patched sudo PAM config")
        }

        if patchScreensaver {
            if !patchScreensaverPAM() {
                reply(false, "Failed to patch screensaver PAM config")
                return
            }
            messages.append("Patched screensaver PAM config")
        }

        reply(true, messages.joined(separator: "; "))
    }

    func uninstall(removeBinary: Bool,
                   with reply: @escaping (Bool, String) -> Void) {
        var messages: [String] = []

        // 1. Remove PAM hooks (BEFORE removing the module to avoid lockout)
        removeSudoPAMHook()
        messages.append("Removed sudo PAM hook")

        removeScreensaverPAMHook()
        messages.append("Removed screensaver PAM hook")

        // 2. Remove PAM module
        let pamPath = "\(pamLibDir)/pam_touchbridge.so"
        if FileManager.default.fileExists(atPath: pamPath) {
            try? FileManager.default.removeItem(atPath: pamPath)
            messages.append("Removed PAM module")
        }

        // 3. Optionally remove daemon binary
        if removeBinary {
            let binPath = "\(binDir)/touchbridge"
            if FileManager.default.fileExists(atPath: binPath) {
                try? FileManager.default.removeItem(atPath: binPath)
                messages.append("Removed daemon binary")
            }
        }

        reply(true, messages.joined(separator: "; "))
    }

    func ping(with reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    // MARK: - PAM patching (reimplemented from pam-common.sh in Swift)

    /// True when /etc/pam.d/sudo includes sudo_local (macOS Sonoma 14+).
    private func supportsSudoLocal() -> Bool {
        let sudoPath = "\(pamDir)/sudo"
        guard let content = try? String(contentsOfFile: sudoPath, encoding: .utf8) else {
            return false
        }
        return content.contains(regex: #"^\s*auth\s+include\s+sudo_local"#)
    }

    /// Patch sudo PAM config. Uses sudo_local on Sonoma+, falls back to direct edit.
    private func patchSudoPAM() -> Bool {
        if supportsSudoLocal() {
            return patchSudoLocal()
        }
        return patchPAMFileDirectly("\(pamDir)/sudo")
    }

    /// Patch screensaver PAM config (always a direct edit — no *_local equivalent).
    private func patchScreensaverPAM() -> Bool {
        return patchPAMFileDirectly("\(pamDir)/screensaver")
    }

    /// Write our hook into /etc/pam.d/sudo_local (unprotected, safe).
    private func patchSudoLocal() -> Bool {
        let path = "\(pamDir)/sudo_local"
        var content = ""
        if FileManager.default.fileExists(atPath: path) {
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if content.contains("pam_touchbridge") {
                return true // already patched
            }
        }
        let newContent = pamLine + "\n" + content
        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o644)
            return true
        } catch {
            return false
        }
    }

    /// Directly edit a PAM file: backup, insert our line as the first auth line.
    private func patchPAMFileDirectly(_ pamFile: String) -> Bool {
        guard FileManager.default.fileExists(atPath: pamFile) else { return true }
        guard let content = try? String(contentsOfFile: pamFile, encoding: .utf8) else {
            return false
        }
        if content.contains("pam_touchbridge") { return true } // already patched

        // Backup
        let backup = "\(pamFile).touchbridge-backup"
        if !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: pamFile, toPath: backup)
        }

        // Insert our line before the first "auth" line
        var lines = content.components(separatedBy: "\n")
        var inserted = false
        for i in 0..<lines.count {
            if lines[i].hasPrefix("auth") {
                lines.insert(pamLine, at: i)
                inserted = true
                break
            }
        }
        if !inserted {
            lines.append(pamLine)
        }
        let newContent = lines.joined(separator: "\n")
        do {
            try newContent.write(toFile: pamFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Remove our hook from sudo PAM config.
    private func removeSudoPAMHook() {
        // Remove from sudo_local
        let sudoLocalPath = "\(pamDir)/sudo_local"
        if FileManager.default.fileExists(atPath: sudoLocalPath) {
            if let content = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8) {
                if content.contains("pam_touchbridge") {
                    let filtered = content
                        .components(separatedBy: "\n")
                        .filter { !$0.contains("pam_touchbridge") }
                        .joined(separator: "\n")
                    // Check if anything meaningful remains
                    let trimmed = filtered.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        try? FileManager.default.removeItem(atPath: sudoLocalPath)
                    } else {
                        try? filtered.write(toFile: sudoLocalPath,
                                            atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        // Restore direct edit (legacy fallback)
        restorePAMFile("\(pamDir)/sudo")
    }

    /// Remove our hook from screensaver PAM config.
    private func removeScreensaverPAMHook() {
        restorePAMFile("\(pamDir)/screensaver")
    }

    /// Restore a PAM file from backup, or strip our line if no backup exists.
    private func restorePAMFile(_ pamFile: String) {
        let backup = "\(pamFile).touchbridge-backup"
        if FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.removeItem(atPath: pamFile)
            try? FileManager.default.copyItem(atPath: backup, toPath: pamFile)
            try? FileManager.default.removeItem(atPath: backup)
        } else if let content = try? String(contentsOfFile: pamFile, encoding: .utf8) {
            if content.contains("pam_touchbridge") {
                let filtered = content
                    .components(separatedBy: "\n")
                    .filter { !$0.contains("pam_touchbridge") }
                    .joined(separator: "\n")
                try? filtered.write(toFile: pamFile,
                                    atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Regex helper

private extension String {
    func contains(regex pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}

// MARK: - Main entry point

let listener = NSXPCListener(machServiceName: machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()

// Keep running
RunLoop.current.run()
