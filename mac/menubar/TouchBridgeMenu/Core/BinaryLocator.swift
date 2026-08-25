import Foundation

/// Locates the TouchBridge daemon binary at runtime.
///
/// Search order:
/// 1. App bundle Resources/ (bundled with the menubar app)
/// 2. /usr/local/bin/touchbridge (installed via install.sh or .pkg)
/// 3. /opt/homebrew/bin/touchbridge (installed via Homebrew)
/// 4. ~/.homebrew/bin/touchbridge (non-standard Homebrew prefix)
enum BinaryLocator {
    /// Path to the bundled daemon binary inside the app's Resources directory.
    static var bundledDaemonPath: String? {
        Bundle.main.url(forResource: "touchbridge", withExtension: nil)?
            .path
    }

    /// Path to the bundled PAM module inside the app's Resources directory.
    static var bundledPAMPath: String? {
        Bundle.main.url(forResource: "pam_touchbridge", withExtension: "so")?
            .path
    }

    /// All candidate paths for the daemon binary, in search order.
    static var daemonCandidates: [String] {
        var paths: [String] = []
        if let bundled = bundledDaemonPath { paths.append(bundled) }
        paths.append("/usr/local/bin/touchbridge")
        paths.append("/opt/homebrew/bin/touchbridge")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append("\(home)/.homebrew/bin/touchbridge")
        return paths
    }

    /// First existing daemon binary path, or nil if none found.
    static var daemonPath: String? {
        daemonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether the daemon binary exists anywhere.
    static var daemonIsInstalled: Bool {
        daemonPath != nil
    }

    /// Whether the PAM module is installed at the system location.
    static var pamModuleIsInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/lib/pam/pam_touchbridge.so")
    }

    /// Whether the bundled PAM module is available.
    static var hasBundledPAM: Bool {
        bundledPAMPath != nil
    }

    /// Whether the daemon came from Homebrew (not the app bundle).
    static var isHomebrewInstall: Bool {
        guard let path = daemonPath else { return false }
        return path.contains("homebrew") || path == "/usr/local/bin/touchbridge"
    }
}
