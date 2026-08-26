import Testing
import Foundation
@testable import TouchBridgeCore

@Test func linkQualityFromRSSI() {
    #expect(LinkQuality.from(rssi: -50) == .good)
    #expect(LinkQuality.from(rssi: -60) == .good)
    #expect(LinkQuality.from(rssi: -61) == .fair)
    #expect(LinkQuality.from(rssi: -75) == .fair)
    #expect(LinkQuality.from(rssi: -76) == .poor)
    #expect(LinkQuality.from(rssi: -90) == .poor)
    #expect(LinkQuality.from(rssi: -91) == .unknown)
    #expect(LinkQuality.from(rssi: nil) == .unknown)
}

@Test func deviceRuntimeStoreDefaultsEnabled() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    let state = store.get("unknown-device")
    #expect(state.enabled == true)
    #expect(state.priority == 0)
    #expect(state.lastSeen == nil)
    #expect(state.linkQuality == .unknown)
}

@Test func deviceRuntimeStoreSetEnabled() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    store.setEnabled("device-1", enabled: false)
    #expect(store.isEnabled("device-1") == false)
    store.setEnabled("device-1", enabled: true)
    #expect(store.isEnabled("device-1") == true)
}

@Test func deviceRuntimeStoreSetPriority() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    store.setPriority("device-1", priority: 5)
    #expect(store.get("device-1").priority == 5)
}

@Test func deviceRuntimeStoreUpdateLinkQuality() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    store.updateLinkQuality("device-1", rssi: -50)
    #expect(store.get("device-1").linkQuality == .good)
    store.updateLinkQuality("device-1", rssi: -80)
    #expect(store.get("device-1").linkQuality == .poor)
}

@Test func deviceRuntimeStoreUpdateLastSeen() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    let before = Date()
    store.updateLastSeen("device-1")
    let lastSeen = store.get("device-1").lastSeen
    #expect(lastSeen != nil)
    #expect(lastSeen! >= before)
}

@Test func deviceRuntimeStoreRemove() {
    let store = DeviceRuntimeStore(
        filePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    )
    store.setEnabled("device-1", enabled: false)
    store.remove("device-1")
    // After removal, defaults should apply
    #expect(store.isEnabled("device-1") == true)
}

@Test func deviceRuntimeStorePersistsToDisk() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    let store1 = DeviceRuntimeStore(filePath: path)
    store1.setEnabled("device-1", enabled: false)
    store1.setPriority("device-1", priority: 3)

    // Create a new store pointing at the same file — should load from disk
    let store2 = DeviceRuntimeStore(filePath: path)
    #expect(store2.isEnabled("device-1") == false)
    #expect(store2.get("device-1").priority == 3)
}

@Test func deviceRuntimeStoreFilePermissions() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString).json").path
    let store = DeviceRuntimeStore(filePath: path)
    store.setEnabled("device-1", enabled: true)

    // Verify file exists and has 0o600 permissions
    #expect(FileManager.default.fileExists(atPath: path))
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = attrs[.posixPermissions] as? UInt16 ?? 0
    #expect(permissions == 0o600)
}

// MARK: - Selection Policy Tests

@Test func selectionPolicyDefaultsToAnyOneOf() {
    let engine = PolicyEngine(
        plistPath: "/tmp/tb-nonexistent-\(UUID().uuidString).plist"
    )
    let policy = engine.selectionPolicy()
    #expect(policy.mode == .anyOneOf)
    #expect(policy.group == "all")
}

@Test func selectionPolicyReadsPriorityOrderFromPlist() throws {
    let plistDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plistDir) }
    let plistPath = plistDir.appendingPathComponent("policy.plist").path
    let dict: NSDictionary = [
        "DeviceSelection": [
            "mode": "priority_order",
            "group": "my-group"
        ]
    ]
    dict.write(toFile: plistPath, atomically: true)

    let engine = PolicyEngine(plistPath: plistPath)
    let policy = engine.selectionPolicy()
    #expect(policy.mode == .priorityOrder)
    #expect(policy.group == "my-group")
}

@Test func perDeviceTimeoutDividesGlobalByCount() {
    let engine = PolicyEngine(
        plistPath: "/tmp/tb-nonexistent-\(UUID().uuidString).plist"
    )
    // Default auth timeout is 15s
    let perDevice = engine.perDeviceTimeout(deviceCount: 3)
    // 15 / 3 = 5, capped at challengeExpiry (10s) → 5
    #expect(perDevice == 5.0)
}

@Test func perDeviceTimeoutCappedAtChallengeExpiry() {
    let engine = PolicyEngine(
        plistPath: "/tmp/tb-nonexistent-\(UUID().uuidString).plist"
    )
    // With 1 device, 15/1 = 15, but capped at 10
    let perDevice = engine.perDeviceTimeout(deviceCount: 1)
    #expect(perDevice == 10.0)
}
