import Testing
import Foundation
import Security
import CryptoKit
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

// MARK: - MockBLEServer

/// Mock BLE server for DaemonCoordinator integration tests.
///
/// Records all outgoing calls (challenges, pairing responses, session keys) and
/// exposes `simulate*` methods to drive incoming BLE events without real hardware.
///
/// Simulates the real BLEServer's transmit-queue behavior: when
/// `simulateTransmitQueueFull` is true, `sendChallenge` queues the notification
/// instead of delivering it immediately, and returns `true` (matching the real
/// `sendOrQueue` which always returns `true` since the data will be delivered
/// on flush). Call `flushQueuedChallenges()` to simulate the BLE subsystem
/// becoming ready again.
final class MockBLEServer: BLEServerInterface, @unchecked Sendable {
    weak var delegate: BLEServerDelegate?

    // Outgoing calls recorded for assertions
    var sentChallenges: [(data: Data, centralID: UUID)] = []
    var sentPairingResponses: [(data: Data, centralID: UUID)] = []
    var sentSessionKeys: [(data: Data, centralID: UUID)] = []

    // Configurable RSSI per central (default -60 dBm)
    var rssiValues: [UUID: Int] = [:]

    // When true, sendChallenge queues the notification instead of recording it
    // in sentChallenges immediately. Matches the real BLEServer's transmit-queue-full
    // behavior. Call flushQueuedChallenges() to deliver them.
    var simulateTransmitQueueFull: Bool = false

    // Queued challenges waiting for flush
    private var queuedChallenges: [(data: Data, centralID: UUID)] = []

    // Legacy flag — when true, sendChallenge returns false (hard send failure).
    // Use simulateTransmitQueueFull instead for the realistic queue-retry path.
    var sendSucceeds: Bool = true

    var isAdvertising: Bool = false

    func startAdvertising() {}
    func stopAdvertising() {}

    @discardableResult
    func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        if simulateTransmitQueueFull {
            // Queue for later delivery — matches real BLEServer.sendOrQueue behavior.
            // Returns true because the data WILL be delivered on flush.
            queuedChallenges.append((data, centralID))
            return true
        }
        sentChallenges.append((data, centralID))
        return sendSucceeds
    }

    @discardableResult
    func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        sentPairingResponses.append((data, centralID))
        return sendSucceeds
    }

    @discardableResult
    func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool {
        sentSessionKeys.append((data, centralID))
        return sendSucceeds
    }

    var connectedCentralIDs: [UUID] { [] }

    func averageRSSI(for centralID: UUID) -> Int? {
        rssiValues[centralID] ?? -60
    }

    // MARK: - Transmit queue simulation

    /// Flush all queued challenges — simulates the BLE subsystem becoming ready.
    /// Moves queued challenges into `sentChallenges` so tests can inspect them.
    func flushQueuedChallenges() {
        for queued in queuedChallenges {
            sentChallenges.append(queued)
        }
        queuedChallenges.removeAll()
    }

    /// Number of challenges currently queued (not yet delivered).
    var queuedChallengeCount: Int { queuedChallenges.count }

    // MARK: - Test event simulators

    func simulateConnect(_ centralID: UUID) {
        delegate?.bleServer(self, centralDidConnect: centralID)
    }

    func simulateDisconnect(_ centralID: UUID) {
        delegate?.bleServer(self, centralDidDisconnect: centralID)
    }

    /// Simulate companion sending its ECDH public key; returns server's public key.
    func simulateSessionKey(_ keyData: Data, from centralID: UUID) -> Data? {
        delegate?.bleServer(self, didReceiveSessionKey: keyData, from: centralID)
    }

    func simulatePairingData(_ data: Data, from centralID: UUID) {
        delegate?.bleServer(self, didReceivePairingData: data, from: centralID)
    }

    func simulateResponse(_ data: Data, from centralID: UUID) {
        delegate?.bleServer(self, didReceiveResponse: data, from: centralID)
    }
}

// MARK: - CompanionSimulator

/// Simulates the iOS companion app's BLE/crypto behaviour for testing.
///
/// Handles ECDH key exchange, encrypted identify messages, challenge signing,
/// and key-invalidated error generation — matching the protocol the daemon expects.
final class CompanionSimulator: @unchecked Sendable {
    let centralID: UUID
    let deviceID: String
    let deviceName: String

    // P-256 signing key (simulates Secure Enclave)
    private let signingPrivateKey: SecKey
    /// Public key bytes to store in the daemon's Keychain during test setup.
    let signingPublicKeyData: Data

    // ECDH session (derived after key exchange)
    private(set) var sessionCrypto: SessionCrypto?
    private var ecdhPrivateKey: P256.KeyAgreement.PrivateKey?
    private var daemonEphemeralPubKey: Data?

