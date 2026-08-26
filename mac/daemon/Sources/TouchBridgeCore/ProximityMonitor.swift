import Foundation
import OSLog

/// Monitors companion device proximity via BLE RSSI and auto-locks
/// the Mac when the device moves out of range.
///
/// When the paired iPhone leaves BLE range (RSSI drops below threshold
/// for sustained period), the Mac screen is locked.
///
/// This is the inverse of "unlock with iPhone" — "lock when iPhone walks away."
public final class ProximityMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")

    private let rssiThreshold: Int
    private let disconnectDelay: TimeInterval
    private let stateLock = NSLock()
    private var _isEnabled: Bool = false
    private var _disconnectTimer: DispatchWorkItem?
    private var _lastConnectedState: Bool = true
    private let queue = DispatchQueue(label: "dev.touchbridge.proximity")
    private let lockAction: () -> Void

    /// Callback when the Mac should be locked.
    public var onShouldLock: (() -> Void)?

    /// Initialize with configurable RSSI threshold and delay.
    ///
    /// - Parameters:
    ///   - rssiThreshold: Lock when average RSSI drops below this (default -80 dBm)
    ///   - disconnectDelay: Wait this long after disconnect before locking (default 30s)
    public convenience init(rssiThreshold: Int = -80, disconnectDelay: TimeInterval = 30) {
        self.init(
            rssiThreshold: rssiThreshold,
            disconnectDelay: disconnectDelay,
            lockAction: ProximityMonitor.systemDisplaySleep
        )
    }

    init(rssiThreshold: Int, disconnectDelay: TimeInterval, lockAction: @escaping () -> Void) {
        self.rssiThreshold = rssiThreshold
        self.disconnectDelay = disconnectDelay
        self.lockAction = lockAction
    }

    /// Enable proximity-based auto-lock.
    public func enable() {
        stateLock.withLock { _isEnabled = true }
        logger.info("Proximity auto-lock enabled (threshold: \(self.rssiThreshold) dBm, delay: \(self.disconnectDelay)s)")
    }

    /// Disable proximity-based auto-lock.
    public func disable() {
        stateLock.withLock {
            _isEnabled = false
            _disconnectTimer?.cancel()
            _disconnectTimer = nil
        }
        logger.info("Proximity auto-lock disabled")
    }

    /// Called when BLE connection state changes.
    public func connectionStateChanged(connected: Bool) {
        var enabled = false
        var shouldStartTimer = false

        stateLock.withLock {
            enabled = _isEnabled
            guard _isEnabled else { return }

            if connected {
                _disconnectTimer?.cancel()
                _disconnectTimer = nil
                _lastConnectedState = true
            } else if _lastConnectedState {
                _lastConnectedState = false
                shouldStartTimer = true
            }
        }

        guard enabled else { return }

        if connected {
            logger.info("Companion reconnected — auto-lock cancelled")
        } else if shouldStartTimer {
            logger.info("Companion disconnected — will lock in \(self.disconnectDelay)s if not reconnected")

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldLock: Bool = self.stateLock.withLock {
                    guard self._isEnabled, !self._lastConnectedState else { return false }
                    return true
                }
                guard shouldLock else { return }
                self.logger.info("Proximity auto-lock triggered — locking screen")
                self.lockScreen()
            }
            stateLock.withLock { _disconnectTimer = workItem }
            queue.asyncAfter(deadline: .now() + disconnectDelay, execute: workItem)
        }
    }

    /// Called with RSSI updates from BLE.
    public func rssiUpdated(_ rssi: Int) {
        let enabled = stateLock.withLock { _isEnabled }
        guard enabled else { return }

        if rssi < rssiThreshold {
            logger.info("RSSI \(rssi) below threshold \(self.rssiThreshold) — companion moving out of range")
        }
    }

    /// Lock the Mac screen using the CGSession command.
    private func lockScreen() {
        onShouldLock?()

        lockAction()
        logger.info("Screen lock action completed")
    }

    private static func systemDisplaySleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")
                .error("Failed to lock screen: \(error.localizedDescription)")
        }
    }

    public var enabled: Bool { stateLock.withLock { _isEnabled } }
}
