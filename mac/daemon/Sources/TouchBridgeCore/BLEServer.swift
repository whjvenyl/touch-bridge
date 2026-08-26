import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

// MARK: - BLE Server Interface

/// Abstraction over the BLE peripheral server.
///
/// Extracted as a protocol so tests can inject a `MockBLEServer` without
/// requiring CoreBluetooth or real Bluetooth hardware.
public protocol BLEServerInterface: AnyObject {
    /// The delegate that receives BLE events.
    var delegate: BLEServerDelegate? { get set }

    /// Whether the server is currently advertising over BLE.
    var isAdvertising: Bool { get }

    func startAdvertising()
    func stopAdvertising()

    /// Send an encrypted challenge to a connected companion. Returns true if sent.
    @discardableResult func sendChallenge(_ data: Data, to centralID: UUID) -> Bool

    /// Send pairing data to a connected companion. Returns true if sent.
    @discardableResult func sendPairingData(_ data: Data, to centralID: UUID) -> Bool

    /// Send session key data to a connected companion. Returns true if sent.
    @discardableResult func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool

    /// UUIDs of currently connected centrals.
    var connectedCentralIDs: [UUID] { get }

    /// Rolling-average RSSI for a connected central, or nil if unavailable.
    func averageRSSI(for centralID: UUID) -> Int?
}

// MARK: - Delegate Protocol

/// Events emitted by the BLE GATT server to the daemon coordinator.
public protocol BLEServerDelegate: AnyObject {
    /// A companion device connected.
    func bleServer(_ server: any BLEServerInterface, centralDidConnect centralID: UUID)

    /// A companion device disconnected.
    func bleServer(_ server: any BLEServerInterface, centralDidDisconnect centralID: UUID)

    /// ECDH session key received from companion; returns our public key bytes to send back.
    func bleServer(_ server: any BLEServerInterface, didReceiveSessionKey data: Data, from centralID: UUID) -> Data?

    /// Pairing data received from companion.
    func bleServer(_ server: any BLEServerInterface, didReceivePairingData data: Data, from centralID: UUID)

    /// Signed challenge response received from companion.
    func bleServer(_ server: any BLEServerInterface, didReceiveResponse data: Data, from centralID: UUID)
}

// MARK: - Pending Notification

/// A notification that couldn't be sent immediately (BLE transmit queue full).
/// Queued and retried when `peripheralManagerIsReady` fires.
struct PendingNotification {
    let data: Data
    let characteristic: CBMutableCharacteristic
    let central: CBCentral
}

// MARK: - Connected Central Tracking

/// Tracks per-central connection state.
struct ConnectedCentral {
    let central: CBCentral
    var subscribedToChallenge: Bool = false
    var subscribedToSession: Bool = false
    var subscribedToPairing: Bool = false
    var rssiReadings: [Int] = []

    /// Rolling average RSSI over last 5 readings.
    var averageRSSI: Int? {
        guard !rssiReadings.isEmpty else { return nil }
        let recent = Array(rssiReadings.suffix(5))
        return recent.reduce(0, +) / recent.count
    }

    mutating func addRSSI(_ rssi: Int) {
        rssiReadings.append(rssi)
        if rssiReadings.count > 10 {
            rssiReadings.removeFirst(rssiReadings.count - 10)
        }
    }
}

// MARK: - BLE Server