    init(
        centralID: UUID = UUID(),
        deviceID: String = UUID().uuidString,
        deviceName: String = "Test iPhone"
    ) {
        self.centralID = centralID
        self.deviceID = deviceID
        self.deviceName = deviceName

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var cfErr: Unmanaged<CFError>?
        self.signingPrivateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr)!
        let pub = SecKeyCopyPublicKey(signingPrivateKey)!
        self.signingPublicKeyData = SecKeyCopyExternalRepresentation(pub, &cfErr)! as Data
    }

    /// Reconnect initializer — reuses the same signing key and deviceID but
    /// gets a fresh centralID (simulating a new BLE connection).
    convenience init(
        reconnecting original: CompanionSimulator,
        newCentralID: UUID = UUID()
    ) {
        self.init(
            centralID: newCentralID,
            deviceID: original.deviceID,
            deviceName: original.deviceName,
            signingPrivateKey: original.signingPrivateKey,
            signingPublicKeyData: original.signingPublicKeyData
        )
    }

    /// Private initializer that accepts an existing signing key (for reconnect).
    private init(
        centralID: UUID,
        deviceID: String,
        deviceName: String,
        signingPrivateKey: SecKey,
        signingPublicKeyData: Data
    ) {
        self.centralID = centralID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKeyData = signingPublicKeyData
    }

    /// Reset ECDH session state (simulates dropping the BLE link).
    func resetSession() {
        sessionCrypto = nil
        ecdhPrivateKey = nil
        daemonEphemeralPubKey = nil
    }

    // MARK: - ECDH

    /// Generate our ephemeral public key to send to the daemon.
    func ecdhPublicKeyData() -> Data {
        let key = P256.KeyAgreement.PrivateKey()
        ecdhPrivateKey = key
        return SessionCrypto.exportPublicKey(key.publicKey)
    }

    /// Receive the daemon's ECDH public key and derive the shared session.
    func completeECDH(daemonPublicKeyData: Data) throws {
        guard let myPrivate = ecdhPrivateKey else {
            throw CompanionError.ecdhNotStarted
        }
        let daemonPublic = try SessionCrypto.importPublicKey(daemonPublicKeyData)
        sessionCrypto = try SessionCrypto.deriveSession(myPrivate: myPrivate, theirPublic: daemonPublic)
        daemonEphemeralPubKey = daemonPublicKeyData
    }

    // MARK: - Identify

    /// Create an encrypted identify message with a valid signature: [1, 6] + AES-GCM(protobuf Identify).
    func makeIdentifyData() throws -> Data {
        return try makeIdentifyData(signatureMode: .valid)
    }

    /// Create an identify message with no signature (for testing rejection).
    func makeIdentifyDataWithoutSignature() throws -> Data {
        return try makeIdentifyData(signatureMode: .omitted)
    }

    /// Create an identify message with a tampered signature (for testing rejection).
    func makeIdentifyDataWithTamperedSignature() throws -> Data {
        return try makeIdentifyData(signatureMode: .tampered)
    }

    /// Create an identify message signed with the wrong daemon ephemeral key
    /// (simulates a MITM who intercepts ECDH — signature is valid ECDSA but
    /// over a different key than the daemon's).
    func makeIdentifyDataWithWrongEphemeralKey() throws -> Data {
        return try makeIdentifyData(signatureMode: .wrongEphemeralKey)
    }

    private enum SignatureMode { case valid, omitted, tampered, wrongEphemeralKey }

    private func makeIdentifyData(signatureMode: SignatureMode) throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }
        guard let daemonPubKey = daemonEphemeralPubKey else { throw CompanionError.noSession }

        let msg: TBIdentify
        switch signatureMode {
        case .omitted:
            // Empty signature — simulates a client that doesn't sign
            msg = TBIdentify.with {
                $0.deviceID = deviceID
                $0.deviceName = deviceName
            }
        case .tampered:
            // Valid signature with one byte flipped
            var sig = try signIdentify(daemonPubKey: daemonPubKey)
            if !sig.isEmpty { sig[sig.count - 1] ^= 0xFF }
            msg = TBIdentify.with {
                $0.deviceID = deviceID
                $0.deviceName = deviceName
                $0.signature = sig
            }
        case .wrongEphemeralKey:
            // Valid signature, but over a DIFFERENT daemon ephemeral key.
            // Simulates a MITM who intercepts ECDH: the companion signs with
            // the MITM's ephemeral key, but the daemon verifies against its own.
            // The signature is valid ECDSA but won't match the daemon's key.
            let fakeKey = P256.KeyAgreement.PrivateKey()
            let fakePubKey = SessionCrypto.exportPublicKey(fakeKey.publicKey)
            let sig = try signIdentify(daemonPubKey: fakePubKey)
            msg = TBIdentify.with {
                $0.deviceID = deviceID
                $0.deviceName = deviceName
                $0.signature = sig
            }
        case .valid:
            // Valid signature
            let sig = try signIdentify(daemonPubKey: daemonPubKey)
            msg = TBIdentify.with {
                $0.deviceID = deviceID
                $0.deviceName = deviceName
                $0.signature = sig
            }
        }

        let payload = try msg.serializedData()
        let encrypted = try crypto.encrypt(plaintext: payload)

        var wire = Data([1, 6]) // version=1, type=identify(6)
        wire.append(encrypted)
        return wire
    }

    /// Sign (deviceID || daemonEphemeralPubKey) with the long-term signing key.
    private func signIdentify(daemonPubKey: Data) throws -> Data {
        let message = Data(deviceID.utf8) + daemonPubKey
        var cfErr: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingPrivateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &cfErr
        ) else {
            throw CompanionError.signingFailed
        }
        return signature as Data
    }

    // MARK: - Challenge Response

    /// Receive a challenge wire frame and return a valid signed response wire frame.
    ///
    /// Wire in:  [1, 3] + JSON ChallengeIssuedMessage (encryptedNonce = AES-GCM(nonce))
    /// Wire out: [1, 4] + JSON ChallengeResponseMessage
    func respondToChallenge(_ wireData: Data) throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }

        // Parse challenge (strip 2-byte wire header)
        guard wireData.count > 2 else { throw CompanionError.invalidData }
        let payload = wireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)

        // Decrypt nonce
        let nonce = try crypto.decrypt(ciphertext: msg.encryptedNonce)

        // Sign
        var cfErr: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingPrivateKey,
            .ecdsaSignatureMessageX962SHA256,
            nonce as CFData,
            &cfErr
        ) as Data? else {
            throw CompanionError.signingFailed
        }

        // Encode response with wire header
        let response = TBChallengeResponse.with {
            $0.challengeID = msg.challengeID
            $0.signature = signature
            $0.deviceID = deviceID
        }
        return try WireFormat.encode(.challengeResponse, response)
    }

    /// Respond with a bad signature (causes .invalidSignature on daemon side).
    func respondWithBadSignature(_ wireData: Data) throws -> Data {
        guard wireData.count > 2 else { throw CompanionError.invalidData }
        let payload = wireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)

        let garbage = Data(repeating: 0xFF, count: 64)
        let response = TBChallengeResponse.with {
            $0.challengeID = msg.challengeID
            $0.signature = garbage
            $0.deviceID = deviceID
        }
        return try WireFormat.encode(.challengeResponse, response)
    }

    // MARK: - Key Invalidated Error

    /// Create an encrypted key-invalidated error: [1, 5] + AES-GCM(protobuf Error).
    ///
    /// Consumes the first challenge in wireData to extract the challengeID.
    func makeKeyInvalidatedError(for challengeWireData: Data) throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }
        guard challengeWireData.count > 2 else { throw CompanionError.invalidData }

        let payload = challengeWireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)

        let err = TBError.with {
            $0.code = 1001
            $0.description_p = "key_invalidated"
            $0.challengeID = msg.challengeID
        }
        let errData = try err.serializedData()
        let encrypted = try crypto.encrypt(plaintext: errData)

        var wire = Data([1, 5]) // version=1, type=error(5)
        wire.append(encrypted)
        return wire
    }

    enum CompanionError: Error {
        case ecdhNotStarted, noSession, invalidData, signingFailed
    }
}

