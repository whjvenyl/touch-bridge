import Foundation
import OSLog

/// Runtime state for a paired companion device.
///
/// Lives in-memory + `~/Library/Application Support/TouchBridge/devices.json` (0o600).
/// NOT in Keychain — Keychain is for pairing material (publicKey, deviceType, caps,
/// pairedAt) that rarely changes. Runtime state (enabled, priority, lastSeen,
/// linkQuality) changes frequently and must not incur Keychain IPC overhead.
public struct DeviceRuntimeState: Codable, Sendable, Equatable {
    public let deviceID: String
    public var enabled: Bool
    /// Priority within an ordered group (lower = higher priority).
    /// Only meaningful when the device is in a `priorityOrder` group.
    public var priority: Int
    public var lastSeen: Date?
    /// Coarse link quality — updated from RSSI averages.
    public var linkQuality: LinkQuality

    public init(
        deviceID: String,
        enabled: Bool = true,
        priority: Int = 0,
        lastSeen: Date? = nil,
        linkQuality: LinkQuality = .unknown
    ) {
        self.deviceID = deviceID
        self.enabled = enabled
        self.priority = priority
        self.lastSeen = lastSeen
        self.linkQuality = linkQuality
    }
}

/// Coarse link quality bucket — derived from average RSSI.
/// Exposed to UI instead of raw dBm to avoid implying false precision.
public enum LinkQuality: String, Codable, Sendable, CaseIterable {
    case good      // RSSI >= -60
    case fair      // -75 <= RSSI < -60
    case poor      // -90 <= RSSI < -75
    case unknown   // No RSSI data or RSSI < -90

    /// Map an average RSSI value to a quality bucket.
    public static func from(rssi: Int?) -> LinkQuality {
        guard let rssi = rssi else { return .unknown }
        if rssi >= -60 { return .good }
        if rssi >= -75 { return .fair }
        if rssi >= -90 { return .poor }
        return .unknown
    }
}

/// In-memory + file-backed store for device runtime state.
///
/// File: `~/Library/Application Support/TouchBridge/devices.json`
/// Permissions: 0o600 (owner read/write only).
///
/// Thread-safe via a single `NSLock`. File writes are debounced — callers
/// mutate in-memory state and the store persists on each mutation. For
/// high-frequency updates (e.g. RSSI on every packet), use `updateLinkQuality`
/// which only writes to disk if the bucket changed.
public final class DeviceRuntimeStore: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "DeviceRuntimeStore")
    private let lock = NSLock()
    private var states: [String: DeviceRuntimeState] = [:]
    private let filePath: String

    public init(filePath: String? = nil) {
        if let filePath {
            self.filePath = filePath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let dir = "\(home)/Library/Application Support/TouchBridge"
            self.filePath = "\(dir)/devices.json"
        }
        loadFromDisk()
    }

    // MARK: - Read

    /// Get runtime state for a device. Returns a default state if not found.
    public func get(_ deviceID: String) -> DeviceRuntimeState {
        lock.lock()
        defer { lock.unlock() }
        return states[deviceID] ?? DeviceRuntimeState(deviceID: deviceID)
    }

    /// Get all runtime states.
    public func all() -> [DeviceRuntimeState] {
        lock.lock()
        defer { lock.unlock() }
        return Array(states.values)
    }

    /// Check if a device is enabled (defaults to true if unknown).
    public func isEnabled(_ deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[deviceID]?.enabled ?? true
    }

    // MARK: - Write

    /// Set the enabled state for a device. Persists to disk.
    public func setEnabled(_ deviceID: String, enabled: Bool) {
        lock.lock()
        var state = states[deviceID] ?? DeviceRuntimeState(deviceID: deviceID)
        state.enabled = enabled
        states[deviceID] = state
        lock.unlock()
        persist()
    }

    /// Set the priority for a device. Persists to disk.
    public func setPriority(_ deviceID: String, priority: Int) {
        lock.lock()
        var state = states[deviceID] ?? DeviceRuntimeState(deviceID: deviceID)
        state.priority = priority
        states[deviceID] = state
        lock.unlock()
        persist()
    }

    /// Update lastSeen timestamp. Does NOT persist to disk (too frequent).
    public func updateLastSeen(_ deviceID: String, at date: Date = Date()) {
        lock.lock()
        var state = states[deviceID] ?? DeviceRuntimeState(deviceID: deviceID)
        state.lastSeen = date
        states[deviceID] = state
        lock.unlock()
        // No persist — lastSeen changes on every packet, would thrash disk.
    }

    /// Update link quality from RSSI. Only persists to disk if the bucket changed.
    public func updateLinkQuality(_ deviceID: String, rssi: Int?) {
        let newQuality = LinkQuality.from(rssi: rssi)
        lock.lock()
        var state = states[deviceID] ?? DeviceRuntimeState(deviceID: deviceID)
        let oldQuality = state.linkQuality
        state.linkQuality = newQuality
        states[deviceID] = state
        lock.unlock()
        if oldQuality != newQuality {
            persist()
        }
    }

    /// Remove a device's runtime state (e.g. after unpairing). Persists to disk.
    public func remove(_ deviceID: String) {
        lock.lock()
        states.removeValue(forKey: deviceID)
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.info("No devices.json found — starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoded = try JSONDecoder().decode([String: DeviceRuntimeState].self, from: data)
            lock.lock()
            states = decoded
            lock.unlock()
            logger.info("Loaded \(decoded.count) device runtime state(s) from disk")
        } catch {
            logger.error("Failed to load devices.json: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let dir = (filePath as NSString).deletingLastPathComponent

        // Ensure directory exists
        if !FileManager.default.fileExists(atPath: dir) {
            do {
                try FileManager.default.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true
                )
            } catch {
                logger.error("Failed to create directory: \(error.localizedDescription)")
                return
            }
        }

        lock.lock()
        let snapshot = states
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)

            // Write atomically, then set permissions to 0o600
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
        } catch {
            logger.error("Failed to persist devices.json: \(error.localizedDescription)")
        }
    }
}
