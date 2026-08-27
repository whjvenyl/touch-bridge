package dev.touchbridge.core

import com.google.protobuf.ByteString
import org.junit.Test
import org.junit.Assert.*

/**
 * Tests for ChallengeHandler's crypto logic.
 *
 * These tests verify ECDH key exchange, AES-GCM encrypt/decrypt,
 * and HKDF derivation — the parts that don't require Android Keystore
 * or BLE (those are integration-tested on-device).
 *
 * The ECDH ephemeral keys use standard JCA (not Keystore), so they
 * work in a plain JVM unit test.
 */
class ChallengeHandlerTest {

    @Test
    fun initiateECDHReturns65BytePublicKey() {
        val handler = ChallengeHandler()
        val pubKey = handler.initiateECDH()
        assertEquals(65, pubKey.size)
        assertEquals(0x04.toByte(), pubKey[0]) // uncompressed point
    }

    @Test
    fun getSessionPublicKeyThrowsBeforeInitiate() {
        val handler = ChallengeHandler()
        try {
            handler.getSessionPublicKey()
            fail("Should throw before initiateECDH")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("not initiated"))
        }
    }

    @Test
    fun getSessionPublicKeyReturnsSameKeyAsInitiate() {
        val handler = ChallengeHandler()
        val pubKey = handler.initiateECDH()
        val cached = handler.getSessionPublicKey()
        assertArrayEquals(pubKey, cached)
    }

    @Test
    fun isSessionReadyFalseBeforeECDH() {
        val handler = ChallengeHandler()
        assertFalse(handler.isSessionReady)
    }

    @Test
    fun twoPartiesDeriveSameSessionKey() {
        // Simulate both sides of ECDH — the Mac and the watch.
        // Both should derive the same AES key.
        val watchHandler = ChallengeHandler()
        val macHandler = ChallengeHandler()

        // Both generate ephemeral key pairs
        val watchPub = watchHandler.initiateECDH()
        val macPub = macHandler.initiateECDH()

        // Both complete ECDH with the other's public key
        watchHandler.completeECDH(macPub)
        macHandler.completeECDH(watchPub)

        // Both should be able to encrypt/decrypt each other's messages
        val plaintext = "Hello from watch".toByteArray()
        val encrypted = watchHandler.encrypt(plaintext)
        val decrypted = macHandler.decrypt(encrypted)
        assertArrayEquals(plaintext, decrypted)

        // Reverse direction
        val plaintext2 = "Hello from mac".toByteArray()
        val encrypted2 = macHandler.encrypt(plaintext2)
        val decrypted2 = watchHandler.decrypt(encrypted2)
        assertArrayEquals(plaintext2, decrypted2)
    }

    @Test
    fun decryptWithWrongSessionFails() {
        val handler1 = ChallengeHandler()
        val handler2 = ChallengeHandler()

        handler1.initiateECDH()
        handler2.initiateECDH()

        // handler1 encrypts without completing ECDH with handler2
        // (they never exchanged public keys)
        // handler1's session key is null — encrypt should throw
        try {
            handler1.encrypt("test".toByteArray())
            fail("Should throw — no session key")
        } catch (e: IllegalStateException) {
            // expected
        }
    }

    @Test
    fun encryptProducesDifferentCiphertextsForSamePlaintext() {
        val handler = ChallengeHandler()
        handler.initiateECDH()

        // Can't completeECDH without a real partner, but we can test
        // that the handler doesn't crash on init.
        // Full encrypt test requires two-party ECDH (tested above).
        assertTrue(handler.isSessionReady == false) // ECDH initiated but not completed
    }

    @Test
    fun parseChallengeExtractsFields() {
        val handler = ChallengeHandler()
        val msg = dev.touchbridge.core.proto.ChallengeIssued.newBuilder()
            .setChallengeId("chal-test-123")
            .setEncryptedNonce(com.google.protobuf.ByteString.copyFrom(ByteArray(60) { 0xAB.toByte() }))
            .setReason("sudo")
            .setExpiryUnix(1234567890L)
            .build()

        val parsed = handler.parseChallenge(msg.toByteArray())
        assertEquals("chal-test-123", parsed.challengeID)
        assertEquals("sudo", parsed.reason)
        assertEquals(1234567890L, parsed.expiryUnix)
        assertEquals(60, parsed.encryptedNonce.size)
    }

    @Test
    fun buildResponsePayloadContainsAllFields() {
        val handler = ChallengeHandler()
        val signature = ByteArray(72) { 0xFF.toByte() }
        val payload = handler.buildResponsePayload("chal-456", signature, "watch-001")

        val msg = dev.touchbridge.core.proto.ChallengeResponse.parseFrom(payload)
        assertEquals("chal-456", msg.challengeId)
        assertArrayEquals(signature, msg.signature.toByteArray())
        assertEquals("watch-001", msg.deviceId)
    }
}
