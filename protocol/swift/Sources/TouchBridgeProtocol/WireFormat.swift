import Foundation
import SwiftProtobuf

/// Errors during wire format encoding/decoding.
public enum WireFormatError: Error, Sendable {
    case messageTooLarge(Int)
    case messageTooSmall
    case unknownMessageType(UInt8)
    case encodingFailed
    case decodingFailed
}

/// Handles encoding and decoding of TouchBridge wire messages.
///
/// Wire format: [version: UInt8][type: UInt8][protobuf payload bytes]
/// Max total size: 512 bytes (protobuf is more compact than JSON).
///
/// The version and type bytes are prepended outside of protobuf — they
/// identify the message for routing before deserialization. The payload
/// is a serialized protobuf message.
public struct WireFormat: Sendable {

    private static let headerSize = 2 // version + type

    /// Encode a protobuf message with the wire format header.
    public static func encode<T: Message>(_ type: TBMessageType, _ message: T) throws -> Data {
        let payload = try message.serializedData()
        let totalSize = headerSize + payload.count
        guard totalSize <= TouchBridgeConstants.maxMessageSize else {
            throw WireFormatError.messageTooLarge(totalSize)
        }

        var data = Data(capacity: totalSize)
        data.append(TouchBridgeConstants.protocolVersion)
        data.append(UInt8(type.rawValue))
        data.append(payload)
        return data
    }

    /// Decode a wire format message into its type and raw protobuf payload.
    public static func decode(data: Data) throws -> (type: TBMessageType, payload: Data) {
        guard data.count >= headerSize else {
            throw WireFormatError.messageTooSmall
        }

        let typeByte = data[data.startIndex + 1]
        guard let type = TBMessageType(rawValue: Int(typeByte)) else {
            throw WireFormatError.unknownMessageType(typeByte)
        }

        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return (type, payload)
    }

    /// Decode a protobuf payload into a specific message type.
    public static func decodeMessage<T: Message>(_ payloadType: T.Type, from data: Data) throws -> T {
        return try T(serializedBytes: data)
    }

    /// Alias for decodeMessage — kept for backward compatibility with existing call sites.
    public static func decodePayload<T: Message>(_ payloadType: T.Type, from data: Data) throws -> T {
        return try T(serializedBytes: data)
    }
}
