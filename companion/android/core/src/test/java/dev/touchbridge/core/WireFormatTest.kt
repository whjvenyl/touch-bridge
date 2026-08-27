package dev.touchbridge.core

import com.google.protobuf.ByteString
import org.junit.Test
import org.junit.Assert.*

/**
 * Golden vector tests for the core WireFormat module.
 *
 * These vectors must match the Swift golden vectors in
 * protocol/golden/wire_vectors.json — both platforms must produce
 * byte-identical wire output.
 */
class WireFormatTest {

    @Test
    fun encodeProducesCorrectHeader() {
        val payload = byteArrayOf(0x0A, 0x03, 0x41, 0x42, 0x43)
        val encoded = WireFormat.encode(WireFormat.TYPE_PAIR_REQUEST, payload)
        assertEquals("version byte", Constants.PROTOCOL_VERSION, encoded[0])
        assertEquals("type byte", WireFormat.TYPE_PAIR_REQUEST, encoded[1])
        assertArrayEquals("payload", payload, encoded.copyOfRange(2, encoded.size))
    }

    @Test
    fun encodeThrowsOnOversize() {
        val tooBig = ByteArray(Constants.MAX_MESSAGE_SIZE - 1) // header + this > 512
        try {
            WireFormat.encode(WireFormat.TYPE_ERROR, tooBig)
            fail("Should have thrown for oversize message")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("too large"))
        }
    }

    @Test
    fun decodeRejectsTooSmallData() {
        val result = WireFormat.decode(byteArrayOf(0x01))
        assertNull(result)
    }

    @Test
    fun decodeRejectsWrongVersion() {
        val data = byteArrayOf(0x02, WireFormat.TYPE_PAIR_REQUEST, 0x0A)
        val result = WireFormat.decode(data)
        assertNull(result)
    }

    @Test
    fun decodeRoundTrip() {
        val payload = byteArrayOf(0x0A, 0x03, 0x41, 0x42, 0x43)
        val encoded = WireFormat.encode(WireFormat.TYPE_CHALLENGE_RESPONSE, payload)
        val decoded = WireFormat.decode(encoded)
        assertNotNull(decoded)
        assertEquals(WireFormat.TYPE_CHALLENGE_RESPONSE, decoded!!.first)
        assertArrayEquals(payload, decoded.second)
    }

    @Test
    fun buildIdentifyWithWatchType() {
        val signature = ByteArray(72) { 0xDD.toByte() }
        val encoded = WireFormat.buildIdentify(
            deviceID = "watch-001",
            deviceName = "Pixel Watch 2",
            signature = signature,
            deviceType = dev.touchbridge.core.proto.DeviceType.WATCH
        )
        // Verify it decodes back
        val decoded = WireFormat.decode(encoded)
        assertNotNull(decoded)
        assertEquals(WireFormat.TYPE_IDENTIFY, decoded!!.first)

        val msg = dev.touchbridge.core.proto.Identify.parseFrom(decoded.second)
        assertEquals("watch-001", msg.deviceId)
        assertEquals("Pixel Watch 2", msg.deviceName)
        assertArrayEquals(signature, msg.signature.toByteArray())
        assertEquals(dev.touchbridge.core.proto.DeviceType.WATCH, msg.deviceType)
    }

    @Test
    fun buildPairRequestWithWatchTypeAndCaps() {
        val publicKey = ByteArray(65) { 0x01 }
        val token = ByteArray(32) { 0x02 }
        val caps = dev.touchbridge.core.proto.DeviceCapabilities.newBuilder()
            .setHasBiometric(false)
            .setHasSecureEnclave(true)
            .setHasDisplay(true)
            .setHasButton(true)
            .setLatencyClass(1)
            .build()

        val encoded = WireFormat.buildPairRequest(
            deviceName = "Pixel Watch 2",
            publicKey = publicKey,
            deviceID = "watch-001",
            pairingToken = token,
            deviceType = dev.touchbridge.core.proto.DeviceType.WATCH,
            caps = caps
        )

        val decoded = WireFormat.decode(encoded)
        assertNotNull(decoded)
        assertEquals(WireFormat.TYPE_PAIR_REQUEST, decoded!!.first)

        val msg = dev.touchbridge.core.proto.PairRequest.parseFrom(decoded.second)
        assertEquals("Pixel Watch 2", msg.deviceName)
        assertEquals("watch-001", msg.deviceId)
        assertEquals(dev.touchbridge.core.proto.DeviceType.WATCH, msg.deviceType)
        assertFalse(msg.caps.hasBiometric)
        assertTrue(msg.caps.hasSecureEnclave)
        assertTrue(msg.caps.hasDisplay)
        assertTrue(msg.caps.hasButton)
        assertEquals(1, msg.caps.latencyClass)
    }

    @Test
    fun buildChallengeResponse() {
        val signature = ByteArray(72) { 0xCC.toByte() }
        val encoded = WireFormat.buildChallengeResponse("chal-123", signature, "watch-001")

        val decoded = WireFormat.decode(encoded)
        assertNotNull(decoded)
        assertEquals(WireFormat.TYPE_CHALLENGE_RESPONSE, decoded!!.first)

        val msg = dev.touchbridge.core.proto.ChallengeResponse.parseFrom(decoded.second)
        assertEquals("chal-123", msg.challengeId)
        assertArrayEquals(signature, msg.signature.toByteArray())
        assertEquals("watch-001", msg.deviceId)
    }

    @Test
    fun buildError() {
        val encoded = WireFormat.buildError(1001, "Key invalidated", "chal-err")

        val decoded = WireFormat.decode(encoded)
        assertNotNull(decoded)
        assertEquals(WireFormat.TYPE_ERROR, decoded!!.first)

        val msg = dev.touchbridge.core.proto.Error.parseFrom(decoded.second)
        assertEquals(1001, msg.code)
        assertEquals("Key invalidated", msg.description)
        assertEquals("chal-err", msg.challengeId)
    }
}