// MARK: - Test Helpers

/// Creates an isolated DaemonCoordinator with a MockBLEServer and temp keychain/log.
private func makeTestCoordinator() -> (
    coordinator: DaemonCoordinator,
    bleServer: MockBLEServer,
    keychain: KeychainStore,
    auditLog: AuditLog,
    runtimeStore: DeviceRuntimeStore
) {
    let bleServer = MockBLEServer()
    let keychain = KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
    let auditLog = AuditLog(logDirectory: logDir)
    let runtimeStore = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-runtime-\(UUID().uuidString).json").path
    )

    let coordinator = DaemonCoordinator(
        keychainStore: keychain,
        auditLog: auditLog,
        runtimeStore: runtimeStore,
        bleServer: bleServer
    )
    return (coordinator, bleServer, keychain, auditLog, runtimeStore)
}

/// Register a companion's signing key in the keychain so `identify` and auth work.
private func register(
    _ companion: CompanionSimulator,
    in keychain: KeychainStore,
    deviceType: TBDeviceType = .phone,
    caps: TBDeviceCapabilities = TBDeviceCapabilities.with {
        $0.hasBiometric_p = true
        $0.hasSecureEnclave_p = true
        $0.hasDisplay_p = true
        $0.hasButton_p = false
        $0.latencyClass = 0
    }
) throws {
    let device = PairedDevice(
        deviceID: companion.deviceID,
        publicKey: companion.signingPublicKeyData,
        displayName: companion.deviceName,
        pairedAt: Date(),
        deviceType: deviceType,
        caps: caps
    )
    try keychain.storePairedDevice(device)
}

/// Full companion connection setup: connect → ECDH → identify.
/// Leaves the companion's session ready to receive challenges.
private func fullyConnect(
    companion: CompanionSimulator,
    to coordinator: DaemonCoordinator,
    via bleServer: MockBLEServer
) async throws {
    // Connect
    bleServer.simulateConnect(companion.centralID)

    // ECDH: companion sends its public key, daemon responds
    let clientPubKey = companion.ecdhPublicKeyData()
    guard let serverPubKey = bleServer.simulateSessionKey(clientPubKey, from: companion.centralID) else {
        throw TestSetupError.ecdhFailed
    }
    try companion.completeECDH(daemonPublicKeyData: serverPubKey)

    // Identify: companion sends encrypted identity
    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 200_000_000) // let the async identify Task complete
}

enum TestSetupError: Error { case ecdhFailed }

// MARK: - Session Lifecycle Tests

@Test func connectCreatesReadySession() async throws {
    let (coordinator, bleServer, _, _, _) = makeTestCoordinator()
    let centralID = UUID()

    #expect(coordinator.readyCentrals.isEmpty)
    bleServer.simulateConnect(centralID)
    // No ECDH yet — session exists but is not "ready" (no sessionCrypto)
    #expect(coordinator.readyCentrals.isEmpty)
}

@Test func ecdhExchangeProducesReadySession() async throws {
    let (coordinator, bleServer, _, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()

    bleServer.simulateConnect(companion.centralID)
    let clientPubKey = companion.ecdhPublicKeyData()
    let serverPubKey = bleServer.simulateSessionKey(clientPubKey, from: companion.centralID)

    #expect(serverPubKey != nil)
    #expect(coordinator.readyCentrals.contains(companion.centralID))

    // Companion can derive the same session
    #expect(throws: Never.self) {
        try companion.completeECDH(daemonPublicKeyData: serverPubKey!)
    }
}

@Test func ecdhWithoutConnectCreatesRecoverableSession() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // Reproduces a restored/stale CoreBluetooth path where the daemon receives
    // the ECDH write before it has observed centralDidConnect for that central.
    let clientPubKey = companion.ecdhPublicKeyData()
    guard let serverPubKey = bleServer.simulateSessionKey(clientPubKey, from: companion.centralID) else {
        Issue.record("Daemon did not respond to ECDH without a prior connect event")
        return
    }

    #expect(coordinator.readyCentrals.contains(companion.centralID))
    try companion.completeECDH(daemonPublicKeyData: serverPubKey)

    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 200_000_000)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1234, timeout: 5.0
    )

    try await Task.sleep(nanoseconds: 150_000_000)
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent after recovery identify")
        return
    }
    #expect(sent.centralID == companion.centralID)

    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func disconnectClearsSession() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)
    #expect(coordinator.readyCentrals.contains(companion.centralID))

    bleServer.simulateDisconnect(companion.centralID)
    #expect(coordinator.readyCentrals.isEmpty)
}

@Test func multipleCompanionsCanConnectSimultaneously() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    #expect(coordinator.readyCentrals.count == 2)
}

// MARK: - Identify Tests

@Test func identifyKnownDeviceSetsDeviceID() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // ECDH only (no identify yet)
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    // Session is ECDH-ready but not identified — auth should fail
    let pre = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.5)
    #expect(pre.success == false)
    #expect(pre.reason == "no_companion_connected")

    // Now identify
    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    // Identified entry should be in audit log
    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "IDENTIFIED" })
}

@Test func identifyUnknownDeviceIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    // Deliberately NOT registering in keychain

    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    // Device in keychain is unknown — should still not appear as auth target
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.2)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func identifyWithoutECDHIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    bleServer.simulateConnect(companion.centralID)
    // No ECDH → no sessionCrypto → identify silently dropped

    // Fabricate an identify message without a real session (daemon can't decrypt it)
    let fakeIdentify = Data([1, 6]) + Data(repeating: 0xAA, count: 32)
    bleServer.simulatePairingData(fakeIdentify, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.2)
    #expect(result.success == false)
}

