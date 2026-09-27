package ai.nymbot

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// FlutterFragmentActivity rather than FlutterActivity: platform plugins that
// present system dialogs (the keystore's biometric prompt among them) require a
// FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
    private var intents: MethodChannel? = null
    private val pending = mutableListOf<Map<String, Any?>>()
    private val maxSharedBytes = 50 * 1024 * 1024
    private val maxSharedTotal = 80 * 1024 * 1024
    private val maxSharedFiles = 10
    private var recorder: MediaRecorder? = null
    private var recording: File? = null
    private var waitingForMic: MethodChannel.Result? = null
    private val micRequest = 4107
    private val signerWaiting = mutableMapOf<Int, MethodChannel.Result>()
    private var signerCode = 5200

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val incoming = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.nymbot/intents")
        incoming.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                val held = ArrayList(pending)
                pending.clear()
                result.success(held)
            } else {
                result.notImplemented()
            }
        }
        intents = incoming
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.nymbot/dictate")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> startDictation(result)
                    "stop" -> result.success(stopDictation(true))
                    "level" -> result.success(dictationLevel())
                    "cancel" -> {
                        stopDictation(false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        intent?.let { first ->
            read(first)?.let {
                pending.add(it)
                setIntent(Intent(Intent.ACTION_MAIN))
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.nymbot/secure")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "secure" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "copySecret" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("failed", null, null)
                        } else {
                            result.success(copySecret(text))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.nymbot/vault_key")
            .setMethodCallHandler { call, result -> vaultKey(call, Reply(result)) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.nymbot/signer")
            .setMethodCallHandler { call, result -> signer(call, result) }
        ReplyNotifier.attach(this, flutterEngine)
        PasskeyBridge.attach(this, flutterEngine)
    }

    private fun signer(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "apps" -> result.success(signerApps())
            "getPublicKey" -> signerIntent(
                "get_public_key",
                "",
                call.argument<String>("package"),
                mapOf("permissions" to call.argument<String>("permissions")),
                result,
            )
            "signEvent" -> {
                val event = call.argument<String>("event") ?: return result.error("failed", null, null)
                val current = call.argument<String>("current") ?: ""
                signerOp(
                    call.argument<String>("package"),
                    "sign_event",
                    "SIGN_EVENT",
                    event,
                    arrayOf(event, "", current),
                    mapOf("current_user" to current, "id" to call.argument<String>("id")),
                    result,
                )
            }
            "nip44Encrypt", "nip44Decrypt" -> {
                val encrypt = call.method == "nip44Encrypt"
                val text = call.argument<String>("text") ?: return result.error("failed", null, null)
                val peer = call.argument<String>("peer") ?: return result.error("failed", null, null)
                val current = call.argument<String>("current") ?: ""
                signerOp(
                    call.argument<String>("package"),
                    if (encrypt) "nip44_encrypt" else "nip44_decrypt",
                    if (encrypt) "NIP44_ENCRYPT" else "NIP44_DECRYPT",
                    text,
                    arrayOf(text, peer, current),
                    mapOf("current_user" to current, "pubkey" to peer, "id" to newSignerId()),
                    result,
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun copySecret(text: String): Boolean = try {
        val clip = ClipData.newPlainText("", text)
        val extras = PersistableBundle()
        if (Build.VERSION.SDK_INT >= 33) {
            extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        } else {
            extras.putBoolean("android.content.extra.IS_SENSITIVE", true)
        }
        clip.description.extras = extras
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
        true
    } catch (e: Exception) {
        false
    }

    private fun newSignerId(): String = java.util.UUID.randomUUID().toString()

    @Suppress("DEPRECATION")
    private fun signerApps(): List<Map<String, String>> {
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:"))
        val found = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.queryIntentActivities(probe, PackageManager.ResolveInfoFlags.of(0))
        } else {
            packageManager.queryIntentActivities(probe, 0)
        }
        return found
            .map {
                mapOf(
                    "package" to it.activityInfo.packageName,
                    "name" to it.loadLabel(packageManager).toString(),
                )
            }
            .distinctBy { it["package"] }
    }

    private fun signerOp(
        pkg: String?,
        type: String,
        provider: String,
        content: String,
        projection: Array<String>,
        extras: Map<String, String?>,
        result: MethodChannel.Result,
    ) {
        if (pkg.isNullOrEmpty()) return result.error("unavailable", null, null)
        Thread {
            val quiet = signerQuery(pkg, provider, projection)
            runOnUiThread {
                when {
                    quiet == null -> signerIntent(type, content, pkg, extras, result)
                    quiet["rejected"] == true -> result.error("rejected", null, null)
                    else -> result.success(quiet)
                }
            }
        }.start()
    }

    private fun signerQuery(pkg: String, provider: String, projection: Array<String>): Map<String, Any?>? =
        try {
            contentResolver.query(
                Uri.parse("content://$pkg.$provider"),
                projection,
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.getColumnIndex("rejected") >= 0) return@use mapOf("rejected" to true)
                if (!cursor.moveToFirst()) return@use null
                val value = cursor.getColumnIndex("result")
                if (value < 0) return@use null
                val event = cursor.getColumnIndex("event")
                mapOf(
                    "result" to cursor.getString(value),
                    "event" to if (event >= 0) cursor.getString(event) else null,
                    "package" to pkg,
                )
            }
        } catch (e: Exception) {
            null
        }

    @Suppress("DEPRECATION")
    private fun signerIntent(
        type: String,
        content: String,
        pkg: String?,
        extras: Map<String, String?>,
        result: MethodChannel.Result,
    ) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("nostrsigner:$content"))
        if (!pkg.isNullOrEmpty()) intent.`package` = pkg
        intent.putExtra("type", type)
        for ((key, value) in extras) {
            if (value != null) intent.putExtra(key, value)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val code = signerCode++
        if (signerCode > 5999) signerCode = 5200
        signerWaiting[code] = result
        try {
            startActivityForResult(intent, code)
        } catch (e: ActivityNotFoundException) {
            signerWaiting.remove(code)
            result.error("unavailable", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val waiting = signerWaiting.remove(requestCode)
        if (waiting == null) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            waiting.error("rejected", null, null)
            return
        }
        if (data.getBooleanExtra("rejected", false)) {
            waiting.error("rejected", null, null)
            return
        }
        waiting.success(
            mapOf(
                "result" to (data.getStringExtra("result") ?: data.getStringExtra("signature")),
                "event" to data.getStringExtra("event"),
                "package" to data.getStringExtra("package"),
                "id" to data.getStringExtra("id"),
            ),
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (ReplyNotifier.handleIntent(intent)) return
        val payload = read(intent) ?: return
        val channel = intents
        if (channel == null) pending.add(payload) else channel.invokeMethod("incoming", payload)
    }

    private fun startDictation(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            waitingForMic?.error("busy", null, null)
            waitingForMic = result
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), micRequest)
            return
        }
        beginRecording(result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != micRequest) return
        val result = waitingForMic ?: return
        waitingForMic = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            beginRecording(result)
        } else {
            result.error("denied", null, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun newRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()

    private fun beginRecording(result: MethodChannel.Result) {
        stopDictation(false)
        try {
            val file = File(cacheDir, "dictation.m4a")
            val made = newRecorder()
            made.setAudioSource(MediaRecorder.AudioSource.MIC)
            made.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            made.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            made.setAudioChannels(1)
            made.setAudioSamplingRate(16000)
            made.setAudioEncodingBitRate(32000)
            made.setOutputFile(file.absolutePath)
            made.prepare()
            made.start()
            recorder = made
            recording = file
            result.success(true)
        } catch (e: Exception) {
            stopDictation(false)
            result.error("unavailable", e.message, null)
        }
    }

    private fun dictationLevel(): Double? {
        val made = recorder ?: return null
        val amplitude = try {
            made.maxAmplitude
        } catch (e: Exception) {
            return null
        }
        if (amplitude <= 0) return 0.0
        val db = 20.0 * Math.log10(amplitude / 32767.0)
        return ((db + 60.0) / 60.0).coerceIn(0.0, 1.0)
    }

    private fun stopDictation(keep: Boolean): ByteArray? {
        val made = recorder ?: return null
        recorder = null
        val file = recording
        recording = null
        var ok = true
        try {
            made.stop()
        } catch (e: Exception) {
            ok = false
        }
        made.release()
        val bytes = if (keep && ok && file != null && file.exists()) file.readBytes() else null
        file?.delete()
        return bytes
    }

    private fun read(intent: Intent): Map<String, Any?>? {
        when (intent.action) {
            Intent.ACTION_VIEW -> {
                val url = intent.dataString ?: return null
                return mapOf("type" to "link", "url" to url)
            }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                val files = mutableListOf<Map<String, Any>>()
                var budget = maxSharedTotal
                for (uri in streams(intent).take(maxSharedFiles)) {
                    val got = file(uri, minOf(maxSharedBytes, budget)) ?: continue
                    budget -= (got["bytes"] as ByteArray).size
                    files.add(got)
                }
                if (text.isNullOrBlank() && files.isEmpty()) return null
                return mapOf("type" to "share", "text" to text, "files" to files)
            }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            return list ?: emptyList()
        }
        val one = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        return if (one == null) emptyList() else listOf(one)
    }

    private fun foreign(uri: Uri): Boolean {
        if (uri.scheme?.lowercase() != ContentResolver.SCHEME_CONTENT) return false
        val authority = uri.authority?.lowercase() ?: return false
        val own = packageName.lowercase()
        if (authority.split(';').any { it == own || it.startsWith("$own.") }) return false
        val owner = try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.resolveContentProvider(authority, PackageManager.ComponentInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.resolveContentProvider(authority, 0)
            }
        } catch (e: Exception) {
            null
        }
        return owner?.packageName != packageName
    }

    private fun file(uri: Uri, limit: Int): Map<String, Any>? = if (!foreign(uri)) null else try {
        var name: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0)
        }
        val mime = try {
            contentResolver.getType(uri)
        } catch (e: Exception) {
            null
        }
        val bytes = contentResolver.openInputStream(uri)?.use { stream ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                total += n
                if (total > limit) return@use null
                out.write(buffer, 0, n)
            }
            out.toByteArray()
        }
        if (bytes == null) null else mapOf("name" to label(name, mime), "bytes" to bytes)
    } catch (e: Exception) {
        null
    }

    private fun label(raw: String?, mime: String?): String {
        var name = (raw ?: "").substringAfterLast('/').substringAfterLast('\\')
        name = name.filter { !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt() }
        name = name.trim().trimStart('.').trim()
        if (name.length > 120) {
            val dot = name.lastIndexOf('.')
            val ext = if (dot > 0 && name.length - dot <= 10) name.substring(dot) else ""
            name = name.take(120 - ext.length) + ext
        }
        if (name.isEmpty()) name = "shared"
        if (!name.contains('.')) {
            val ext = extensionFor(mime)
            if (ext != null) name = "$name.$ext"
        }
        return name
    }

    private fun extensionFor(mime: String?): String? {
        val type = mime?.lowercase()?.substringBefore(';')?.trim() ?: return null
        return when (type) {
            "image/jpeg" -> "jpg"
            "video/quicktime" -> "mov"
            "text/plain" -> "txt"
            "text/markdown" -> "md"
            "application/pdf" -> "pdf"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            else -> android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(type)
        }
    }

    private class Reply(private val result: MethodChannel.Result) {
        private var sent = false

        fun success(value: Any?) {
            if (sent) return
            sent = true
            result.success(value)
        }

        fun error(code: String, message: String?) {
            if (sent) return
            sent = true
            result.error(code, message, null)
        }
    }

    private val keyAlias = "nymbot_vault_key"
    private val keyFile: File get() = File(filesDir, "nymbot_vault_key.bin")

    private fun vaultKey(call: MethodCall, reply: Reply) {
        try {
            when (call.method) {
                "store" -> storeKey(
                    call.argument<String>("secret") ?: return reply.error("failed", null),
                    call.argument<String>("title") ?: "",
                    call.argument<String>("cancel") ?: "",
                    reply,
                )
                "load" -> loadKey(
                    call.argument<String>("title") ?: "",
                    call.argument<String>("cancel") ?: "",
                    reply,
                )
                "erase" -> {
                    eraseKey()
                    reply.success(null)
                }
                else -> reply.error("unimplemented", call.method)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            eraseKey()
            reply.error("invalidated", e.message)
        } catch (e: Exception) {
            reply.error("failed", e.message)
        }
    }

    private fun storeKey(secret: String, title: String, cancel: String, reply: Reply) {
        if (BiometricManager.from(this).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            != BiometricManager.BIOMETRIC_SUCCESS
        ) {
            return reply.error("unavailable", null)
        }
        eraseKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, newKey())
        prompt(cipher, title, cancel, reply) { unlocked ->
            val sealed = unlocked.doFinal(secret.toByteArray(Charsets.UTF_8))
            keyFile.writeBytes(unlocked.iv + sealed)
            reply.success(null)
        }
    }

    private fun loadKey(title: String, cancel: String, reply: Reply) {
        val file = keyFile
        if (!file.exists()) return reply.success(null)
        val key = keyStore().getKey(keyAlias, null) as SecretKey?
        if (key == null) {
            file.delete()
            return reply.error("invalidated", null)
        }
        val bytes = file.readBytes()
        if (bytes.size <= 12) return reply.error("failed", null)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes, 0, 12))
        prompt(cipher, title, cancel, reply) { unlocked ->
            val clear = unlocked.doFinal(bytes, 12, bytes.size - 12)
            reply.success(String(clear, Charsets.UTF_8))
        }
    }

    private fun eraseKey() {
        runCatching { keyStore().deleteEntry(keyAlias) }
        keyFile.delete()
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun newKey(): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            spec.setUserAuthenticationValidityDurationSeconds(-1)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(spec.build())
        return generator.generateKey()
    }

    private fun prompt(
        cipher: Cipher,
        title: String,
        cancel: String,
        reply: Reply,
        done: (Cipher) -> Unit,
    ) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val unlocked = result.cryptoObject?.cipher ?: return reply.error("failed", null)
                try {
                    done(unlocked)
                } catch (e: Exception) {
                    reply.error("failed", e.message)
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val message = errString.toString()
                when (errorCode) {
                    BiometricPrompt.ERROR_USER_CANCELED,
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                    BiometricPrompt.ERROR_CANCELED,
                    BiometricPrompt.ERROR_TIMEOUT -> reply.error("cancelled", message)
                    BiometricPrompt.ERROR_NO_BIOMETRICS,
                    BiometricPrompt.ERROR_HW_NOT_PRESENT,
                    BiometricPrompt.ERROR_HW_UNAVAILABLE -> reply.error("unavailable", message)
                    else -> reply.error("failed", message)
                }
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText(cancel)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }
}
