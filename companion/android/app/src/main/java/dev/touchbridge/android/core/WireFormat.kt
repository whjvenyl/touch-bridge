package dev.touchbridge.android.core

import dev.touchbridge.android.Constants
import org.json.JSONObject

/**
 * Wire format encoder/decoder — matches protocol/swift/WireFormat.swift.
 *
 * Wire format: [version: UInt8][type: UInt8][payload: JSON bytes]
 * Max total size: 256 bytes.
 */
object WireFormat {

    const val TYPE_PAIR_REQUEST: Byte = 1
    const val TYPE_PAIR_RESPONSE: Byte = 2
    const val TYPE_CHALLENGE_ISSUED: Byte = 3
    const val TYPE_CHALLENGE_RESPONSE: Byte = 4
    const val TYPE_ERROR: Byte = 5
    const val TYPE_IDENTIFY: Byte = 6

    /**
     * Encode a JSON payload with the wire format header.
     * Returns: [version][type][payload bytes]
     */
    fun encode(type: Byte, jsonPayload: ByteArray): ByteArray {
        val result = ByteArray(2 + jsonPayload.size)
        result[0] = Constants.PROTOCOL_VERSION
        result[1] = type
        System.arraycopy(jsonPayload, 0, result, 2, jsonPayload.size)
        return result
    }

    /**
     * Decode a wire format message.
     * Returns: (type, payload bytes) or null if too small.
     */
    fun decode(data: ByteArray): Pair<Byte, ByteArray>? {
        if (data.size < 2) return null
        val type = data[1]
        val payload = data.copyOfRange(2, data.size)
        return Pair(type, payload)
    }

    /**
     * Build an identify message JSON.
     */
    fun buildIdentify(deviceID: String, deviceName: String): ByteArray {
        val json = JSONObject().apply {
            put("deviceID", deviceID)
            put("deviceName", deviceName)
        }
        return encode(TYPE_IDENTIFY, json.toString().toByteArray())
    }

    /**
     * Build a pair request message JSON.
     */
    fun buildPairRequest(
        deviceName: String,
        publicKey: ByteArray,
        deviceID: String?,
        pairingToken: ByteArray?
    ): ByteArray {
        val json = JSONObject().apply {
            put("deviceName", deviceName)
            put("publicKey", encodeBase64(publicKey))
            if (deviceID != null) put("deviceID", deviceID)
            if (pairingToken != null) put("pairingToken", encodeBase64(pairingToken))
        }
        return encode(TYPE_PAIR_REQUEST, json.toString().toByteArray())
    }

    /**
     * Build a challenge response message JSON.
     */
    fun buildChallengeResponse(
        challengeID: String,
        signature: ByteArray,
        deviceID: String
    ): ByteArray {
        val json = JSONObject().apply {
            put("challengeID", challengeID)
            put("signature", encodeBase64(signature))
            put("deviceID", deviceID)
        }
        return encode(TYPE_CHALLENGE_RESPONSE, json.toString().toByteArray())
    }

    /**
     * Build an error message JSON.
     */
    fun buildError(code: Int, description: String, challengeID: String? = null): ByteArray {
        val json = JSONObject().apply {
            put("code", code)
            put("description", description)
            if (challengeID != null) put("challengeID", challengeID)
        }
        return encode(TYPE_ERROR, json.toString().toByteArray())
    }

    // MARK: - Base64

    /**
     * Encode bytes as standard Base64 (no line wrapping, with padding).
     * Swift's JSONEncoder encodes Data as standard base64 with padding.
     */
    fun encodeBase64(data: ByteArray): String {
        return android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)
    }

    /**
     * Decode a standard Base64 string to bytes.
     */
    fun decodeBase64(s: String): ByteArray {
        return android.util.Base64.decode(s, android.util.Base64.DEFAULT)
    }
}