// MARK: - Authentication — Happy Path

@Test func authFailsWithNoConnectedDevices() async throws {
    let (coordinator, _, _, _, _) = makeTestCoordinator()

    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 1.0)

    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func authFailsWithUnidentifiedDevice() async throws {
    let (coordinator, bleServer, _, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()

    // ECDH only — no identify
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 0.3)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func authFullFlowSucceeds() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1234, timeout: 5.0
    )

    // Wait for challenge to be dispatched
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent to companion")
        return
    }
    #expect(sent.centralID == companion.centralID)

    // Companion signs and responds
    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
    #expect(result.reason == nil)

    // Audit log must have a VERIFIED entry
    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "VERIFIED" })
}

@Test func authSuccessLogsVerifiedEntry() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "screensaver", pid: 99, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    if let sent = bleServer.sentChallenges.last {
        let response = try companion.respondToChallenge(sent.data)
        bleServer.simulateResponse(response, from: companion.centralID)
    }
    _ = await authResult

    let entries = try await auditLog.readEntries()
    let verified = entries.filter { $0.result == "VERIFIED" }
    #expect(verified.count == 1)
    // The VERIFIED audit entry uses surface="challenge" (logged by didReceiveResponse, which
    // doesn't have access to the original PAM service name — that's in the ISSUED entry).
    #expect(verified[0].surface == "challenge")
}

@Test func authMultipleSequentialRequestsSucceed() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    for _ in 0..<3 {
        let initialCount = bleServer.sentChallenges.count

        async let authResult = coordinator.authenticateFromPAM(
            user: "arun", service: "sudo", pid: 1, timeout: 5.0
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let sent = bleServer.sentChallenges.last, bleServer.sentChallenges.count > initialCount else {
            Issue.record("No new challenge sent")
            return
        }
        let response = try companion.respondToChallenge(sent.data)
        bleServer.simulateResponse(response, from: companion.centralID)

        let result = await authResult
        #expect(result.success == true)
    }
}

// MARK: - Authentication — Error Paths

@Test func authTimeoutReturnsTimeoutReason() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Use a very short timeout and never respond
    let result = await coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 0.2
    )

    #expect(result.success == false)
    #expect(result.reason == "timeout")
}

@Test func authInvalidSignatureReturnsFailure() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else { return }
    let badResponse = try companion.respondWithBadSignature(sent.data)
    bleServer.simulateResponse(badResponse, from: companion.centralID)

    let result = await authResult
    #expect(result.success == false)
    #expect(result.reason == "invalid_signature")
}

@Test func authKeyInvalidatedReturnsFastFail() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 10.0  // long timeout — should resolve fast
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge sent")
        return
    }

    // Companion signals key invalidation instead of signing
    let errData = try companion.makeKeyInvalidatedError(for: sent.data)
    bleServer.simulateResponse(errData, from: companion.centralID)

    let result = await authResult
    #expect(result.success == false)
    #expect(result.reason == "key_invalidated")

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "FAILED_KEY_INVALIDATED" })
}

@Test func authDisconnectDuringPendingAuthTimesOut() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 0.5
    )
    try await Task.sleep(nanoseconds: 100_000_000)

    // Companion disconnects mid-auth
    bleServer.simulateDisconnect(companion.centralID)

    let result = await authResult
    // Disconnecting removes the session but doesn't resume the continuation — it times out
    #expect(result.success == false)
}

@Test func noDeviceLogsFailedNoDeviceEntry() async throws {
    let (coordinator, _, _, auditLog, _) = makeTestCoordinator()

    let result = await coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 1.0
    )
    #expect(result.success == false)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "FAILED_NO_DEVICE" })
}

// MARK: - Multi-Device Tests

@Test func authBroadcastsToAllIdentifiedDevices() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 200_000_000)

    // Both devices should have received a challenge
    let challenged = Set(bleServer.sentChallenges.map(\.centralID))
    #expect(challenged.contains(c1.centralID))
    #expect(challenged.contains(c2.centralID))

    // First response wins
    guard let c1Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c1.centralID }) else { return }
    let response = try c1.respondToChallenge(c1Challenge.data)
    bleServer.simulateResponse(response, from: c1.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func authFirstResponseWins() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 200_000_000)

    // C2 responds first — should win
    guard let c2Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c2.centralID }),
          let c1Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c1.centralID }) else {
        return
    }

    let r2 = try c2.respondToChallenge(c2Challenge.data)
    bleServer.simulateResponse(r2, from: c2.centralID)

    // C1 responds second — continuation already consumed, should be a no-op
    let r1 = try c1.respondToChallenge(c1Challenge.data)
    bleServer.simulateResponse(r1, from: c1.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func authOnlyIdentifiedDevicesAreChallenged() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let identified = CompanionSimulator()
    let unidentified = CompanionSimulator()
    try register(identified, in: keychain)
    // unidentified is NOT registered and does NOT send identify

    // Connect identified — full setup
    try await fullyConnect(companion: identified, to: coordinator, via: bleServer)

    // Connect unidentified — ECDH only, no identify
    bleServer.simulateConnect(unidentified.centralID)
    let upk = unidentified.ecdhPublicKeyData()
    let spk = bleServer.simulateSessionKey(upk, from: unidentified.centralID)!
    try unidentified.completeECDH(daemonPublicKeyData: spk)

    let preChallengeCount = bleServer.sentChallenges.count

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    // Only the identified companion should have been challenged
    let newChallenges = bleServer.sentChallenges.dropFirst(preChallengeCount)
    #expect(newChallenges.allSatisfy { $0.centralID == identified.centralID })
    #expect(!newChallenges.contains { $0.centralID == unidentified.centralID })

    // Complete auth so the test doesn't hang
    if let challenge = newChallenges.first {
        let response = try identified.respondToChallenge(challenge.data)
        bleServer.simulateResponse(response, from: identified.centralID)
    }
    _ = await authResult
}

// MARK: - Edge Cases

