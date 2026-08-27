import Foundation
import OSLog
import TouchBridgeProtocol

/// Authentication mode for a given surface.
public enum AuthMode: String, Codable, Sendable {
    /// Always require biometric confirmation on companion device.
    case biometricRequired = "biometric_required"
    /// Allow proximity session — if device was authenticated recently within TTL, skip biometric.
    case proximitySession = "proximity_session"
}

/// Per-surface policy configuration.
public struct SurfacePolicy: Codable, Sendable {
    public let mode: AuthMode
    /// Session TTL in seconds (only used when mode == .proximitySession).
    public let sessionTTLSeconds: TimeInterval

    public init(mode: AuthMode, sessionTTLSeconds: TimeInterval = 0) {
        self.mode = mode
        self.sessionTTLSeconds = sessionTTLSeconds
    }
}

/// Device selection mode for fan-out during `authenticateFromPAM`.
///
/// - `anyOneOf`: Broadcast to all identified, enabled devices. First response wins.
///   This is the default and preserves the original broadcast behavior.
/// - `priorityOrder`: Try devices in priority order (lowest priority value first).
///   Each device gets `globalTimeout / N` seconds. If it times out, move to the next.
///   Only meaningful for user-created ordered groups.
public enum SelectionMode: String, Codable, Sendable {
    case anyOneOf = "any_one_of"
    case priorityOrder = "priority_order"
}

/// Device selection policy — determines which devices receive challenges
/// and in what order.
///
/// Default: `anyOneOf` (broadcast to all enabled devices).
/// Users can set `priorityOrder` via `policy.plist` for sequential dispatch.
public struct SelectionPolicy: Codable, Sendable, Equatable {
    public let mode: SelectionMode

    public init(mode: SelectionMode = .anyOneOf) {
        self.mode = mode
    }
}

