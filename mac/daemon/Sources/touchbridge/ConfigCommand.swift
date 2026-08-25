import ArgumentParser
import Foundation
import TouchBridgeCore

// MARK: - Config

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write TouchBridge policy configuration.",
        subcommands: [ConfigShow.self, ConfigSet.self, ConfigReset.self]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current policy configuration."
    )

    func run() throws {
        let engine = PolicyEngine()
        let policies = engine.allPolicies()

        print("TouchBridge Policy Configuration")
        print("  Auth timeout: \(engine.authTimeout())s")
        print("  RSSI threshold: \(engine.rssiThreshold()) dBm")
        print("")
        print("Surface Policies:")

        for (surface, policy) in policies.sorted(by: { $0.key < $1.key }) {
            let modeStr = policy.mode == .biometricRequired ? "biometric required" : "proximity session"
            var line = "  \(surface): \(modeStr)"
            if policy.mode == .proximitySession {
                let minutes = Int(policy.sessionTTLSeconds / 60)
                line += " (\(minutes) min)"
            }
            print(line)
        }
    }
}

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a policy value."
    )

    @Option(name: .long, help: "Surface name (e.g., sudo, screensaver).")
    var surface: String?

    @Option(name: .long, help: "Auth mode: biometric_required or proximity_session.")
    var mode: String?

    @Option(name: .long, help: "Session TTL in minutes (for proximity_session mode).")
    var ttl: Int?

    @Option(name: .long, help: "Auth timeout in seconds.")
    var timeout: Int?

    @Option(name: .long, help: "RSSI threshold in dBm.")
    var rssi: Int?

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"

        let dict = NSMutableDictionary(contentsOfFile: plistPath) ?? NSMutableDictionary()

        if let timeout { dict["AuthTimeoutSeconds"] = Double(timeout) }
        if let rssi { dict["RSSIThreshold"] = rssi }

        if let surface, let mode {
            var surfaces = dict["Surfaces"] as? [String: [String: Any]] ?? [:]
            var surfaceDict = surfaces[surface] ?? [:]
            surfaceDict["mode"] = mode
            if let ttl { surfaceDict["sessionTTLSeconds"] = Double(ttl * 60) }
            surfaces[surface] = surfaceDict
            dict["Surfaces"] = surfaces
        }

        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dict.write(toFile: plistPath, atomically: true)
        print("Policy saved.")
    }
}

struct ConfigReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset policy to defaults."
    )

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
        print("Policy reset to defaults.")
    }
}
