import Foundation
import ServiceManagement
import SwiftUI

/// View model for the TouchBridge menu bar app.
///
/// Polls the daemon for real status (paired devices, connections, advertising),
/// and provides actions for pairing, unpairing, and daemon lifecycle control.
@MainActor
class MenuBarState: ObservableObject {
    // Installation state
    @Published var isInstalled: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var isAutoLaunchEnabled: Bool = false
    @Published var isInstalling: Bool = false
    @Published var installMessage: String?

    // PAM surface toggles
    @Published var sudoEnabled: Bool = false
    @Published var screensaverEnabled: Bool = false

    // Daemon status (from socket)
    @Published var status: DaemonClient.DaemonStatus?
    @Published var statusError: String?

    // Pairing state
    @Published var isPairing: Bool = false
    @Published var pairingQRData: String?
    @Published var pairingError: String?
    @Published var pairingSucceeded: Bool = false

    // Recent audit log events
    @Published var recentEvents: [AuthEvent] = []
    @Published var authCount: Int = 0

    // True when an authentication request is pending on a companion device.
    // Drives the menu bar badge/indicator.
    @Published var isAuthPending: Bool = false

    struct AuthEvent: Identifiable, Codable {
        let id = UUID()
        let ts: String
        let surface: String
        let result: String
        let companionDevice: String

        enum CodingKeys: String, CodingKey {
            case ts, surface, result
            case companionDevice = "companion_device"
        }
    }

    private let client = DaemonClient()
    private let helperClient = HelperClient()
    private var refreshTimer: Timer?

    // Constants
    private let launchAgentLabel = "dev.touchbridge.daemon"
    private let launchAgentPlist: String

    init() {
        launchAgentPlist = "\(NSHomeDirectory())/Library/LaunchAgents/dev.touchbridge.daemon.plist"
        checkInstallation()
        startRefreshing()
    }

    // MARK: - Installation & Daemon State

    func checkInstallation() {
        isInstalled = BinaryLocator.daemonIsInstalled
            && BinaryLocator.pamModuleIsInstalled

        isDaemonRunning = client.isSocketAvailable
        isAutoLaunchEnabled = FileManager.default.fileExists(atPath: launchAgentPlist)

        // Check PAM surface status from surfaces.json (user-level config).
        // The PAM line in /etc/pam.d/ is installed once at install time;
        // surfaces.json is the runtime toggle that can only disable, never enable.
        let surfaces = readSurfacesConfig()
        sudoEnabled = surfaces["sudo"] ?? true
        screensaverEnabled = surfaces["screensaver"] ?? true
    }

    /// Path to the user-level surfaces config file.
    private var surfacesConfigPath: String {
        "\(NSHomeDirectory())/Library/Application Support/TouchBridge/surfaces.json"
    }