/// macOS BLE GATT peripheral server.
///
/// Advertises the TouchBridge service and manages characteristics for:
/// - Session key exchange (ECDH)
/// - Challenge delivery (Mac → iPhone via notify)
/// - Response reception (iPhone → Mac via write)
/// - Pairing flow (bidirectional)
public class BLEServer: NSObject, BLEServerInterface {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "BLEServer")

    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?
    private var isServiceRegistered = false
    private var wantsAdvertising = false

    // Characteristics
    private var sessionKeyChar: CBMutableCharacteristic?
    private var challengeChar: CBMutableCharacteristic?
    private var responseChar: CBMutableCharacteristic?
    private var pairingChar: CBMutableCharacteristic?

    // Connected centrals — accessed from CoreBluetooth delegate callbacks and public API.
    // CoreBluetooth dispatches on its own queue (queue: nil = main queue), but sendChallenge
    // and other public methods can be called from any thread, so this needs a lock.
    private let centralsLock = NSLock()
    private var connectedCentrals: [UUID: ConnectedCentral] = [:]

    // Pending notifications that couldn't be sent because the BLE transmit queue was full.
    // Retried when peripheralManagerIsReady(toUpdateSubscribers:) fires.
    private let pendingLock = NSLock()
    private var pendingNotifications: [PendingNotification] = []

    // RSSI proximity gate
    private let rssiThreshold: Int

    // Per-Mac unique service UUID
    private let serviceUUID: String

    public weak var delegate: BLEServerDelegate?

    /// Whether the peripheral manager is powered on and ready.
    public private(set) var isReady: Bool = false

    /// Whether we are currently advertising.
    public private(set) var isAdvertising: Bool = false

    public init(
        rssiThreshold: Int = TouchBridgeConstants.defaultRSSIThreshold,
        serviceUUID: String = TouchBridgeConstants.serviceUUID
    ) {
        self.rssiThreshold = rssiThreshold
        self.serviceUUID = serviceUUID
        super.init()
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    /// Try to send a notification, queuing it for retry if the BLE transmit queue is full.
    private func sendOrQueue(_ data: Data, for char: CBMutableCharacteristic, to central: CBCentral) -> Bool {
        let sent = peripheralManager.updateValue(data, for: char, onSubscribedCentrals: [central])
        if !sent {
            pendingLock.withLock {
                pendingNotifications.append(PendingNotification(
                    data: data, characteristic: char, central: central
                ))
            }
            logger.warning("Notification queued for retry (transmit queue full)")
        }
        return sent
    }

    /// Start advertising the TouchBridge BLE service.
    public func startAdvertising() {
        wantsAdvertising = true
        startAdvertisingIfReady()
    }

    private func startAdvertisingIfReady() {
        guard isReady, isServiceRegistered, !isAdvertising else {
            logger.info("Deferring advertising: ready=\(self.isReady), serviceRegistered=\(self.isServiceRegistered), advertising=\(self.isAdvertising)")
            return
        }

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: serviceUUID)],
            CBAdvertisementDataLocalNameKey: "TouchBridge",
        ])
        isAdvertising = true
        logger.info("Started advertising TouchBridge service")
    }

    /// Stop advertising.
    public func stopAdvertising() {
        wantsAdvertising = false
        guard isAdvertising else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        logger.info("Stopped advertising")
    }

    /// Send an encrypted challenge to a specific connected central.
    public func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        let info = centralsLock.withLock { connectedCentrals[centralID] }
        guard let info,
              info.subscribedToChallenge,
              let char = challengeChar else {
            logger.warning("Cannot send challenge: central \(centralID) not subscribed")
            return false
        }

        return sendOrQueue(data, for: char, to: info.central)
    }

    /// Send pairing data to a specific connected central.
    public func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        let info = centralsLock.withLock { connectedCentrals[centralID] }
        guard let info,
              info.subscribedToPairing,
              let char = pairingChar else {
            logger.warning("Cannot send pairing data: central \(centralID) not subscribed")
            return false
        }

        return sendOrQueue(data, for: char, to: info.central)
    }

    /// Send session key data to a specific connected central.
    public func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool {
        let info = centralsLock.withLock { connectedCentrals[centralID] }
        guard let info,
              info.subscribedToSession,
              let char = sessionKeyChar else {
            logger.warning("Cannot send session key: central \(centralID) not subscribed")
            return false
        }

        return sendOrQueue(data, for: char, to: info.central)
    }

    /// Get the list of connected central UUIDs.
    public var connectedCentralIDs: [UUID] {
        centralsLock.withLock { Array(connectedCentrals.keys) }
    }

    /// Get the average RSSI for a connected central.
    public func averageRSSI(for centralID: UUID) -> Int? {
        centralsLock.withLock { connectedCentrals[centralID]?.averageRSSI }
    }

    // MARK: - Private

    private func buildService() {
        let serviceUUID = CBUUID(string: self.serviceUUID)

        // Session key exchange: writable by central + notifiable
        sessionKeyChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID),
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        // Challenge: Mac notifies iPhone (read-only from central perspective)
        challengeChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.challengeCharUUID),
            properties: [.notify],
            value: nil,
            permissions: []
        )

        // Response: iPhone writes signed response
        responseChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.responseCharUUID),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        // Pairing: bidirectional
        pairingChar = CBMutableCharacteristic(
            type: CBUUID(string: TouchBridgeConstants.pairingCharUUID),
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        let svc = CBMutableService(type: serviceUUID, primary: true)
        svc.characteristics = [sessionKeyChar!, challengeChar!, responseChar!, pairingChar!]
        service = svc

        peripheralManager.add(svc)
        logger.info("TouchBridge GATT service registered")
    }

    private func routeWrite(for characteristicUUID: CBUUID, data: Data, centralID: UUID) {
        let sessionUUID = CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID)
        let responseUUID = CBUUID(string: TouchBridgeConstants.responseCharUUID)
        let pairingUUID = CBUUID(string: TouchBridgeConstants.pairingCharUUID)

        if characteristicUUID == sessionUUID {
            if let responseData = delegate?.bleServer(self, didReceiveSessionKey: data, from: centralID) {
                // Send our session key back via notify
                _ = sendSessionKey(responseData, to: centralID)
            }
        } else if characteristicUUID == responseUUID {
            delegate?.bleServer(self, didReceiveResponse: data, from: centralID)
        } else if characteristicUUID == pairingUUID {
            delegate?.bleServer(self, didReceivePairingData: data, from: centralID)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEServer: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            logger.info("Bluetooth powered on")
            isReady = true
            buildService()
        case .poweredOff:
            logger.warning("Bluetooth powered off")
            isReady = false
            isAdvertising = false
            isServiceRegistered = false
        case .unauthorized:
            logger.error("Bluetooth unauthorized — check Info.plist NSBluetoothAlwaysUsageDescription")
            isReady = false
        case .unsupported:
            logger.error("Bluetooth not supported on this hardware")
            isReady = false
        default:
            logger.info("Bluetooth state: \(String(describing: peripheral.state.rawValue))")
            isReady = false
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error {
            logger.error("Failed to add service: \(error.localizedDescription)")
        } else {
            logger.info("Service added successfully")
            isServiceRegistered = true
            if wantsAdvertising {
                startAdvertisingIfReady()
            }
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            isAdvertising = false
        } else {
            logger.info("Advertising started")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let centralID = central.identifier
        logger.info("Central \(centralID) subscribed to \(characteristic.uuid)")

        let isNewCentral: Bool = centralsLock.withLock {
            if connectedCentrals[centralID] == nil {
                connectedCentrals[centralID] = ConnectedCentral(central: central)
                return true
            }
            return false
        }
        if isNewCentral {
            delegate?.bleServer(self, centralDidConnect: centralID)
        }

        let charUUID = characteristic.uuid
        centralsLock.withLock {
            if charUUID == CBUUID(string: TouchBridgeConstants.challengeCharUUID) {
                connectedCentrals[centralID]?.subscribedToChallenge = true
            } else if charUUID == CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID) {
                connectedCentrals[centralID]?.subscribedToSession = true
            } else if charUUID == CBUUID(string: TouchBridgeConstants.pairingCharUUID) {
                connectedCentrals[centralID]?.subscribedToPairing = true
            }
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let centralID = central.identifier
        logger.info("Central \(centralID) unsubscribed from \(characteristic.uuid)")

        let charUUID = characteristic.uuid
        centralsLock.withLock {
            if charUUID == CBUUID(string: TouchBridgeConstants.challengeCharUUID) {
                connectedCentrals[centralID]?.subscribedToChallenge = false
            } else if charUUID == CBUUID(string: TouchBridgeConstants.sessionKeyCharUUID) {
                connectedCentrals[centralID]?.subscribedToSession = false
            } else if charUUID == CBUUID(string: TouchBridgeConstants.pairingCharUUID) {
                connectedCentrals[centralID]?.subscribedToPairing = false
            }
        }

        // If no subscriptions remain, treat as disconnected
        let shouldDisconnect: Bool = centralsLock.withLock {
            guard let info = connectedCentrals[centralID] else { return false }
            if !info.subscribedToChallenge && !info.subscribedToSession && !info.subscribedToPairing {
                connectedCentrals.removeValue(forKey: centralID)
                return true
            }
            return false
        }
        if shouldDisconnect {
            delegate?.bleServer(self, centralDidDisconnect: centralID)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            // Enforce max message size
            guard data.count <= TouchBridgeConstants.maxMessageSize else {
                logger.warning("Rejecting oversized write: \(data.count) bytes")
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            let centralID = request.central.identifier

            // Track the central if not yet tracked
            let isNewCentral: Bool = centralsLock.withLock {
                if connectedCentrals[centralID] == nil {
                    connectedCentrals[centralID] = ConnectedCentral(central: request.central)
                    return true
                }
                return false
            }
            if isNewCentral {
                delegate?.bleServer(self, centralDidConnect: centralID)
            }

            routeWrite(
                for: request.characteristic.uuid,
                data: data,
                centralID: centralID
            )

            peripheral.respond(to: request, withResult: .success)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Transmit queue has space again — flush pending notifications.
        let pending = pendingLock.withLock {
            let taken = pendingNotifications
            pendingNotifications.removeAll()
            return taken
        }

        for notification in pending {
            let sent = peripheralManager.updateValue(
                notification.data,
                for: notification.characteristic,
                onSubscribedCentrals: [notification.central]
            )
            if !sent {
                // Queue still full — re-queue and wait for the next ready callback.
                pendingLock.withLock {
                    pendingNotifications.append(notification)
                }
                logger.warning("Transmit queue still full after retry — re-queued")
                return
            }
        }

        if !pending.isEmpty {
            logger.info("Flushed \(pending.count) pending notification(s)")
        }
    }
}
