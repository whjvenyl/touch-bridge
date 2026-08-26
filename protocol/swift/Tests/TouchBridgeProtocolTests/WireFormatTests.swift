import Testing
import Foundation
@testable import TouchBridgeProtocol

@Test func roundTripPairRequest() throws {
    let msg = TBPairRequest.with {
        $0.deviceName = "Test iPhone"
        $0.publicKey = Data(repeating: 0x01, count: 65)
    }
    let encoded = try WireFormat.encode(.pairRequest, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .pairRequest)
    let decoded = try WireFormat.decodePayload(TBPairRequest.self, from: payload)
    #expect(decoded.deviceName == "Test iPhone")
    #expect(decoded.publicKey == Data(repeating: 0x01, count: 65))
}

@Test func roundTripChallengeIssued() throws {
    let msg = TBChallengeIssued.with {
        $0.challengeID = "test-uuid"
        $0.encryptedNonce = Data(repeating: 0xAB, count: 60)
        $0.reason = "sudo"
        $0.expiryUnix = 1234567890
    }
    let encoded = try WireFormat.encode(.challengeIssued, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .challengeIssued)
    let decoded = try WireFormat.decodePayload(TBChallengeIssued.self, from: payload)
    #expect(decoded.challengeID == "test-uuid")
    #expect(decoded.reason == "sudo")
    #expect(decoded.expiryUnix == 1234567890)
}

@Test func roundTripChallengeResponse() throws {
    let msg = TBChallengeResponse.with {
        $0.challengeID = "resp-uuid"
        $0.signature = Data(repeating: 0xCC, count: 72)
        $0.deviceID = "device-123"
    }
    let encoded = try WireFormat.encode(.challengeResponse, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .challengeResponse)
    let decoded = try WireFormat.decodePayload(TBChallengeResponse.self, from: payload)
    #expect(decoded.deviceID == "device-123")
    #expect(decoded.signature.count == 72)
}

@Test func oversizeMessageThrows() throws {
    // Create a message that exceeds max message size
    let largeKey = Data(repeating: 0xFF, count: 600)
    let msg = TBPairRequest.with {
        $0.deviceName = "Big"
        $0.publicKey = largeKey
    }

    #expect(throws: WireFormatError.self) {
        try WireFormat.encode(.pairRequest, msg)
    }
}

@Test func tooSmallDataThrows() throws {
    let tiny = Data([0x01]) // only 1 byte, need at least 2

    #expect(throws: WireFormatError.self) {
        try WireFormat.decode(data: tiny)
    }
}

@Test func versionMismatchThrows() throws {
    // Valid size but wrong version byte (0x02 instead of 0x01)
    let data = Data([0x02, 0x01, 0x00])

    #expect(throws: WireFormatError.self) {
        try WireFormat.decode(data: data)
    }
}

@Test func unknownTypeReturnsUnrecognized() throws {
    var data = Data([TouchBridgeConstants.protocolVersion, 0xFF])
    data.append(Data([0x00])) // minimal protobuf payload

    // Protobuf returns .UNRECOGNIZED for unknown enum values rather than throwing
    let (type, _) = try WireFormat.decode(data: data)
    #expect(type != .pairRequest)
    #expect(type != .pairResponse)
    #expect(type != .challengeIssued)
    #expect(type != .challengeResponse)
    #expect(type != .error)
    #expect(type != .identify)
}

@Test func versionByteIsPresent() throws {
    let msg = TBError.with {
        $0.code = 42
        $0.description_p = "test"
    }
    let encoded = try WireFormat.encode(.error, msg)

    #expect(encoded[0] == TouchBridgeConstants.protocolVersion)
    #expect(encoded[1] == UInt8(TBMessageType.error.rawValue))
}

@Test func emptyPayloadDecodes() throws {
    let msg = TBError.with {
        $0.code = 0
        $0.description_p = ""
    }
    let encoded = try WireFormat.encode(.error, msg)
    let (type, payload) = try WireFormat.decode(data: encoded)

    #expect(type == .error)
    let decoded = try WireFormat.decodePayload(TBError.self, from: payload)
    #expect(decoded.code == 0)
    #expect(decoded.description_p == "")
}
