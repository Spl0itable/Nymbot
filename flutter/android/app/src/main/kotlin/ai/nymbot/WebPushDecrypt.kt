package ai.nymbot

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object WebPushDecrypt {
    private const val HEADER = 21
    private const val KEY_LENGTH = 65
    private const val TAG = 16

    fun newKeyPair(): java.security.KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair()
    }

    fun rawPublic(key: ECPublicKey): ByteArray =
        byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
            else -> ByteArray(32 - bytes.size) + bytes
        }
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun agree(own: ECPrivateKey, peer: ByteArray): ByteArray {
        val x = BigInteger(1, peer.copyOfRange(1, 33))
        val y = BigInteger(1, peer.copyOfRange(33, 65))
        val spec = ECPublicKeySpec(ECPoint(x, y), own.params)
        val theirs = KeyFactory.getInstance("EC").generatePublic(spec)
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(own)
        agreement.doPhase(theirs, true)
        return agreement.generateSecret()
    }

    fun decrypt(body: ByteArray, own: ECPrivateKey, ownPublic: ByteArray, auth: ByteArray): ByteArray? {
        if (body.size < HEADER) return null
        val salt = body.copyOfRange(0, 16)
        val rs = ((body[16].toLong() and 0xff) shl 24) or
            ((body[17].toLong() and 0xff) shl 16) or
            ((body[18].toLong() and 0xff) shl 8) or
            (body[19].toLong() and 0xff)
        val idLength = body[20].toInt() and 0xff
        if (idLength != KEY_LENGTH || rs <= TAG + 1 || rs > Int.MAX_VALUE) return null
        val start = HEADER + idLength
        if (body.size <= start + TAG) return null
        val peer = body.copyOfRange(HEADER, start)
        if (peer[0].toInt() != 4 || ownPublic.size != KEY_LENGTH) return null
        val secret = agree(own, peer)
        val prkKey = hmac(auth, secret)
        val keyInfo = "WebPush: info".toByteArray(Charsets.US_ASCII) + byteArrayOf(0) + ownPublic + peer
        val ikm = hmac(prkKey, keyInfo + byteArrayOf(1))
        val prk = hmac(salt, ikm)
        val cek = hmac(prk, "Content-Encoding: aes128gcm".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 1)).copyOf(16)
        val base = hmac(prk, "Content-Encoding: nonce".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 1)).copyOf(12)
        val out = ByteArrayOutputStream()
        val size = rs.toInt()
        var offset = start
        var seq = 0L
        while (offset < body.size) {
            val end = if (body.size - offset > size) offset + size else body.size
            val last = end == body.size
            val nonce = base.copyOf()
            for (i in 0 until 8) {
                val shift = 8 * i
                nonce[11 - i] = (nonce[11 - i].toInt() xor ((seq ushr shift).toInt() and 0xff)).toByte()
            }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(cek, "AES"), GCMParameterSpec(TAG * 8, nonce))
            val plain = try {
                cipher.doFinal(body, offset, end - offset)
            } catch (e: Exception) {
                return null
            }
            var cut = plain.size - 1
            while (cut >= 0 && plain[cut].toInt() == 0) cut--
            if (cut < 0) return null
            val delimiter = plain[cut].toInt()
            if (delimiter != (if (last) 2 else 1)) return null
            out.write(plain, 0, cut)
            offset = end
            seq++
        }
        return out.toByteArray()
    }
}
