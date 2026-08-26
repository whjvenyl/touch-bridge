import Foundation
import Security
import TouchBridgeProtocol

/// A paired companion device record.
public struct PairedDevice: Codable, Sendable, Equatable {
    public let deviceID: String
    public let publicKey: Data
    public let displayName: String
    public let pairedAt: Date

    public init(deviceID: String, publicKey: Data, displayName: String, pairedAt: Date) {
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.displayName = displayName
        self.pairedAt = pairedAt
    }
}

/// Manages paired device public keys in the macOS Keychain.
public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = TouchBridgeConstants.keychainService) {
        self.service = service
    }

    /// Store a paired device's public key and metadata.
    ///
    /// Uses `SecItemUpdate` first (atomic — the entry is never missing), and
    /// only falls back to `SecItemAdd` if the item doesn't exist yet. This
    /// avoids the delete-then-add window where a crash would lose the entry.
    public func storePairedDevice(_ device: PairedDevice) throws {
        let data = try JSONEncoder().encode(device)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: device.deviceID,
        ]

        let attributesToUpdate: [String: Any] = [
            kSecAttrLabel as String: "TouchBridge: \(device.displayName)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]

        // Try to update the existing entry atomically.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        // Item doesn't exist — create it.
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecAttrLabel as String] = "TouchBridge: \(device.displayName)"
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecValueData as String] = data

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.storeFailed(addStatus)
            }
            return
        }

        // Unexpected error from SecItemUpdate.
        throw KeychainStoreError.storeFailed(updateStatus)
    }

    /// Retrieve a paired device record by device ID.
    public func retrievePairedDevice(deviceID: String) throws -> PairedDevice {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError.deviceNotFound(deviceID)
        }

        return try JSONDecoder().decode(PairedDevice.self, from: data)
    }

    /// Reconstruct a `SecKey` from a paired device's stored public key bytes.
    public func retrievePublicKey(for deviceID: String) throws -> SecKey {
        let device = try retrievePairedDevice(deviceID: deviceID)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(device.publicKey as CFData, attributes as CFDictionary, &error) else {
            throw KeychainStoreError.publicKeyReconstructionFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown"
            )
        }

        return key
    }

    /// List all paired devices.
    public func listPairedDevices() throws -> [PairedDevice] {
        // First, get all account names for our service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainStoreError.listFailed(status)
        }

        // Retrieve each device individually by account name
        return items.compactMap { dict in
            guard let account = dict[kSecAttrAccount as String] as? String else { return nil }
            return try? retrievePairedDevice(deviceID: account)
        }
    }

    /// Remove a paired device by ID.
    public func removePairedDevice(deviceID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.removeFailed(status)
        }
    }

    /// Remove all paired devices (for testing/cleanup).
    public func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.removeFailed(status)
        }
    }
}

public enum KeychainStoreError: Error, Sendable {
    case storeFailed(OSStatus)
    case deviceNotFound(String)
    case publicKeyReconstructionFailed(String)
    case listFailed(OSStatus)
    case removeFailed(OSStatus)
}
