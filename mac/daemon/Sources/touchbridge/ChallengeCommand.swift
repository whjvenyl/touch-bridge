import ArgumentParser
import Foundation
import TouchBridgeCore

// MARK: - Challenge

struct Challenge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge",
        abstract: "Issue a challenge to a paired device and print the result."
    )

    @Option(name: .long, help: "Device ID of the paired companion.")
    var device: String

    @Option(name: .long, help: "Reason string shown on the companion device.")
    var reason: String = "touchbridge"

    @Option(name: .long, help: "Timeout in seconds to wait for response (default: 30).")
    var timeout: Int = 30

    func run() throws {
        let keychainStore = KeychainStore()

        // Verify the device is paired
        do {
            let pairedDevice = try keychainStore.retrievePairedDevice(deviceID: device)
            print("Challenging paired device: \(pairedDevice.displayName) (\(device))")
        } catch {
            print("Error: Device '\(device)' is not paired.")
            print("Run 'touchbridge pair' first.")
            throw ExitCode.failure
        }

        let config = DaemonConfig.load()
        let coordinator = DaemonCoordinator(
            keychainStore: keychainStore,
            serviceUUID: config.serviceUUID
        )
        var challengeResult: ChallengeResult?

        coordinator.onChallengeResult = { _, result, _ in
            challengeResult = result
        }

        coordinator.start()

        print("Starting BLE server, waiting for companion to connect...")

        // Wait for a central to connect and establish ECDH
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            coordinator.startAdvertising()
        }

        // Poll for a ready central
        var centralID: UUID?
        let pollDeadline = Date(timeIntervalSinceNow: TimeInterval(timeout))

        while Date() < pollDeadline {
            if let first = coordinator.identifiedCentrals.first {
                centralID = first
                break
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        guard let central = centralID else {
            print("\nNo companion device connected within \(timeout) seconds.")
            print("Make sure the TouchBridge app is running on your iPhone/iPad.")
            coordinator.stop()
            throw ExitCode.failure
        }

        print("Companion connected. Issuing challenge...")

        // Issue the challenge
        var challengeIssued = false
        var issueFinished = false
        let issueDeadline = Date(timeIntervalSinceNow: TimeInterval(timeout))
        Task {
            challengeIssued = await coordinator.issueChallenge(to: central, reason: reason) != nil
            issueFinished = true
        }

        while !issueFinished && Date() < issueDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard challengeIssued else {
            print("Failed to issue challenge.")
            coordinator.stop()
            throw ExitCode.failure
        }

        // Keep the main run loop active so CoreBluetooth can deliver the signed
        // response from the companion instead of blocking it on a semaphore.
        let responseDeadline = Date(timeIntervalSinceNow: TimeInterval(timeout))
        while challengeResult == nil && Date() < responseDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        coordinator.stop()

        guard let result = challengeResult else {
            print("\nFAILED_TIMEOUT: Companion did not respond within \(timeout) seconds.")
            throw ExitCode.failure
        }

        switch result {
        case .verified:
            print("\nVERIFIED")
            print("Biometric authentication succeeded.")
        case .expired:
            print("\nFAILED_TIMEOUT")
            print("Challenge expired before response was received.")
            throw ExitCode.failure
        case .invalidSignature:
            print("\nFAILED_SIGNATURE")
            print("Signature verification failed.")
            throw ExitCode.failure
        case .replayDetected:
            print("\nFAILED_REPLAY")
            print("Replay attack detected — nonce was already used.")
            throw ExitCode.failure
        case .unknownChallenge:
            print("\nFAILED")
            print("Unknown challenge ID in response.")
            throw ExitCode.failure
        case .keyInvalidated:
            print("\nFAILED_KEY_INVALIDATED")
            print("Signing key was invalidated — biometric enrollment changed on the companion device.")
            print("Re-pair: touchbridge pair")
            throw ExitCode.failure
        }
    }
}