/// Manages per-action authentication policy.
///
/// Default policy:
/// - sudo → always require biometric
/// - screensaver → proximity session (30 min)
/// - app_store → always require biometric
/// - system_settings → always require biometric
/// - browser_autofill → proximity session (10 min)
///
/// Reads overrides from `~/Library/Application Support/TouchBridge/policy.plist`.
public final class PolicyEngine: Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "PolicyEngine")
    private let plistPath: String

    /// Default policies per surface.
    private static let defaults: [String: SurfacePolicy] = [
        "sudo": SurfacePolicy(mode: .biometricRequired),
        "screensaver": SurfacePolicy(mode: .proximitySession, sessionTTLSeconds: 1800),
        "app_store": SurfacePolicy(mode: .biometricRequired),
        "system_settings": SurfacePolicy(mode: .biometricRequired),
        "browser_autofill": SurfacePolicy(mode: .proximitySession, sessionTTLSeconds: 600),
    ]

    /// Active proximity sessions: surface → expiry time.
    private let sessions = ProximitySessionStore()

    public init(plistPath: String? = nil) {
        if let path = plistPath {
            self.plistPath = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.plistPath = "\(home)/Library/Application Support/TouchBridge/policy.plist"
        }
    }

    /// Get the policy for a given surface (e.g., "sudo", "screensaver").
    public func policy(for surface: String) -> SurfacePolicy {
        // Check user overrides from plist
        if let dict = NSDictionary(contentsOfFile: plistPath),
           let surfaces = dict["Surfaces"] as? [String: [String: Any]],
           let surfaceDict = surfaces[surface],
           let modeStr = surfaceDict["mode"] as? String,
           let mode = AuthMode(rawValue: modeStr) {
            let ttl = surfaceDict["sessionTTLSeconds"] as? TimeInterval ?? 0
            return SurfacePolicy(mode: mode, sessionTTLSeconds: ttl)
        }

        // Fall back to defaults
        return Self.defaults[surface] ?? SurfacePolicy(mode: .biometricRequired)
    }

    /// Determine whether biometric auth is needed for this surface right now.
    ///
    /// Returns `true` if biometric is required, `false` if a valid proximity session exists.
    public func requiresBiometric(for surface: String, deviceID: String) -> Bool {
        let pol = policy(for: surface)

        switch pol.mode {
        case .biometricRequired:
            return true
        case .proximitySession:
            // Check if there's a valid session
            if sessions.isValid(surface: surface, deviceID: deviceID) {
                return false
            }
            return true
        }
    }

    /// Record a successful biometric auth, starting a proximity session if applicable.
    public func recordAuthentication(surface: String, deviceID: String) {
        let pol = policy(for: surface)
        if pol.mode == .proximitySession && pol.sessionTTLSeconds > 0 {
            sessions.create(surface: surface, deviceID: deviceID, ttl: pol.sessionTTLSeconds)
        }
    }

    /// Invalidate all proximity sessions (e.g., on device disconnect).
    public func invalidateAllSessions() {
        sessions.clear()
    }

    /// Kill-switch: when active, `authenticateFromPAM` returns immediately with
    /// a forced-password fallback, bypassing all BLE challenge dispatch.
    ///
    /// Triggered by either:
    ///   - Environment variable `TOUCHBRIDGE_FORCE_PASSWORD=1`
    ///   - Plist key `ForcePasswordFallback: true`
    ///
    /// This is the sudo-lockout rollback path — if a policy or daemon regression
    /// breaks `sudo`, the user can set this and reboot to restore password auth
    /// without uninstalling TouchBridge.
    public func forcePasswordFallback() -> Bool {
        if ProcessInfo.processInfo.environment["TOUCHBRIDGE_FORCE_PASSWORD"] == "1" {
            return true
        }
        if let dict = NSDictionary(contentsOfFile: plistPath),
           let force = dict["ForcePasswordFallback"] as? Bool {
            return force
        }
        return false
    }

    /// Authentication timeout in seconds. Defaults to 15s if not configured.
    public func authTimeout() -> TimeInterval {
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let timeout = dict["AuthTimeoutSeconds"] as? Double,
              timeout > 0 else {
            return 15.0
        }
        return timeout
    }

    /// Default RSSI threshold for proximity gate. Defaults to -75 dBm.
    public func rssiThreshold() -> Int {
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let threshold = dict["RSSIThreshold"] as? Int else {
            return -75
        }
        return threshold
    }

    /// Device selection policy — determines fan-out behavior.
    ///
    /// Reads from `policy.plist`:
    /// ```
    /// DeviceSelection = {
    ///     mode = "any_one_of" | "priority_order";
    ///     group = "all" | "custom-group-name";
    /// };
    /// ```
    /// Defaults to `anyOneOf` (broadcast to all enabled devices).
    public func selectionPolicy() -> SelectionPolicy {
        if let dict = NSDictionary(contentsOfFile: plistPath),
           let selection = dict["DeviceSelection"] as? [String: Any] {
            let modeStr = selection["mode"] as? String ?? "any_one_of"
            let mode = SelectionMode(rawValue: modeStr) ?? .anyOneOf
            return SelectionPolicy(mode: mode)
        }
        return SelectionPolicy(mode: .anyOneOf)
    }

    /// Per-device timeout budget for `priorityOrder` mode.
    ///
    /// In `priorityOrder`, each device gets `globalTimeout / N` seconds,
    /// where N is the number of devices in the group. This prevents a single
    /// slow device from consuming the entire auth timeout.
    ///
    /// The global auth timeout is `authTimeout()` (default 15s).
    /// The per-device challenge timeout is `challengeExpirySeconds` (default 10s).
    /// For `priorityOrder`, the per-device budget is `min(globalTimeout / N, challengeExpiry)`.
    public func perDeviceTimeout(deviceCount: Int) -> TimeInterval {
        guard deviceCount > 0 else { return authTimeout() }
        let global = authTimeout()
        let perDevice = global / Double(deviceCount)
        // Cap at challenge expiry — no point giving a device more time than
        // the challenge nonce is valid for.
        return min(perDevice, TouchBridgeConstants.challengeExpirySeconds)
    }

    /// List all configured surface policies (defaults + overrides).
    public func allPolicies() -> [String: SurfacePolicy] {
        var result = Self.defaults

        if let dict = NSDictionary(contentsOfFile: plistPath),
           let surfaces = dict["Surfaces"] as? [String: [String: Any]] {
            for (surface, surfaceDict) in surfaces {
                if let modeStr = surfaceDict["mode"] as? String,
                   let mode = AuthMode(rawValue: modeStr) {
                    let ttl = surfaceDict["sessionTTLSeconds"] as? TimeInterval ?? 0
                    result[surface] = SurfacePolicy(mode: mode, sessionTTLSeconds: ttl)
                }
            }
        }

        return result
    }
}

/// Thread-safe proximity session storage.
final class ProximitySessionStore: @unchecked Sendable {
    private var sessions: [String: Date] = [:] // key: "surface:deviceID" → expiry
    private let lock = NSLock()

    func create(surface: String, deviceID: String, ttl: TimeInterval) {
        let key = "\(surface):\(deviceID)"
        lock.lock()
        sessions[key] = Date().addingTimeInterval(ttl)
        lock.unlock()
    }

    func isValid(surface: String, deviceID: String) -> Bool {
        let key = "\(surface):\(deviceID)"
        lock.lock()
        defer { lock.unlock() }
        guard let expiry = sessions[key] else { return false }
        if Date() < expiry {
            return true
        }
        sessions.removeValue(forKey: key)
        return false
    }

    func clear() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
    }
}
