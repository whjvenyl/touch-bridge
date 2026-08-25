import ArgumentParser
import CoreImage
import Foundation
import TouchBridgeCore

// MARK: - Pair

struct Pair: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Generate pairing QR data and wait for a companion device."
    )

    @Option(name: .long, help: "Timeout in seconds to wait for pairing (default: 300).")
    var timeout: Int = 300

    func run() throws {
        let keychainStore = KeychainStore()
        // Pair against the same persistent, per-Mac UUID used by the
        // long-running daemon. Using the protocol's shared default here makes
        // a successful one-off pairing unable to reconnect to `serve` later.
        let config = DaemonConfig.load()
        let pairingManager = PairingManager(
            keychainStore: keychainStore,
            serviceUUID: config.serviceUUID
        )
        let coordinator = DaemonCoordinator(
            keychainStore: keychainStore,
            pairingManager: pairingManager,
            serviceUUID: config.serviceUUID
        )

        var paired = false

        // Generate and display QR data
        let group = DispatchGroup()
        group.enter()

        Task {
            do {
                let qrData = try await pairingManager.generatePairingQRData()

                if let jsonString = String(data: qrData, encoding: .utf8) {
                    print("")
                    print("=== TouchBridge Pairing ===")
                    print("")

                    if let qrURL = Self.writeQRImage(qrData) {
                        print("Opening QR code — scan it with the TouchBridge app on your iPhone.")
                        print("  (\(qrURL.path))")
                        let open = Process()
                        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        open.arguments = [qrURL.path]
                        try? open.run()
                    }

                    print("")
                    print("Or paste this pairing data into the app manually:")
                    print("")
                    print(jsonString)
                    print("")
                }
            } catch {
                print("Error generating pairing data: \(error)")
            }
            group.leave()
        }
        group.wait()

        // Set up pairing callback
        coordinator.onPairingComplete = { device in
            print("")
            print("Pairing successful!")
            print("  Device: \(device.displayName)")
            print("  ID:     \(device.deviceID)")
            print("  Paired: \(device.pairedAt)")
            print("")
            paired = true
        }

        // Start BLE advertising
        coordinator.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
            print("Waiting for companion device to connect (timeout: \(self.timeout)s)...")
        }

        // Keep the main run loop alive. CoreBluetooth and the delayed advertising
        // callback both use the main queue; blocking it with a semaphore prevents
        // advertising from ever starting.
        let deadline = Date(timeIntervalSinceNow: TimeInterval(timeout))
        while !paired && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        if !paired {
            print("\nPairing timed out after \(self.timeout) seconds.")
        }
        coordinator.stop()

        // The QR image contains the (now spent or expired) pairing token — remove it.
        try? FileManager.default.removeItem(at: Self.qrImageURL)

        if !paired {
            throw ExitCode.failure
        }
    }

    private static let qrImageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("touchbridge-pairing-qr.png")

    /// Render the pairing payload as a QR code PNG. Returns nil if generation fails
    /// (callers fall back to the printed JSON).
    private static func writeQRImage(_ payload: Data) -> URL? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let png = context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }

        do {
            try png.write(to: qrImageURL)
            return qrImageURL
        } catch {
            return nil
        }
    }
}