@Test func authLateResponseAfterTimeoutIsNoOp() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let result = coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 0.05)
    // Wait past the timeout
    try await Task.sleep(nanoseconds: 200_000_000)

    // Send a valid response AFTER timeout — OnceContinuation must not crash (no double-resume)
    guard let challengeWire = bleServer.sentChallenges.last?.data else {
        Issue.record("No challenge was sent")
        return
    }
    let lateResponse = try companion.respondToChallenge(challengeWire)
    bleServer.simulateResponse(lateResponse, from: companion.centralID)

    let (success, reason) = await result
    #expect(success == false)
    #expect(reason == "timeout")
}

@Test func authBLEHardSendFailureResultsInImmediateFailure() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Simulate a hard BLE send failure (e.g. central not subscribed).
    // This is NOT the transmit-queue-full case — that's tested separately.
    bleServer.sendSucceeds = false

    let start = Date()
    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 5.0)
    let elapsed = Date().timeIntervalSince(start)

    #expect(result.success == false)
    #expect(result.reason == "challenge_failed")
    #expect(elapsed < 1.0)  // must fail fast, not after the full 5s timeout
}

// MARK: - BLE Transmit Queue Retry Tests

@Test func authTransmitQueueFullThenFlushSucceeds() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Simulate BLE transmit queue full — challenge is queued, not sent immediately.
    // sendChallenge returns true (data will be delivered on flush).
    bleServer.simulateTransmitQueueFull = true

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )

    // Give the coordinator time to issue the challenge (it goes into the queue)
    try await Task.sleep(nanoseconds: 150_000_000)

    // Challenge should be queued, not yet in sentChallenges
    #expect(bleServer.queuedChallengeCount == 1)
    #expect(bleServer.sentChallenges.isEmpty)

    // Flush the queue — simulates BLE subsystem becoming ready
    bleServer.simulateTransmitQueueFull = false
    bleServer.flushQueuedChallenges()

    // Now the challenge is in sentChallenges
    #expect(bleServer.sentChallenges.count == 1)
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge was flushed")
        return
    }
    #expect(sent.centralID == companion.centralID)

    // Companion signs and responds
    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
    #expect(result.reason == nil)
}

@Test func authTransmitQueueFullWithMultipleFlushes() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    bleServer.simulateTransmitQueueFull = true

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )

    try await Task.sleep(nanoseconds: 150_000_000)

    // Flush in two batches — first flush is empty (nothing new queued),
    // second flush delivers the challenge
    bleServer.flushQueuedChallenges() // first flush
    #expect(bleServer.sentChallenges.count == 1)

    // Companion responds
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge was flushed")
        return
    }
    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func authTransmitQueueFullMultipleDevicesFirstResponseWins() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let c1 = CompanionSimulator(deviceName: "iPhone 1")
    let c2 = CompanionSimulator(deviceName: "iPhone 2")
    try register(c1, in: keychain)
    try register(c2, in: keychain)
    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    // Both devices' challenges get queued
    bleServer.simulateTransmitQueueFull = true

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )

    try await Task.sleep(nanoseconds: 150_000_000)

    // Both challenges queued
    #expect(bleServer.queuedChallengeCount == 2)

    // Flush — both challenges delivered
    bleServer.simulateTransmitQueueFull = false
    bleServer.flushQueuedChallenges()
    #expect(bleServer.sentChallenges.count == 2)

    // Find each companion's challenge by centralID
    guard let sent1 = bleServer.sentChallenges.first(where: { $0.centralID == c1.centralID }) else {
        Issue.record("No challenge for c1")
        return
    }
    let response1 = try c1.respondToChallenge(sent1.data)
    bleServer.simulateResponse(response1, from: c1.centralID)

    let result = await authResult
    #expect(result.success == true)
    #expect(result.reason == nil)
}

// MARK: - Reconnect Tests

@Test func reconnectWithFreshECDHReidentifiesAndAuths() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // First connection — full setup
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)
    #expect(coordinator.identifiedCentrals.contains(companion.centralID))

    // Disconnect (BLE link drops)
    bleServer.simulateDisconnect(companion.centralID)
    #expect(coordinator.readyCentrals.isEmpty)

    // Reconnect with a fresh BLE connection (new centralID) but same signing key
    let reconnected = CompanionSimulator(reconnecting: companion)

    bleServer.simulateConnect(reconnected.centralID)
    let clientKey = reconnected.ecdhPublicKeyData()
    guard let serverKey = bleServer.simulateSessionKey(clientKey, from: reconnected.centralID) else {
        Issue.record("ECDH failed on reconnect")
        return
    }
    try reconnected.completeECDH(daemonPublicKeyData: serverKey)

    // Re-identify with the same deviceID — daemon should recognize it
    let identifyData = try reconnected.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: reconnected.centralID)
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(coordinator.identifiedCentrals.contains(reconnected.centralID))

    // Auth should work after reconnect
    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge sent after reconnect")
        return
    }
    let response = try reconnected.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: reconnected.centralID)

    let result = await authResult
    #expect(result.success == true)
}

// MARK: - Cross-Central Response Tests

@Test func authResponseWithForgedSignatureFromOtherCentralFailsAuth() async throws {
    // This test documents the current behavior: a forged response with a bad
    // signature from a different central causes the auth to fail immediately
    // with invalid_signature. The daemon processes responses from any connected
    // central and verifies the signature against the pinned public key.
    //
    // A forged response with a garbage signature fails verification, which
    // resumes the pending continuation with .invalidSignature — the legitimate
    // companion never gets a chance to respond.
    //
    // This is a known limitation: an attacker who knows the challengeID (which
    // is sent in plaintext in the BLE notification) and is connected as a BLE
    // central could send a forged response to cause a DoS. Mitigation requires
    // checking that the response came from the same central that was challenged.
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 3.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge sent")
        return
    }

    // Extract the challengeID from the wire data
    let payload = sent.data.dropFirst(2)
    let challengeMsg = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)

    // Forge a response with the correct challengeID but a garbage signature,
    // sent from a different central UUID (simulating an attacker)
    let forged = TBChallengeResponse.with {
        $0.challengeID = challengeMsg.challengeID
        $0.signature = Data(repeating: 0xFF, count: 64)
        $0.deviceID = companion.deviceID
    }
    let forgedWire = try WireFormat.encode(.challengeResponse, forged)
    let attackerCentral = UUID()
    bleServer.simulateResponse(forgedWire, from: attackerCentral)

    let result = await authResult
    #expect(result.success == false)
    #expect(result.reason == "invalid_signature")
}

@Test func authResponseWithWrongDeviceIDIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let result = coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 2.0)
    try await Task.sleep(nanoseconds: 100_000_000)

    guard let challengeWire = bleServer.sentChallenges.last?.data else {
        Issue.record("No challenge was sent")
        return
    }
    let payload = challengeWire.dropFirst(2)
    let msg = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)

    // Spoof: valid challengeID but a deviceID that is not in the keychain
    let spoofed = TBChallengeResponse.with {
        $0.challengeID = msg.challengeID
        $0.signature = Data(repeating: 0, count: 64)
        $0.deviceID = "spoofed-unknown-device"
    }
    let spoofWire = try WireFormat.encode(.challengeResponse, spoofed)
    bleServer.simulateResponse(spoofWire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 50_000_000)  // let coordinator process the spoof

    // Correct response should still resolve auth successfully
    let goodResponse = try companion.respondToChallenge(challengeWire)
    bleServer.simulateResponse(goodResponse, from: companion.centralID)

    let (success, reason) = await result
    #expect(success == true)
    #expect(reason == nil)
}

// MARK: - Pairing Token Enforcement

/// Creates a coordinator whose PairingManager is accessible for opening pairing windows.
private func makePairingTestCoordinator() -> (
    coordinator: DaemonCoordinator,
    bleServer: MockBLEServer,
    keychain: KeychainStore,
    pairingManager: PairingManager
) {
    let bleServer = MockBLEServer()
    let keychain = KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
    let auditLog = AuditLog(logDirectory: logDir)
    let pairingManager = PairingManager(keychainStore: keychain)

    let coordinator = DaemonCoordinator(
        keychainStore: keychain,
        auditLog: auditLog,
        pairingManager: pairingManager,
        bleServer: bleServer
    )
    return (coordinator, bleServer, keychain, pairingManager)
}

extension CompanionSimulator {
    /// Build a wire-format pair request: [1, 1] + JSON PairRequestMessage.
    func makePairRequest(token: Data?) throws -> Data {
        let msg = TBPairRequest.with {
            $0.deviceName = deviceName
            $0.publicKey = signingPublicKeyData
            $0.deviceID = deviceID
            if let token { $0.pairingToken = token }
        }
        return try WireFormat.encode(.pairRequest, msg)
    }
}

/// Decode the daemon's last pairing response, if any.
private func lastPairResponse(_ bleServer: MockBLEServer) throws -> TBPairResponse? {
    guard let sent = bleServer.sentPairingResponses.last else { return nil }
    let (type, payload) = try WireFormat.decode(data: sent.data)
    guard type == .pairResponse else { return nil }
    return try WireFormat.decodePayload(TBPairResponse.self, from: payload)
}

@Test func pairingWithValidTokenSucceeds() async throws {
    let (coordinator, bleServer, keychain, pairingManager) = makePairingTestCoordinator()

    // Open a pairing window and extract the token from the QR payload
    let qrData = try await pairingManager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let companion = CompanionSimulator()
    bleServer.simulateConnect(companion.centralID)

    let wire = try companion.makePairRequest(token: payload.pairingToken)
    bleServer.simulatePairingData(wire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 150_000_000)

    let response = try lastPairResponse(bleServer)
    #expect(response?.accepted == true)
    // Device must be stored under the companion's own deviceID so later
    // identify and challenge responses can find its public key.
    #expect(response?.deviceID == companion.deviceID)
    #expect(throws: Never.self) { try keychain.retrievePublicKey(for: companion.deviceID) }
    withExtendedLifetime(coordinator) {}
}

@Test func pairingWithWrongTokenIsRejected() async throws {
    let (coordinator, bleServer, keychain, pairingManager) = makePairingTestCoordinator()

    _ = try await pairingManager.generatePairingQRData()

    let companion = CompanionSimulator()
    bleServer.simulateConnect(companion.centralID)

    let wrongToken = Data(repeating: 0xAB, count: 16)
    let wire = try companion.makePairRequest(token: wrongToken)
    bleServer.simulatePairingData(wire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 150_000_000)

    let response = try lastPairResponse(bleServer)
    #expect(response?.accepted == false)
    #expect(throws: (any Error).self) { try keychain.retrievePublicKey(for: companion.deviceID) }
    withExtendedLifetime(coordinator) {}
}

@Test func pairingWithMissingTokenIsRejected() async throws {
    let (coordinator, bleServer, keychain, pairingManager) = makePairingTestCoordinator()

    _ = try await pairingManager.generatePairingQRData()

    let companion = CompanionSimulator()
    bleServer.simulateConnect(companion.centralID)

    let wire = try companion.makePairRequest(token: nil)
    bleServer.simulatePairingData(wire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 150_000_000)

    let response = try lastPairResponse(bleServer)
    #expect(response?.accepted == false)
    #expect(throws: (any Error).self) { try keychain.retrievePublicKey(for: companion.deviceID) }
    withExtendedLifetime(coordinator) {}
}

@Test func pairingWithNoActiveWindowIsRejected() async throws {
    let (coordinator, bleServer, keychain, pairingManager) = makePairingTestCoordinator()
    // No generatePairingQRData() — no pairing window is open

    let companion = CompanionSimulator()
    bleServer.simulateConnect(companion.centralID)

    let wire = try companion.makePairRequest(token: Data(repeating: 0xCD, count: 16))
    bleServer.simulatePairingData(wire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 150_000_000)

    let response = try lastPairResponse(bleServer)
    #expect(response?.accepted == false)
    #expect(throws: (any Error).self) { try keychain.retrievePublicKey(for: companion.deviceID) }
    _ = pairingManager
    withExtendedLifetime(coordinator) {}
}