    /// Read the surfaces.json config file.
    /// Returns a dictionary of surface name → enabled bool.
    /// Missing file or keys default to enabled (true).
    private func readSurfacesConfig() -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: surfacesConfigPath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return dict
    }

    /// Write the surfaces.json config file.
    /// Only writes surfaces that are explicitly disabled (false) —
    /// missing keys default to enabled, so we keep the file minimal.
    private func writeSurfacesConfig(sudo: Bool, screensaver: Bool) {
        var config: [String: Bool] = [:]
        if !sudo { config["sudo"] = false }
        if !screensaver { config["screensaver"] = false }

        let dir = (surfacesConfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if config.isEmpty {
            // All enabled — remove the file so defaults kick in.
            try? FileManager.default.removeItem(atPath: surfacesConfigPath)
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: surfacesConfigPath), options: .atomic)
            }
        }
    }

    /// Start the daemon via launchctl.
    func startDaemon() {
        guard FileManager.default.fileExists(atPath: launchAgentPlist) else { return }
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", launchAgentPlist]
        try? process.run()
        process.waitUntilExit()
        checkInstallation()
        Task { await refreshStatus() }
    }

    /// Stop the daemon via launchctl.
    func stopDaemon() {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)/\(launchAgentLabel)"]
        try? process.run()
        process.waitUntilExit()
        // Remove stale socket if the daemon didn't clean it up
        let socketPath = "\(NSHomeDirectory())/Library/Application Support/TouchBridge/daemon.sock"
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        checkInstallation()
        status = nil
    }

    /// Toggle autolaunch at login (load/unload LaunchAgent).
    func toggleAutoLaunch() {
        if isAutoLaunchEnabled {
            stopDaemon()
            try? FileManager.default.removeItem(atPath: launchAgentPlist)
            isAutoLaunchEnabled = false
        } else {
            installLaunchAgentPlist()
            startDaemon()
            isAutoLaunchEnabled = true
        }
    }

    // MARK: - Install / Uninstall via privileged helper

    /// Install TouchBridge system components.
    ///
    /// Patches BOTH sudo and screensaver PAM configs at install time. The
    /// individual surface toggles are handled at runtime via surfaces.json
    /// (no root needed). This is a one-time privileged operation.
    ///
    /// Tries the privileged helper (SMAppService.daemon) first — this is the
    /// preferred path for properly signed (Developer ID) builds. If the helper
    /// cannot be registered (e.g. ad-hoc signed builds with no Team ID), falls
    /// back to `AdminInstaller` which uses an admin-privileged osascript dialog.
    func installSystem(ignoreSSH: Bool = false) async {
        let patchSudo = true
        let patchScreensaver = true
        isInstalling = true
        installMessage = nil

        guard let daemonPath = BinaryLocator.bundledDaemonPath,
              let pamPath = BinaryLocator.bundledPAMPath else {
            installMessage = "Bundled binaries not found."
            isInstalling = false
            return
        }

        // Try the privileged helper first (preferred for Developer ID signed builds)
        if !helperClient.isHelperRegistered {
            let (registered, regError) = await helperClient.registerHelper()
            if !registered {
                // Fall back to admin-privileged osascript (works with ad-hoc signing)
                print("Helper registration failed, falling back to admin installer: \(regError ?? "unknown")")
                let (success, message) = await AdminInstaller.install(
                    daemonPath: daemonPath,
                    pamModulePath: pamPath,
                    patchSudo: patchSudo,
                    patchScreensaver: patchScreensaver,
                    ignoreSSH: ignoreSSH
                )
                if success {
                    checkInstallation()
                    installLaunchAgentPlist()
                    startDaemon()
                    installMessage = "Installation complete."
                } else {
                    installMessage = "Installation failed: \(message)"
                }
                isInstalling = false
                return
            }
        }

        let (success, message) = await helperClient.install(
            daemonPath: daemonPath,
            pamModulePath: pamPath,
            patchSudo: patchSudo,
            patchScreensaver: patchScreensaver,
            ignoreSSH: ignoreSSH
        )

        if success {
            checkInstallation()
            installLaunchAgentPlist()
            startDaemon()
            installMessage = "Installation complete."
        } else {
            installMessage = "Installation failed: \(message)"
        }
        isInstalling = false
    }

    /// Uninstall TouchBridge system components.
    ///
    /// Uses the privileged helper if registered, otherwise falls back to
    /// `AdminInstaller` (admin-privileged osascript dialog).
    func uninstallSystem() async {
        isInstalling = true
        installMessage = nil

        stopDaemon()
        try? FileManager.default.removeItem(atPath: launchAgentPlist)
        isAutoLaunchEnabled = false

        let (success, message): (Bool, String)
        if helperClient.isHelperRegistered {
            (success, message) = await helperClient.uninstall(removeBinary: true)
        } else {
            (success, message) = await AdminInstaller.uninstall(removeBinary: true)
        }

        if success {
            checkInstallation()
            if helperClient.isHelperRegistered {
                await helperClient.unregisterHelper()
            }
            installMessage = "Uninstallation complete."
        } else {
            installMessage = "Uninstallation failed: \(message)"
        }
        isInstalling = false
    }

    /// Toggle a PAM surface (sudo or screensaver).
    ///
    /// This is now a simple user-level file write to surfaces.json — no root
    /// privileges needed. The PAM module reads this file on each invocation
    /// and short-circuits (returns PAM_AUTH_ERR) if the surface is disabled.
    ///
    /// The PAM config line in /etc/pam.d/ is installed once at install time
    /// and remains permanent. surfaces.json is the runtime toggle.
    func togglePAMSurface(_ surface: String, enabled: Bool) {
        // Read current config, update the requested surface, write back.
        var surfaces = readSurfacesConfig()
        surfaces[surface] = enabled

        // Write the full config (both surfaces) so we don't lose the other one.
        let sudo = surfaces["sudo"] ?? true
        let screensaver = surfaces["screensaver"] ?? true
        writeSurfacesConfig(sudo: sudo, screensaver: screensaver)

        checkInstallation()
    }

    private func installLaunchAgentPlist() {
        guard let binaryPath = BinaryLocator.daemonPath else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>serve</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(NSHomeDirectory())/Library/Logs/TouchBridge/daemon.stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(NSHomeDirectory())/Library/Logs/TouchBridge/daemon.stderr.log</string>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        let dir = (launchAgentPlist as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? plist.write(toFile: launchAgentPlist, atomically: true, encoding: .utf8)
    }

    // MARK: - Daemon Status Polling

    func refreshStatus() async {
        guard isDaemonRunning else {
            status = nil
            return
        }
        do {
            let newStatus = try await client.getStatus()
            status = newStatus
            statusError = nil

            if isPairing && !newStatus.isPairingActive {
                isPairing = false
                pairingQRData = nil
                // Pairing completed — mark as succeeded so the pairing window
                // can show a success message before closing.
                pairingSucceeded = pairingError == nil
            }
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }

    func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkInstallation()
                await self?.refreshStatus()
                self?.loadRecentEvents()
            }
        }
        Task {
            await refreshStatus()
            loadRecentEvents()
        }
    }

    // MARK: - Pairing

    func startPairing() {
        isPairing = true
        pairingError = nil
        pairingQRData = nil
        pairingSucceeded = false

        Task {
            do {
                let qrData = try await client.startPairing()
                pairingQRData = qrData
            } catch {
                pairingError = error.localizedDescription
                isPairing = false
            }
        }
    }

    func cancelPairing() {
        Task {
            try? await client.cancelPairing()
            isPairing = false
            pairingQRData = nil
            pairingSucceeded = false
        }
    }

    func unpairDevice(deviceID: String) {
        Task {
            try? await client.unpairDevice(deviceID: deviceID)
            await refreshStatus()
        }
    }

    func setDeviceEnabled(deviceID: String, enabled: Bool) {
        Task {
            try? await client.setDeviceEnabled(deviceID: deviceID, enabled: enabled)
            await refreshStatus()
        }
    }

    // MARK: - Audit Log

    func loadRecentEvents() {
        let logDir = "\(NSHomeDirectory())/Library/Logs/TouchBridge"
        let fm = FileManager.default

        guard fm.fileExists(atPath: logDir),
              let files = try? fm.contentsOfDirectory(atPath: logDir)
                .filter({ $0.hasSuffix(".ndjson") })
                .sorted()
                .reversed() else { return }

        var events: [AuthEvent] = []
        let decoder = JSONDecoder()

        for file in files {
            let path = "\(logDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(AuthEvent.self, from: data) else { continue }
                events.append(event)
                if events.count >= 10 { break }
            }
            if events.count >= 10 { break }
        }

        recentEvents = events
        authCount = events.filter { $0.result == "VERIFIED" }.count
    }
}
