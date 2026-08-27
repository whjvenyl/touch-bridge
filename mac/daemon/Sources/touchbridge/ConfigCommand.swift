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

        print("")
        print("Surface Enable/Disable (surfaces.json):")
        let surfaces = readSurfacesConfig()
        let sudoEnabled = surfaces["sudo"] ?? false
        let screensaverEnabled = surfaces["screensaver"] ?? false
        print("  sudo: \(sudoEnabled ? "enabled" : "disabled")")
        print("  screensaver: \(screensaverEnabled ? "enabled" : "disabled")")
    }

    private func readSurfacesConfig() -> [String: Bool] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/Library/Application Support/TouchBridge/surfaces.json"
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return dict
    }
}

struct ConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a policy value or enable/disable a surface."
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

    @Flag(name: .long, help: "Enable the surface (writes surfaces.json). Use with --surface.")
    var enable: Bool = false

    @Flag(name: .long, help: "Disable the surface (writes surfaces.json). Use with --surface.")
    var disable: Bool = false

    func run() throws {
        // Handle surface enable/disable (surfaces.json)
        if enable || disable {
            guard let surface else {
                throw ValidationError("--enable/--disable requires --surface")
            }
            if enable && disable {
                throw ValidationError("--enable and --disable are mutually exclusive")
            }
            try writeSurfaceConfig(surface: surface, enabled: enable)
            print("Surface '\(surface)' \(enable ? "enabled" : "disabled").")
            return
        }

        // Handle policy.plist settings
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

    /// Read, update, and write surfaces.json.
    private func writeSurfaceConfig(surface: String, enabled: Bool) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/Library/Application Support/TouchBridge/surfaces.json"
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config: [String: Bool] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            config = dict
        }
        config[surface] = enabled

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
