import ArgumentParser
import Foundation
import TouchBridgeCore

@main
struct TouchBridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "touchbridge",
        abstract: "TouchBridge — approve macOS auth prompts from your phone or watch.",
        version: "1.0.0",
        subcommands: [Serve.self, Pair.self, Challenge.self, ListDevices.self, Config.self, Logs.self]
    )
}

// MARK: - Serve

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the TouchBridge daemon."
    )

    @Option(name: .long, help: "RSSI proximity threshold in dBm (default: -75).")
    var rssiThreshold: Int = -75

    @Flag(name: .long, help: "Run in simulator mode — no iPhone needed. Auto-approves all auth requests using software keys.")
    var simulator: Bool = false

    @Flag(name: .long, help: "Interactive simulator — prompts in terminal for approve/deny. Implies --simulator.")
    var interactive: Bool = false

    @Flag(name: .long, help: "Enable proximity auto-lock — lock Mac when companion disconnects.")
    var autoLock: Bool = false

    func run() throws {
        if simulator || interactive {
            try runSimulatorMode()
        } else {
            try runNormalMode()
        }
    }

    private func runSimulatorMode() throws {
        let mode: SimulatorAuthHandler.Mode = interactive ? .interactive : .autoApprove

        print("touchbridge v1.0.0 (SIMULATOR MODE: \(mode.rawValue))")
        print("")
        print("  No iPhone required. Auth requests will be handled locally.")
        print("  This mode is for testing only — not for production use.")
        print("")

        let policyEngine = PolicyEngine()
        let simulatorHandler = SimulatorAuthHandler(mode: mode)

        let socketServer = SocketServer(authHandler: simulatorHandler, policyEngine: policyEngine)
        do {
            try socketServer.start()
            print("  Socket: \(socketServer.path)")
        } catch {
            print("Error: Failed to start socket server: \(error)")
            Darwin.exit(1)
        }

        print("  Ready. Waiting for auth requests...")
        print("")

        setupShutdownHandler {
            print("\nShutting down simulator...")
            socketServer.stop()
        }

        RunLoop.current.run()
    }

    private func runNormalMode() throws {
        print("touchbridge v1.0.0 starting...")

        let config = DaemonConfig.load()
        let policyEngine = PolicyEngine()
        let coordinator = DaemonCoordinator(rssiThreshold: rssiThreshold, serviceUUID: config.serviceUUID)

        // Proximity auto-lock
        var proximityMonitor: ProximityMonitor?
        if autoLock {
            let monitor = ProximityMonitor(rssiThreshold: rssiThreshold - 5)
            monitor.enable()
            monitor.onShouldLock = {
                print("Proximity auto-lock: locking screen")
            }
            proximityMonitor = monitor

            coordinator.onChallengeResult = { challengeID, result, deviceID in
                print("Challenge \(challengeID): \(result) (device: \(deviceID ?? "unknown"))")
            }
        } else {
            coordinator.onChallengeResult = { challengeID, result, deviceID in
                print("Challenge \(challengeID): \(result) (device: \(deviceID ?? "unknown"))")
            }
        }

        coordinator.onPairingComplete = { device in
            print("Paired with \(device.displayName) (\(device.deviceID))")
        }

        // Start Unix domain socket server for PAM module + control app communication
        let socketServer = SocketServer(authHandler: coordinator, controlHandler: coordinator, policyEngine: policyEngine)
        do {
            try socketServer.start()
            print("Socket server listening on \(socketServer.path)")
        } catch {
            print("Warning: Failed to start socket server: \(error)")
            print("PAM module authentication will not be available.")
        }

        coordinator.start()

        // Wait for BLE to be ready, then start advertising
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
            print("Advertising TouchBridge service over BLE...")
            print("Waiting for companion device connections.")
            if self.autoLock {
                print("Proximity auto-lock: ENABLED")
            }
        }

        setupShutdownHandler {
            print("\nShutting down...")
            socketServer.stop()
            coordinator.stop()
            proximityMonitor?.disable()
        }

        print("Press Ctrl+C to stop.")
        RunLoop.current.run()
    }

    private func setupShutdownHandler(_ cleanup: @escaping () -> Void) {
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanup()
            Darwin.exit(0)
        }
        sigintSource.resume()
    }
}