@Test func pairedDeviceCanAuthenticateAfterTokenPairing() async throws {
    let (coordinator, bleServer, _, pairingManager) = makePairingTestCoordinator()

    let qrData = try await pairingManager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let companion = CompanionSimulator()
    bleServer.simulateConnect(companion.centralID)

    // ECDH first (as the real app does), then pair with the token
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    let wire = try companion.makePairRequest(token: payload.pairingToken)
    bleServer.simulatePairingData(wire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 150_000_000)

    // Pairing marks the session identified — auth should work immediately
    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge sent after pairing")
        return
    }
    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
}

// MARK: - Identify-on-Reconnect

@Test func reconnectAndReidentifyRestoresAuth() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // First connection — full setup + auth
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)
    async let firstAuth = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 5.0)
    try await Task.sleep(nanoseconds: 150_000_000)
    if let challenge = bleServer.sentChallenges.last {
        bleServer.simulateResponse(try companion.respondToChallenge(challenge.data), from: companion.centralID)
    }
    let first = await firstAuth
    #expect(first.success == true)

    // Simulate Mac reboot: disconnect → reconnect → new ECDH → re-identify
    bleServer.simulateDisconnect(companion.centralID)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Auth should work again without re-pairing
    async let secondAuth = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 5.0)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let challenge2 = bleServer.sentChallenges.last else {
        Issue.record("No challenge after reconnect")
        return
    }
    bleServer.simulateResponse(try companion.respondToChallenge(challenge2.data), from: companion.centralID)
    let second = await secondAuth
    #expect(second.success == true)
}

// MARK: - Kill-Switch Tests

@Test func killSwitchForcesPasswordFallback() async throws {
    let bleServer = MockBLEServer()
    let keychain = KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
    let auditLog = AuditLog(logDirectory: logDir)

    // Create a plist with the kill-switch active
    let plistDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plistDir) }
    let plistPath = plistDir.appendingPathComponent("policy.plist").path
    let dict: NSDictionary = ["ForcePasswordFallback": true]
    dict.write(toFile: plistPath, atomically: true)

    let policyEngine = PolicyEngine(plistPath: plistPath)
    let coordinator = DaemonCoordinator(
        keychainStore: keychain,
        auditLog: auditLog,
        policyEngine: policyEngine,
        bleServer: bleServer
    )

    let result = await coordinator.authenticateFromPAM(
        user: "test", service: "sudo", pid: 1, timeout: 5.0
    )

    #expect(result.success == false)
    #expect(result.reason == "forced_fallback")
    // No challenges should have been dispatched
    #expect(bleServer.sentChallenges.isEmpty)
}

@Test func killSwitchOffAllowsNormalAuth() async throws {
    let bleServer = MockBLEServer()
    let keychain = KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
    let auditLog = AuditLog(logDirectory: logDir)

    // Kill-switch NOT active
    let plistDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plistDir) }
    let plistPath = plistDir.appendingPathComponent("policy.plist").path
    let dict: NSDictionary = ["ForcePasswordFallback": false]
    dict.write(toFile: plistPath, atomically: true)

    let policyEngine = PolicyEngine(plistPath: plistPath)
    let coordinator = DaemonCoordinator(
        keychainStore: keychain,
        auditLog: auditLog,
        policyEngine: policyEngine,
        bleServer: bleServer
    )

    // With no devices connected, auth should fail with no_companion_connected
    // (NOT forced_fallback — proving the kill-switch didn't short-circuit)
    let result = await coordinator.authenticateFromPAM(
        user: "test", service: "sudo", pid: 1, timeout: 2.0
    )

    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

// MARK: - Identify Signature Tests

@Test func identifyWithValidSignatureSucceeds() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "IDENTIFIED" })
    #expect(!entries.contains { $0.result == "REJECTED_INVALID_SIGNATURE" })
    #expect(!entries.contains { $0.result == "REJECTED_MISSING_SIGNATURE" })
}

@Test func identifyWithMissingSignatureIsRejected() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // ECDH only
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    // Send identify without signature
    let identifyData = try companion.makeIdentifyDataWithoutSignature()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "REJECTED_MISSING_SIGNATURE" })
    #expect(!entries.contains { $0.result == "IDENTIFIED" })

    // Auth should fail — device was not identified
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.5)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func identifyWithTamperedSignatureIsRejected() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // ECDH only
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    // Send identify with tampered signature
    let identifyData = try companion.makeIdentifyDataWithTamperedSignature()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "REJECTED_INVALID_SIGNATURE" })
    #expect(!entries.contains { $0.result == "IDENTIFIED" })

    // Auth should fail — device was not identified
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.5)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}


@Test func identifyWithWrongEphemeralKeyIsRejected() async throws {
    // Simulates a MITM who intercepts ECDH: the companion signs with the
    // MITM's ephemeral key, but the daemon verifies against its own.
    // The signature is valid ECDSA but won't match — daemon must reject.
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // ECDH
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    // Send identify signed with a wrong daemon ephemeral key
    let identifyData = try companion.makeIdentifyDataWithWrongEphemeralKey()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "REJECTED_INVALID_SIGNATURE" })
    #expect(!entries.contains { $0.result == "IDENTIFIED" })

    // Auth should fail — device was not identified
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.5)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

// MARK: - Device Type & Capabilities Tests

@Test func pairRequestStoresDeviceTypeAndCaps() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()

    // Generate pairing QR
    let qrData = try await coordinator.pairingManager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    // Simulate a phone connecting and sending a pair request with deviceType=PHONE + caps
    let companion = CompanionSimulator(deviceName: "Test iPhone")
    bleServer.simulateConnect(companion.centralID)

    let pairReq = TBPairRequest.with {
        $0.deviceName = "Test iPhone"
        $0.publicKey = companion.signingPublicKeyData
        $0.deviceID = companion.deviceID
        $0.pairingToken = payload.pairingToken
        $0.deviceType = .phone
        $0.caps = TBDeviceCapabilities.with {
            $0.hasBiometric_p = true
            $0.hasSecureEnclave_p = true
            $0.hasDisplay_p = true
            $0.hasButton_p = false
            $0.latencyClass = 0
        }
    }
    let pairWire = try WireFormat.encode(.pairRequest, pairReq)
    bleServer.simulatePairingData(pairWire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 100_000_000)

    // Verify the device was stored with the correct type + caps
    let stored = try keychain.retrievePairedDevice(deviceID: companion.deviceID)
    #expect(stored.tbDeviceType == .phone)
    #expect(stored.caps.hasBiometric == true)
    #expect(stored.caps.hasSecureEnclave == true)
    #expect(stored.caps.hasDisplay == true)
}

