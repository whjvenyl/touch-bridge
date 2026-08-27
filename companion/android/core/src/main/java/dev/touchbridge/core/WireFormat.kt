package dev.touchbridge.core

import dev.touchbridge.core.Constants
import dev.touchbridge.core.proto.ChallengeIssued
import dev.touchbridge.core.proto.ChallengeResponse
import dev.touchbridge.core.proto.Error
import dev.touchbridge.core.proto.Identify
import dev.touchbridge.core.proto.PairRequest
import dev.touchbridge.core.proto.DeviceType
import dev.touchbridge.core.proto.DeviceCapabilities
import dev.touchbridge.core.proto.PairResponse
import com.google.protobuf.ByteString

/// Handles encoding and decoding of TouchBridge wire messages using protobuf.
///
/// Wire format: [version: Byte][type: Byte][protobuf payload bytes]
/// Max total size: 512 bytes.
object WireFormat {

    // Message type constants — match the [type] byte in the wire header.
    const val TYPE_PAIR_REQUEST: Byte = 1
    const val TYPE_PAIR_RESPONSE: Byte = 2
    const val TYPE_CHALLENGE_ISSUED: Byte = 3
    const val TYPE_CHALLENGE_RESPONSE: Byte = 4
    const val TYPE_ERROR: Byte = 5
    const val TYPE_IDENTIFY: Byte = 6

    /// Encode a protobuf payload with the wire format header.
    ///
    /// Throws `IllegalArgumentException` if the total size (header + payload)
    /// exceeds `Constants.MAX_MESSAGE_SIZE`. This matches the Swift
    /// `WireFormat.encode` behavior, which throws `messageTooLarge`.
    fun encode(type: Byte, payload: ByteArray): ByteArray {
        val totalSize = 2 + payload.size
        require(totalSize <= Constants.MAX_MESSAGE_SIZE) {
            "WireFormat.encode: message too large ($totalSize > ${Constants.MAX_MESSAGE_SIZE})"
        }
        val result = ByteArray(totalSize)
        result[0] = Constants.PROTOCOL_VERSION
        result[1] = type
        System.arraycopy(payload, 0, result, 2, payload.size)
        return result
    }

    /// Decode a wire format message into its type and raw protobuf payload.
    /// Returns null if the data is too small or the version doesn't match.
    fun decode(data: ByteArray): Pair<Byte, ByteArray>? {
        if (data.size < 2) return null
        if (data[0] != Constants.PROTOCOL_VERSION) return null
        val type = data[1]
        val payload = data.copyOfRange(2, data.size)
        return Pair(type, payload)
    }

    /// Build an identify message: [version][type=6] + protobuf Identify.
    /// The signature proves possession of the paired private key.
    fun buildIdentify(
        deviceID: String,
        deviceName: String,
        signature: ByteArray,
        deviceType: DeviceType = DeviceType.PHONE
    ): ByteArray {
        val msg = Identify.newBuilder()
            .setDeviceId(deviceID)
            .setDeviceName(deviceName)
            .setSignature(ByteString.copyFrom(signature))
            .setDeviceType(deviceType)
            .build()
        return encode(TYPE_IDENTIFY, msg.toByteArray())
    }

    /// Build a pair request message: [version][type=1] + protobuf PairRequest.
    fun buildPairRequest(
        deviceName: String,
        publicKey: ByteArray,
        deviceID: String,
        pairingToken: ByteArray,
        deviceType: DeviceType = DeviceType.PHONE,
        caps: DeviceCapabilities = DeviceCapabilities.newBuilder()
            .setHasBiometric(true)
            .setHasSecureEnclave(true)
            .setHasDisplay(true)
            .setHasButton(false)
            .setLatencyClass(0)
            .build()
    ): ByteArray {
        val msg = PairRequest.newBuilder()
            .setDeviceName(deviceName)
            .setPublicKey(ByteString.copyFrom(publicKey))
            .setDeviceId(deviceID)
            .setPairingToken(ByteString.copyFrom(pairingToken))
            .setDeviceType(deviceType)
            .setCaps(caps)
            .build()
        return encode(TYPE_PAIR_REQUEST, msg.toByteArray())
    }

    /// Build a challenge response message: [version][type=4] + protobuf ChallengeResponse.
    fun buildChallengeResponse(
        challengeID: String,
        signature: ByteArray,
        deviceID: String
    ): ByteArray {
        val msg = ChallengeResponse.newBuilder()
            .setChallengeId(challengeID)
            .setSignature(ByteString.copyFrom(signature))
            .setDeviceId(deviceID)
            .build()
        return encode(TYPE_CHALLENGE_RESPONSE, msg.toByteArray())
    }

    /// Build an error message: [version][type=5] + protobuf Error.
    fun buildError(code: Int, description: String, challengeID: String?): ByteArray {
        val builder = Error.newBuilder()
            .setCode(code)
            .setDescription(description)
        if (challengeID != null) builder.setChallengeId(challengeID)
        return encode(TYPE_ERROR, builder.build().toByteArray())
    }
}
