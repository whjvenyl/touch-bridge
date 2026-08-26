import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

/// Coordinates all daemon components: BLE server, challenge management,
/// pairing, session crypto, and audit logging.
///
/// This is the central integration point that wires events from the BLE layer
/// to the crypto and storage layers.
public final class DaemonCoordinator: NSObject, PAMAuthHandler, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "Coordinator")

    // Components
    public let bleServer: any BLEServerInterface
    public let challengeManager: ChallengeManager
    public let pairingManager: PairingManager
    public let keychainStore: KeychainStore
    public let auditLog: AuditLog

    /// Guards `sessions` and `pendingAuthentications` — both are mutated from
    /// CoreBluetooth delegate callbacks, detached Tasks, and PAM auth calls,
    /// which run on different threads.
    ///
    /// Uses `NSRecursiveLock` for defense-in-depth: if a future callback path
    /// ever re-enters the lock (e.g. a delegate callback that triggers another
    /// event synchronously), a plain `NSLock` would deadlock silently.
    private let stateLock = NSRecursiveLock()

    // Per-central session state (access only while holding stateLock)
    private var sessions: [UUID: SessionState] = [:]

    /// Pending PAM authentications awaiting challenge results.
    /// Each auth broadcast stores the same OnceContinuation under multiple challenge IDs
    /// (one per device), so the first valid response wins and subsequent responses are no-ops.
    /// (access only while holding stateLock)
    private var pendingAuthentications: [UUID: OnceContinuation] = [:]

    /// Periodic maintenance task pruning expired challenges and replay nonces.
    private var pruneTask: Task<Void, Never>?

    /// Callback invoked when a challenge is verified or fails.
    public var onChallengeResult: ((UUID, ChallengeResult, String?) -> Void)?

    /// Callback invoked when pairing completes.
    public var onPairingComplete: ((PairedDevice) -> Void)?

    private struct SessionState {
        var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?
        var sessionCrypto: SessionCrypto?
        var deviceID: String?
    }

    public init(
        keychainStore: KeychainStore = KeychainStore(),
        auditLog: AuditLog = AuditLog(),
        challengeManager: ChallengeManager = ChallengeManager(),
        pairingManager: PairingManager? = nil,
        rssiThreshold: Int = TouchBridgeConstants.defaultRSSIThreshold,
        serviceUUID: String = TouchBridgeConstants.serviceUUID,
        bleServer: (any BLEServerInterface)? = nil
    ) {
        self.keychainStore = keychainStore
        self.auditLog = auditLog
        self.challengeManager = challengeManager
        self.bleServer = bleServer ?? BLEServer(rssiThreshold: rssiThreshold, serviceUUID: serviceUUID)

        let pm = pairingManager ?? PairingManager(keychainStore: keychainStore, serviceUUID: serviceUUID)
        self.pairingManager = pm

        super.init()
        self.bleServer.delegate = self
    }

    // MARK: - Public API

    /// Start the daemon: begin advertising over BLE.
    public func start() {
        logger.info("DaemonCoordinator starting")
        // BLEServer will start advertising once Bluetooth is powered on
        // (handled in peripheralManagerDidUpdateState via delegate)

        // Unanswered challenges and replay nonces otherwise accumulate for the
        // lifetime of the daemon — prune them periodically.
        pruneTask?.cancel()
        pruneTask = Task { [challengeManager] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await challengeManager.pruneExpired()
            }
        }
    }

    /// Start advertising (call after BLE is ready).
    public func startAdvertising() {
        bleServer.startAdvertising()
    }

    /// Stop advertising and clean up.
    public func stop() {
        bleServer.stopAdvertising()
        pruneTask?.cancel()
        pruneTask = nil
        stateLock.withLock { sessions.removeAll() }
        logger.info("DaemonCoordinator stopped")
    }

    /// Issue a challenge to a specific connected device.
    ///
    /// - Parameters:
    ///   - centralID: The BLE central UUID of the connected companion.
    ///   - reason: The reason string to show on the companion (e.g., "sudo").
    /// - Returns: The challenge ID, or nil if sending failed.
    public func issueChallenge(to centralID: UUID, reason: String) async -> UUID? {
        let session = stateLock.withLock { sessions[centralID] }
        guard let session,
              let crypto = session.sessionCrypto,
              let deviceID = session.deviceID else {
            logger.warning("Cannot issue challenge: no session for central \(centralID)")
            return nil
        }

        do {
            let challenge = try await challengeManager.issue(for: deviceID)

            // Encrypt nonce for wire transfer
            let encryptedNonce = try crypto.encrypt(plaintext: challenge.nonce)

            let msg = TBChallengeIssued.with {
                $0.challengeID = challenge.id.uuidString
                $0.encryptedNonce = encryptedNonce
                $0.reason = reason
                $0.expiryUnix = UInt64(challenge.expiresAt.timeIntervalSince1970)
            }

            let wireData = try WireFormat.encode(.challengeIssued, msg)
            let sent = bleServer.sendChallenge(wireData, to: centralID)

            if sent {
                logger.info("Challenge \(challenge.id) issued to \(centralID)")
                await auditLog.log(AuditEntry(
                    sessionID: challenge.id.uuidString,
                    surface: reason,
                    result: "ISSUED",
                    rssi: bleServer.averageRSSI(for: centralID)
                ))
                return challenge.id
            } else {
                logger.warning("Failed to send challenge over BLE")
                return nil
            }
        } catch {
            logger.error("Challenge issuance failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Authenticate a PAM request by issuing challenges to all identified companion devices.
    ///
    /// Called by `SocketServer` when a PAM module connects.
    /// Broadcasts to every connected, paired device simultaneously.
    /// The first valid response wins — other challenges expire naturally.
    /// Blocks until a response arrives or the timeout expires.
    public func authenticateFromPAM(
        user: String,
        service: String,
        pid: Int,
        timeout: TimeInterval
    ) async -> (success: Bool, reason: String?) {
        // Only challenge sessions that have completed ECDH AND identified as a known paired device.
        // Unknown/anonymous centrals (e.g. stranger's phone that happens to be nearby) are excluded.
        let targets = stateLock.withLock {
            sessions.filter { $0.value.sessionCrypto != nil && $0.value.deviceID != nil }.map(\.key)
        }

        guard !targets.isEmpty else {
            logger.warning("PAM auth: no identified companion connected (ready=\(self.readyCentrals.count))")
            await auditLog.log(AuditEntry(
                sessionID: UUID().uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                deviceID: "",
                result: "FAILED_NO_DEVICE"
            ))
            return (false, "no_companion_connected")
        }

        logger.info("PAM auth: broadcasting challenge to \(targets.count) device(s)")

        // Race: first device response OR global timeout — whichever fires first wins.
        //
        // We use a single withCheckedContinuation + two unstructured Tasks (challenge dispatch
        // and timeout) rather than withTaskGroup, because withTaskGroup waits for ALL child
        // tasks to finish after the closure returns. That means if the timeout fires first,
        // the group would hang indefinitely waiting for the challenge-dispatch task to return
        // — which it never does because withCheckedContinuation only returns when resumed.
        //
        // With two unstructured Tasks sharing one OnceContinuation, the first resume wins;
        // subsequent resumes (from late responses or cleanup) are silent no-ops.
        // Challenge IDs issued for THIS auth — cleaned up once the auth resolves,
        // so losing/timed-out entries don't leak in pendingAuthentications.
        let issuedIDs = LockedBox<[UUID]>([])

        let result: ChallengeResult? = await withCheckedContinuation { outer in
            let wrapped = OnceContinuation(outer)

            // Challenge-dispatch task: issue to all identified devices, then just wait.
            Task {
                var issued = 0
                for centralID in targets {
                    if let challengeID = await self.issueChallenge(to: centralID, reason: service) {
                        self.stateLock.withLock {
                            self.pendingAuthentications[challengeID] = wrapped
                        }
                        issuedIDs.mutate { $0.append(challengeID) }
                        issued += 1
                    }
                }
                if issued == 0 {
                    wrapped.resume(returning: .unknownChallenge)
                }
                // Otherwise: wait — the first device response (or timeout below) resumes outer.
            }

            // Timeout task: resumes with nil after the deadline.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                wrapped.resume(returning: nil)
            }
        }

        // The auth is resolved — drop every challenge entry it created (the winning
        // response already removed its own; siblings and timeouts are removed here).
        stateLock.withLock {
            for id in issuedIDs.value {
                pendingAuthentications.removeValue(forKey: id)
            }
        }

        if let result, result == .verified {
            return (true, nil)
        }

        let reason: String
        switch result {
        case .expired: reason = "challenge_expired"
        case .invalidSignature: reason = "invalid_signature"
        case .replayDetected: reason = "replay_detected"
        case .unknownChallenge: reason = "challenge_failed"
        case .keyInvalidated: reason = "key_invalidated"
        case nil: reason = "timeout"
        case .verified: reason = "unknown" // unreachable
        }

        return (false, reason)
    }

    /// Get all connected central UUIDs that have completed ECDH.
    public var readyCentrals: [UUID] {
        stateLock.withLock {
            sessions.filter { $0.value.sessionCrypto != nil }.map(\.key)
        }
    }

    /// Get all connected centrals that are both encrypted and recognised as a
    /// previously paired device, so they can receive challenges.
    public var identifiedCentrals: [UUID] {
        stateLock.withLock {
            sessions.filter { $0.value.sessionCrypto != nil && $0.value.deviceID != nil }.map(\.key)
        }
    }
}

// MARK: - DaemonControlHandler

extension DaemonCoordinator: DaemonControlHandler {

    public func getDaemonStatus() async -> DaemonStatus {
        // Paired devices from keychain
        let paired: [PairedDevice]
        do {
            paired = try keychainStore.listPairedDevices()
        } catch {
            logger.error("Failed to list paired devices: \(error.localizedDescription)")
            paired = []
        }

        // Connected centrals with identification state
        let connected: [(UUID, SessionState)] = stateLock.withLock {
            sessions.map { ($0.key, $0.value) }
        }

        let connectedDeviceIDs = Set(connected.compactMap { $0.1.deviceID })

        let pairedInfo = paired.map { device in
            DaemonStatus.PairedDeviceInfo(
                deviceID: device.deviceID,
                displayName: device.displayName,
                pairedAt: device.pairedAt,
                isConnected: connectedDeviceIDs.contains(device.deviceID)
            )
        }

        let connectedInfo = connected.map { (centralID, state) in
            DaemonStatus.ConnectedDeviceInfo(
                centralID: centralID.uuidString,
                deviceID: state.deviceID,
                identified: state.deviceID != nil && state.sessionCrypto != nil
            )
        }

        let pairingActive = await pairingManager.isPairingActive

        return DaemonStatus(
            pairedDevices: pairedInfo,
            connectedDevices: connectedInfo,
            isAdvertising: bleServer.isAdvertising,
            isPairingActive: pairingActive
        )
    }

    public func startPairing() async throws -> Data {
        try await pairingManager.generatePairingQRData()
    }

    public func cancelPairing() async {
        await pairingManager.cancelPairing()
    }

    public func unpairDevice(deviceID: String) async throws {
        try keychainStore.removePairedDevice(deviceID: deviceID)
        logger.info("Unpaired device \(deviceID)")
    }
}

// MARK: - BLEServerDelegate

extension DaemonCoordinator: BLEServerDelegate {

    public func bleServer(_ server: any BLEServerInterface, centralDidConnect centralID: UUID) {
        logger.info("Central connected: \(centralID)")
        stateLock.withLock { sessions[centralID] = SessionState() }
    }

    public func bleServer(_ server: any BLEServerInterface, centralDidDisconnect centralID: UUID) {
        logger.info("Central disconnected: \(centralID)")
        stateLock.withLock { _ = sessions.removeValue(forKey: centralID) }
    }

    public func bleServer(_ server: any BLEServerInterface, didReceiveSessionKey data: Data, from centralID: UUID) -> Data? {
        logger.info("Received session key from \(centralID)")

        do {
            // Import their ephemeral public key
            let theirPublic = try SessionCrypto.importPublicKey(data)

            // Generate our ephemeral key pair
            let (myPrivate, myPublic) = SessionCrypto.generateEphemeralKeyPair()

            // Derive session
            let session = try SessionCrypto.deriveSession(myPrivate: myPrivate, theirPublic: theirPublic)

            stateLock.withLock {
                var state = sessions[centralID] ?? SessionState()
                state.ephemeralPrivateKey = myPrivate
                state.sessionCrypto = session
                state.deviceID = nil
                sessions[centralID] = state
            }

            logger.info("ECDH session established with \(centralID)")

            // Return our public key for them to derive the same session
            return SessionCrypto.exportPublicKey(myPublic)
        } catch {
            logger.error("ECDH key exchange failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func bleServer(_ server: any BLEServerInterface, didReceivePairingData data: Data, from centralID: UUID) {
        logger.info("Received pairing data from \(centralID)")

        Task {
            do {
                // Detect wire-format messages (version=1, valid type byte) vs legacy raw-JSON pairing.
                // Identify messages always use wire format; pairing requests use raw JSON currently.
                if data.count >= 2, data[data.startIndex] == 1,
                   let msgType = TBMessageType(rawValue: Int(data[data.startIndex + 1])),
                   msgType == .identify {
                    try await handleIdentify(data: data, from: centralID)
                    return
                }

                let (_, payload) = try WireFormat.decode(data: data)
                let request = try WireFormat.decodePayload(TBPairRequest.self, from: payload)

                let device = try await pairingManager.validatePairingRequest(
                    token: request.pairingToken,
                    devicePublicKey: request.publicKey,
                    deviceName: request.deviceName,
                    deviceID: request.deviceID.isEmpty ? centralID.uuidString : request.deviceID
                )

                try await pairingManager.completePairing(device: device)
                stateLock.withLock { sessions[centralID]?.deviceID = device.deviceID }

                // Send acceptance response
                let response = TBPairResponse.with {
                    $0.deviceID = device.deviceID
                    $0.publicKey = Data()
                    $0.accepted = true
                }
                let wireResponse = try WireFormat.encode(.pairResponse, response)
                _ = server.sendPairingData(wireResponse, to: centralID)

                await auditLog.log(AuditEntry(
                    sessionID: centralID.uuidString,
                    surface: "pairing",
                    companionDevice: device.displayName,
                    deviceID: device.deviceID,
                    result: "PAIRED"
                ))

                onPairingComplete?(device)
                logger.info("Pairing completed for \(device.displayName)")
            } catch {
                logger.error("Pairing failed: \(error.localizedDescription)")

                // Send rejection
                if let response = try? WireFormat.encode(.pairResponse, TBPairResponse.with {
                    $0.deviceID = ""
                    $0.publicKey = Data()
                    $0.accepted = false
                }) {
                    _ = server.sendPairingData(response, to: centralID)
                }
            }
        }
    }

    public func bleServer(_ server: any BLEServerInterface, didReceiveResponse data: Data, from centralID: UUID) {
        logger.info("Received challenge response from \(centralID)")

        Task {
            do {
                let (msgType, payload) = try WireFormat.decode(data: data)

                // Handle companion error messages (e.g. key invalidated).
                // The error payload is AES-GCM encrypted with the session key.
                if msgType == .error {
                    guard let crypto = stateLock.withLock({ sessions[centralID]?.sessionCrypto }) else {
                        logger.warning("Error message from \(centralID) but no session crypto — ignoring")
                        return
                    }
                    let plaintext = try crypto.decrypt(ciphertext: payload)
                    let errMsg = try WireFormat.decodePayload(TBError.self, from: plaintext)
                    logger.warning("Companion error \(errMsg.code): \(errMsg.description_p)")

                    if errMsg.code == TBErrorCode.keyInvalidated.rawValue,
                       let challengeID = UUID(uuidString: errMsg.challengeID) {
                        // Log before resuming so callers that await the result immediately
                        // and then read the audit log always see the entry.
                        await auditLog.log(AuditEntry(
                            sessionID: errMsg.challengeID,
                            surface: "challenge",
                            deviceID: errMsg.description_p,
                            result: "FAILED_KEY_INVALIDATED"
                        ))
                        let continuation = stateLock.withLock {
                            pendingAuthentications.removeValue(forKey: challengeID)
                        }
                        continuation?.resume(returning: .keyInvalidated)
                    }
                    return
                }

                let response = try WireFormat.decodePayload(TBChallengeResponse.self, from: payload)

                guard let challengeID = UUID(uuidString: response.challengeID) else {
                    logger.error("Invalid challenge ID in response")
                    return
                }

                let publicKey = try keychainStore.retrievePublicKey(for: response.deviceID)
                let startTime = Date()

                let result = await challengeManager.verify(
                    challengeID: challengeID,
                    signature: response.signature,
                    publicKey: publicKey
                )

                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

                let resultString: String
                switch result {
                case .verified: resultString = "VERIFIED"
                case .expired: resultString = "FAILED_TIMEOUT"
                case .invalidSignature: resultString = "FAILED_SIGNATURE"
                case .replayDetected: resultString = "FAILED_REPLAY"
                case .unknownChallenge: resultString = "FAILED_SIGNATURE"
                case .keyInvalidated: resultString = "FAILED_KEY_INVALIDATED"
                }

                await auditLog.log(AuditEntry(
                    sessionID: response.challengeID,
                    surface: "challenge",
                    companionDevice: response.deviceID,
                    deviceID: response.deviceID,
                    result: resultString,
                    rssi: server.averageRSSI(for: centralID),
                    latencyMs: latencyMs
                ))

                // Resume any pending PAM authentication continuation
                let continuation = stateLock.withLock {
                    pendingAuthentications.removeValue(forKey: challengeID)
                }
                continuation?.resume(returning: result)

                onChallengeResult?(challengeID, result, response.deviceID)

                logger.info("Challenge \(response.challengeID): \(resultString)")
            } catch {
                logger.error("Response processing failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Identify

    /// Handle an encrypted identify message from a reconnecting companion.
    ///
    /// A previously-paired device sends this after ECDH to tell the daemon its deviceID
    /// without going through a full pairing ceremony. The daemon looks up the deviceID in
    /// the keychain and, if found, marks the session as identified so it can receive challenges.
    private func handleIdentify(data: Data, from centralID: UUID) async throws {
        guard let crypto = stateLock.withLock({ sessions[centralID]?.sessionCrypto }) else {
            logger.warning("Identify from \(centralID): no session crypto — ignoring")
            return
        }

        // Strip the 2-byte wire header, then decrypt.
        let encryptedPayload = data.dropFirst(2)
        let plaintext = try crypto.decrypt(ciphertext: Data(encryptedPayload))

        // The payload is a JSON object with deviceID and deviceName.
        // We use a local struct to avoid importing TouchBridgeProtocol's IdentifyMessage
        // (which is fine here since we're in the daemon — same package as DaemonCoordinator).
        let msg = try WireFormat.decodePayload(TBIdentify.self, from: plaintext)

        // Verify this device is actually in the keychain (was paired at some point).
        guard (try? keychainStore.retrievePairedDevice(deviceID: msg.deviceID)) != nil else {
            logger.warning("Identify from \(centralID): unknown deviceID \(msg.deviceID) — ignoring")
            return
        }

        stateLock.withLock { sessions[centralID]?.deviceID = msg.deviceID }
        logger.info("Identified \(msg.deviceName) (\(msg.deviceID)) on central \(centralID)")

        await auditLog.log(AuditEntry(
            sessionID: centralID.uuidString,
            surface: "identify",
            companionDevice: msg.deviceName,
            deviceID: msg.deviceID,
            result: "IDENTIFIED"
        ))
    }
}

// MARK: - LockedBox

/// Minimal lock-guarded mutable container for values shared across concurrent Tasks.
final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSRecursiveLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        lock.withLock { _value }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.withLock { body(&_value) }
    }
}

// MARK: - OnceContinuation

/// Wraps a `CheckedContinuation` so it can safely be resumed at most once.
///
/// `authenticateFromPAM` stores the same `OnceContinuation` under every challenge ID
/// it broadcasts. The first resume (from a device response or the timeout Task) wins;
/// all subsequent calls are silent no-ops.
///
/// Holds `ChallengeResult?` so the timeout Task can pass `nil` ("no result = timeout")
/// while device-response tasks pass a concrete `ChallengeResult`.
final class OnceContinuation: @unchecked Sendable {
    private var inner: CheckedContinuation<ChallengeResult?, Never>?
    private let lock = NSRecursiveLock()

    init(_ continuation: CheckedContinuation<ChallengeResult?, Never>) {
        self.inner = continuation
    }

    func resume(returning value: ChallengeResult?) {
        lock.withLock {
            guard let c = inner else { return }
            inner = nil
            c.resume(returning: value)
        }
    }
}