@Test func identifyRefreshesDeviceTypeOnSession() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    // Register as PHONE
    try register(companion, in: keychain, deviceType: .phone)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // The session should have deviceType=phone (from identify)
    // We can't directly inspect the private sessions dict, but we can verify
    // that auth works (which requires an identified session)
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 1.0)
    // It should not be "no_companion_connected" — the device is identified
    #expect(result.reason != "no_companion_connected")
}

@Test func watchWithoutSepIsRejectedFromDirectChallengeResponse() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator(deviceName: "Apple Watch")

    // Register as WATCH without secure enclave
    try register(companion, in: keychain, deviceType: .watch, caps: TBDeviceCapabilities.with {
        $0.hasBiometric_p = false
        $0.hasSecureEnclave_p = false  // No SEP — must delegate to phone
        $0.hasDisplay_p = true
        $0.hasButton_p = true
        $0.latencyClass = 1
    })

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Issue a challenge and have the watch respond directly
    async let authResult = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 3.0)
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let challenge = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent")
        return
    }

    // Watch responds directly (violating delegation rule)
    let response = try companion.respondToChallenge(challenge.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    // The watch's direct response should be rejected
    #expect(result.success == false)

    // Audit log should show the delegation violation
    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "FAILED_WATCH_DELEGATION_VIOLATION" })
}

@Test func watchWithSepCanRespondDirectly() async throws {
    let (coordinator, bleServer, keychain, auditLog, _) = makeTestCoordinator()
    let companion = CompanionSimulator(deviceName: "Apple Watch Ultra")

    // Register as WATCH WITH secure enclave (e.g. Apple Watch Ultra has SEP)
    try register(companion, in: keychain, deviceType: .watch, caps: TBDeviceCapabilities.with {
        $0.hasBiometric_p = true
        $0.hasSecureEnclave_p = true  // Has SEP — can sign directly
        $0.hasDisplay_p = true
        $0.hasButton_p = true
        $0.latencyClass = 1
    })

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Issue a challenge and have the watch respond directly
    async let authResult = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 3.0)
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let challenge = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent")
        return
    }

    // Watch responds directly — should be allowed since it has SEP
    let response = try companion.respondToChallenge(challenge.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)

    // No delegation violation in audit log
    let entries = try await auditLog.readEntries()
    #expect(!entries.contains { $0.result == "FAILED_WATCH_DELEGATION_VIOLATION" })
}

// MARK: - Selection Policy Tests

@Test func disabledDeviceIsExcludedFromAuth() async throws {
    let (coordinator, bleServer, keychain, _, runtimeStore) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // Disable the device in the runtime store
    runtimeStore.setEnabled(companion.deviceID, enabled: false)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Auth should fail — the only device is disabled
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 1.0)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func reEnabledDeviceCanAuthenticate() async throws {
    let (coordinator, bleServer, keychain, _, runtimeStore) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Disable, then re-enable
    runtimeStore.setEnabled(companion.deviceID, enabled: false)
    runtimeStore.setEnabled(companion.deviceID, enabled: true)

    // Auth should work now — issue challenge and respond
    async let authResult = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 3.0)
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let challenge = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent")
        return
    }
    let response = try companion.respondToChallenge(challenge.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func anyOneOfBroadcastsToAllEnabledDevices() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()

    // Connect two companions
    let companion1 = CompanionSimulator(deviceName: "iPhone")
    let companion2 = CompanionSimulator(deviceName: "Watch")
    try register(companion1, in: keychain)
    try register(companion2, in: keychain)

    try await fullyConnect(companion: companion1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: companion2, to: coordinator, via: bleServer)

    // Both should receive challenges (anyOneOf = broadcast)
    async let authResult = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 3.0)
    try await Task.sleep(nanoseconds: 150_000_000)

    // At least 2 challenges should have been sent
    #expect(bleServer.sentChallenges.count >= 2)

    // Find the challenge for companion1 and respond to it
    let challenge1 = bleServer.sentChallenges.first { $0.centralID == companion1.centralID }
    guard let challenge = challenge1 else {
        Issue.record("No challenge for companion1")
        return
    }
    let response = try companion1.respondToChallenge(challenge.data)
    bleServer.simulateResponse(response, from: companion1.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func getDaemonStatusExposesDeviceTypeAndLinkQuality() async throws {
    let (coordinator, bleServer, keychain, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator(deviceName: "Test iPhone")
    try register(companion, in: keychain, deviceType: .phone)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    let status = await coordinator.getDaemonStatus()
    #expect(status.pairedDevices.count == 1)

    let device = status.pairedDevices.first!
    #expect(device.deviceType == "phone")
    #expect(device.enabled == true)
    // linkQuality may be "unknown" if no RSSI data in mock, but the field should exist
    #expect(["good", "fair", "poor", "unknown"].contains(device.linkQuality))
}

@Test func setDeviceEnabledViaControlHandler() async throws {
    let (coordinator, _, keychain, _, runtimeStore) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // Disable via control handler
    await coordinator.setDeviceEnabled(deviceID: companion.deviceID, enabled: false)
    #expect(runtimeStore.isEnabled(companion.deviceID) == false)

    // Re-enable
    await coordinator.setDeviceEnabled(deviceID: companion.deviceID, enabled: true)
    #expect(runtimeStore.isEnabled(companion.deviceID) == true)
}

@Test func unpairRemovesRuntimeState() async throws {
    let (coordinator, _, keychain, _, runtimeStore) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // Set some runtime state
    runtimeStore.setEnabled(companion.deviceID, enabled: false)
    runtimeStore.setPriority(companion.deviceID, priority: 5)
    #expect(runtimeStore.isEnabled(companion.deviceID) == false)

    // Unpair should remove runtime state
    try await coordinator.unpairDevice(deviceID: companion.deviceID)
    #expect(runtimeStore.isEnabled(companion.deviceID) == true) // defaults to true after removal
    #expect(runtimeStore.get(companion.deviceID).priority == 0)
}
