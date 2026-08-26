import Testing
import Foundation
@testable import TouchBridgeProtocol

/// Cross-platform golden-file wire format tests.
///
/// Verifies that Swift's WireFormat encoding produces byte-identical output
/// to the golden vectors in `protocol/golden/wire_vectors.json`. The same
/// file is consumed by the Kotlin test suite, ensuring both platforms agree
/// on the wire format. If this test fails, the protocol has drifted.
///
/// To regenerate the golden file, see `GoldenVectorGenerator.swift`.

private struct GoldenVector: Codable {
    let name: String
    let messageType: Int
    let expectedHex: String
}

private func loadGoldenVectors() throws -> [GoldenVector] {
    let path = #function  // unused — just to suppress warnings
    _ = path

    // Resolve the golden file relative to the package root.
    // The test runs from .build/.../debug, so we walk up to find protocol/golden.
    let possiblePaths = [
        // From SPM test working directory
        "../../../protocol/golden/wire_vectors.json",
        // From Xcode test working directory
        "../../../../protocol/golden/wire_vectors.json",
        // Absolute fallback
        "/Users/tobias.bannwert/Workspace/pixel-watch/UnTouchID/protocol/golden/wire_vectors.json",
    ]

    for path in possiblePaths {
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode([GoldenVector].self, from: data)
        }
    }

    Issue.record("Golden vectors file not found in any expected location")
    return []
}

@Test func goldenPairRequestEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "pairRequest" }) else {
        Issue.record("pairRequest vector missing"); return
    }

    let msg = TBPairRequest.with {
        $0.deviceName = "Test iPhone"
        $0.publicKey = Data(repeating: 0x01, count: 65)
        $0.deviceID = "device-abc"
        $0.pairingToken = Data(repeating: 0x02, count: 16)
    }
    let encoded = try WireFormat.encode(.pairRequest, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "pairRequest encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenPairResponseEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "pairResponse" }) else {
        Issue.record("pairResponse vector missing"); return
    }

    let msg = TBPairResponse.with {
        $0.deviceID = "mac-device-001"
        $0.publicKey = Data(repeating: 0x03, count: 65)
        $0.accepted = true
    }
    let encoded = try WireFormat.encode(.pairResponse, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "pairResponse encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenChallengeIssuedEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "challengeIssued" }) else {
        Issue.record("challengeIssued vector missing"); return
    }

    let msg = TBChallengeIssued.with {
        $0.challengeID = "chal-12345"
        $0.encryptedNonce = Data(repeating: 0xAB, count: 60)
        $0.reason = "sudo"
        $0.expiryUnix = 1234567890
    }
    let encoded = try WireFormat.encode(.challengeIssued, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "challengeIssued encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenChallengeResponseEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "challengeResponse" }) else {
        Issue.record("challengeResponse vector missing"); return
    }

    let msg = TBChallengeResponse.with {
        $0.challengeID = "resp-uuid"
        $0.signature = Data(repeating: 0xCC, count: 72)
        $0.deviceID = "device-123"
    }
    let encoded = try WireFormat.encode(.challengeResponse, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "challengeResponse encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenErrorEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "error" }) else {
        Issue.record("error vector missing"); return
    }

    let msg = TBError.with {
        $0.code = 1001
        $0.description_p = "Key invalidated"
        $0.challengeID = "chal-err"
    }
    let encoded = try WireFormat.encode(.error, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "error encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenIdentifyEncoding() throws {
    let vectors = try loadGoldenVectors()
    guard let v = vectors.first(where: { $0.name == "identify" }) else {
        Issue.record("identify vector missing"); return
    }

    let msg = TBIdentify.with {
        $0.deviceID = "device-xyz"
        $0.deviceName = "Pixel Watch"
    }
    let encoded = try WireFormat.encode(.identify, msg)
    let hex = encoded.map { String(format: "%02x", $0) }.joined()

    #expect(hex == v.expectedHex, "identify encoding mismatch:\n  expected: \(v.expectedHex)\n  actual:   \(hex)")
}

@Test func goldenDecodingRoundTrip() throws {
    // Verify that decoding the golden hex produces the expected field values.
    let vectors = try loadGoldenVectors()

    for v in vectors {
        let hex = v.expectedHex
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            let byte = UInt8(hex[i..<next], radix: 16)!
            data.append(byte)
            i = next
        }

        let (type, payload) = try WireFormat.decode(data: data)
        #expect(Int(type.rawValue) == v.messageType, "\(v.name): type mismatch")
        // If we got here, the wire header decoded correctly.
        // The payload is valid protobuf — we don't decode each one fully here
        // since the per-message tests above already verify encoding.
        _ = payload
    }
}
