package dev.touchbridge.android

import dev.touchbridge.android.core.WireFormat
import dev.touchbridge.android.proto.*
import com.google.protobuf.ByteString
import org.json.JSONArray
import org.junit.Test
import org.junit.Assert.assertEquals
import java.io.File

/**
 * Cross-platform golden-file wire format tests.
 *
 * Verifies that Kotlin's WireFormat encoding produces byte-identical output
 * to the golden vectors in `protocol/golden/wire_vectors.json`. The same
 * file is consumed by the Swift test suite, ensuring both platforms agree
 * on the wire format. If this test fails, the protocol has drifted.
 *
 * To regenerate the golden file, run the Swift `generateGoldenVectors` test.
 */
class GoldenVectorTest {

    private data class GoldenVector(val name: String, val messageType: Int, val expectedHex: String)

    private fun loadGoldenVectors(): List<GoldenVector> {
        // The golden file lives at protocol/golden/wire_vectors.json relative
        // to the repo root. From companion/android/app, that's 3 levels up.
        val possiblePaths = listOf(
            "../../../protocol/golden/wire_vectors.json",
            "../../../../protocol/golden/wire_vectors.json",
        )

        for (path in possiblePaths) {
            val file = File(path)
            if (file.exists()) {
                val json = JSONArray(file.readText())
                return (0 until json.length()).map { i ->
                    val obj = json.getJSONObject(i)
                    GoldenVector(
                        name = obj.getString("name"),
                        messageType = obj.getInt("messageType"),
                        expectedHex = obj.getString("expectedHex")
                    )
                }
            }
        }

        throw AssertionError("Golden vectors file not found. Tried: $possiblePaths")
    }

    private fun toHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    @Test
    fun goldenPairRequestEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "pairRequest" } ?: throw AssertionError("pairRequest vector missing")

        val msg = PairRequest.newBuilder()
            .setDeviceName("Test iPhone")
            .setPublicKey(ByteString.copyFrom(ByteArray(65) { 0x01 }))
            .setDeviceId("device-abc")
            .setPairingToken(ByteString.copyFrom(ByteArray(16) { 0x02 }))
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_PAIR_REQUEST, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenPairResponseEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "pairResponse" } ?: throw AssertionError("pairResponse vector missing")

        val msg = PairResponse.newBuilder()
            .setDeviceId("mac-device-001")
            .setPublicKey(ByteString.copyFrom(ByteArray(65) { 0x03 }))
            .setAccepted(true)
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_PAIR_RESPONSE, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenChallengeIssuedEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "challengeIssued" } ?: throw AssertionError("challengeIssued vector missing")

        val msg = ChallengeIssued.newBuilder()
            .setChallengeId("chal-12345")
            .setEncryptedNonce(ByteString.copyFrom(ByteArray(60) { 0xAB.toByte() }))
            .setReason("sudo")
            .setExpiryUnix(1234567890)
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_CHALLENGE_ISSUED, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenChallengeResponseEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "challengeResponse" } ?: throw AssertionError("challengeResponse vector missing")

        val msg = ChallengeResponse.newBuilder()
            .setChallengeId("resp-uuid")
            .setSignature(ByteString.copyFrom(ByteArray(72) { 0xCC.toByte() }))
            .setDeviceId("device-123")
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_CHALLENGE_RESPONSE, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenErrorEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "error" } ?: throw AssertionError("error vector missing")

        val msg = Error.newBuilder()
            .setCode(1001)
            .setDescription("Key invalidated")
            .setChallengeId("chal-err")
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_ERROR, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenIdentifyEncoding() {
        val vectors = loadGoldenVectors()
        val v = vectors.find { it.name == "identify" } ?: throw AssertionError("identify vector missing")

        val signature = ByteArray(72) { 0xDD.toByte() }
        val msg = Identify.newBuilder()
            .setDeviceId("device-xyz")
            .setDeviceName("Pixel Watch")
            .setSignature(com.google.protobuf.ByteString.copyFrom(signature))
            .setDeviceType(dev.touchbridge.android.proto.DeviceType.PHONE)
            .build()
        val encoded = WireFormat.encode(WireFormat.TYPE_IDENTIFY, msg.toByteArray())

        assertEquals(v.expectedHex, toHex(encoded))
    }

    @Test
    fun goldenDecodingRoundTrip() {
        val vectors = loadGoldenVectors()

        for (v in vectors) {
            val bytes = v.expectedHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val decoded = WireFormat.decode(bytes)

            assertNotNull("Failed to decode ${v.name}", decoded)
            assertEquals("${v.name}: type mismatch", v.messageType.toByte(), decoded!!.first)
        }
    }

    private fun assertNotNull(message: String, value: Any?) {
        if (value == null) throw AssertionError(message)
    }
}
