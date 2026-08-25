import ArgumentParser
import Foundation
import TouchBridgeCore

// MARK: - List Devices

struct ListDevices: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "List all paired companion devices."
    )

    func run() throws {
        let store = KeychainStore()

        let devices = try store.listPairedDevices()

        if devices.isEmpty {
            print("No paired devices.")
            print("Run 'touchbridge pair' to pair a companion device.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        print("Paired devices (\(devices.count)):")
        print("")
        for device in devices {
            print("  \(device.displayName)")
            print("    ID:     \(device.deviceID)")
            print("    Paired: \(formatter.string(from: device.pairedAt))")
            print("    Key:    \(device.publicKey.prefix(8).map { String(format: "%02x", $0) }.joined())...")
            print("")
        }
    }
}
