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

    // Recent audit log events
    @Published var recentEvents: [AuthEvent] = []
    @Published var authCount: Int = 0

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

        // Check PAM surface status
        sudoEnabled = checkPAMSurface("sudo_local") || checkPAMSurface("sudo")
        screensaverEnabled = checkPAMSurface("screensaver")
    }

    /// Check if a PAM file contains our hook.
    private func checkPAMSurface(_ name: String) -> Bool {
        let path = "/etc/pam.d/\(name)"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return content.contains("pam_touchbridge")
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

    /// Install TouchBridge system components using the privileged helper.
    func installSystem(patchSudo: Bool = true, patchScreensaver: Bool = false, ignoreSSH: Bool = false) async {
        isInstalling = true
        installMessage = nil

        if !helperClient.isHelperRegistered {
            let registered = await helperClient.registerHelper()
            if !registered {
                installMessage = "Could not register the privileged helper. Check System Settings → General → Login Items to approve TouchBridge."
                isInstalling = false
                return
            }
        }

        guard let daemonPath = BinaryLocator.bundledDaemonPath,
              let pamPath = BinaryLocator.bundledPAMPath else {
            installMessage = "Bundled binaries not found."
            isInstalling = false
            return
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

    /// Uninstall TouchBridge system components using the privileged helper.
    func uninstallSystem() async {
        isInstalling = true
        installMessage = nil

        stopDaemon()
        try? FileManager.default.removeItem(atPath: launchAgentPlist)
        isAutoLaunchEnabled = false

        let (success, message) = await helperClient.uninstall(removeBinary: true)

        if success {
            checkInstallation()
            await helperClient.unregisterHelper()
            installMessage = "Uninstallation complete."
        } else {
            installMessage = "Uninstallation failed: \(message)"
        }
        isInstalling = false
    }

    /// Toggle a PAM surface (sudo or screensaver) via the privileged helper.
    func togglePAMSurface(_ surface: String, enabled: Bool) async {
        isInstalling = true
        installMessage = nil

        if !helperClient.isHelperRegistered {
            let registered = await helperClient.registerHelper()
            if !registered {
                installMessage = "Could not register the privileged helper."
                isInstalling = false
                return
            }
        }

        if enabled {
            guard let pamPath = BinaryLocator.bundledPAMPath else {
                installMessage = "Bundled PAM module not found."
                isInstalling = false
                return
            }
            // Ensure PAM module is installed first
            let (ok, msg) = await helperClient.install(
                daemonPath: BinaryLocator.bundledDaemonPath ?? "",
                pamModulePath: pamPath,
                patchSudo: surface == "sudo",
                patchScreensaver: surface == "screensaver",
                ignoreSSH: false
            )
            if !ok {
                installMessage = "Failed: \(msg)"
            }
        } else {
            // Uninstall just this surface — re-run with the opposite config
            // The helper's uninstall removes everything, so we reinstall with
            // the desired surfaces. This is simpler than per-surface removal.
            let (ok, _) = await helperClient.uninstall(removeBinary: false)
            if ok {
                // Re-patch only the surfaces that should remain
                let wantSudo = surface == "sudo" ? false : sudoEnabled
                let wantScreensaver = surface == "screensaver" ? false : screensaverEnabled
                if wantSudo || wantScreensaver {
                    guard let pamPath = BinaryLocator.bundledPAMPath else { return }
                    _ = await helperClient.install(
                        daemonPath: "",
                        pamModulePath: pamPath,
                        patchSudo: wantSudo,
                        patchScreensaver: wantScreensaver,
                        ignoreSSH: false
                    )
                }
            }
        }

        checkInstallation()
        isInstalling = false
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
        }
    }

    func unpairDevice(deviceID: String) {
        Task {
            try? await client.unpairDevice(deviceID: deviceID)
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
