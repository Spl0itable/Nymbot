package ai.nymbot

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.util.UUID

object UnifiedPush {
    const val ACTION_REGISTER = "org.unifiedpush.android.distributor.REGISTER"
    const val ACTION_UNREGISTER = "org.unifiedpush.android.distributor.UNREGISTER"
    const val ACTION_ACK = "org.unifiedpush.android.distributor.MESSAGE_ACK"
    const val ACTION_MESSAGE = "org.unifiedpush.android.connector.MESSAGE"
    const val ACTION_NEW_ENDPOINT = "org.unifiedpush.android.connector.NEW_ENDPOINT"
    const val ACTION_FAILED = "org.unifiedpush.android.connector.REGISTRATION_FAILED"
    const val ACTION_UNREGISTERED = "org.unifiedpush.android.connector.UNREGISTERED"
    private const val FEATURE_BYTES = "org.unifiedpush.android.distributor.feature.BYTES_MESSAGE"
    private const val PREFS = "nymbot_push"
    private const val KEY_TOKEN = "token"
    private const val KEY_DISTRIBUTOR = "distributor"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_PRIVATE = "private"
    private const val KEY_PUBLIC = "public"
    private const val KEY_AUTH = "auth"
    private const val KEY_CHANNEL = "channel"
    private const val KEY_TEXTS = "texts"
    private const val KEY_PUSHED = "pushed"
    private const val PUSHED_MAX = 100
    private val PR_STATES = setOf("ci-failed", "review", "pr")
    private const val B64 = Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun token(context: Context): String? = prefs(context).getString(KEY_TOKEN, null)

    fun distributor(context: Context): String? = prefs(context).getString(KEY_DISTRIBUTOR, null)

    @Suppress("DEPRECATION")
    fun distributors(context: Context): List<Map<String, String>> {
        val manager = context.packageManager
        val found = try {
            manager.queryBroadcastReceivers(Intent(ACTION_REGISTER), 0)
        } catch (t: Throwable) {
            emptyList()
        }
        return found
            .mapNotNull { info ->
                val pkg = info.activityInfo?.packageName ?: return@mapNotNull null
                if (pkg == context.packageName) return@mapNotNull null
                val name = try {
                    manager.getApplicationLabel(manager.getApplicationInfo(pkg, 0)).toString()
                } catch (t: Throwable) {
                    pkg
                }
                mapOf("package" to pkg, "name" to name)
            }
            .distinctBy { it["package"] }
    }

    private fun ensureKeys(context: Context) {
        val store = prefs(context)
        if (store.getString(KEY_PRIVATE, null) != null &&
            store.getString(KEY_PUBLIC, null) != null &&
            store.getString(KEY_AUTH, null) != null
        ) {
            return
        }
        val pair = WebPushDecrypt.newKeyPair()
        val auth = ByteArray(16)
        SecureRandom().nextBytes(auth)
        store.edit()
            .putString(KEY_PRIVATE, Base64.encodeToString(pair.private.encoded, B64))
            .putString(KEY_PUBLIC, Base64.encodeToString(WebPushDecrypt.rawPublic(pair.public as ECPublicKey), B64))
            .putString(KEY_AUTH, Base64.encodeToString(auth, B64))
            .commit()
    }

    private fun identify(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent("ai.nymbot.UNIFIEDPUSH_ID").setPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )

    fun register(context: Context, distributor: String, channelName: String?, texts: Map<*, *>?): Boolean {
        if (distributors(context).none { it["package"] == distributor }) return false
        ensureKeys(context)
        val store = prefs(context)
        val previous = store.getString(KEY_DISTRIBUTOR, null)
        val token = store.getString(KEY_TOKEN, null)?.takeIf { previous == distributor } ?: UUID.randomUUID().toString()
        if (previous != null && previous != distributor) unregister(context)
        val edit = store.edit()
            .putString(KEY_TOKEN, token)
            .putString(KEY_DISTRIBUTOR, distributor)
        if (previous != distributor) edit.remove(KEY_ENDPOINT)
        if (channelName != null) edit.putString(KEY_CHANNEL, channelName)
        if (texts != null) edit.putString(KEY_TEXTS, JSONObject(texts.mapKeys { "${it.key}" }).toString())
        edit.commit()
        val intent = Intent(ACTION_REGISTER).apply {
            `package` = distributor
            putExtra("token", token)
            putExtra("application", context.packageName)
            putExtra("message", "Nymbot")
            putExtra("features", arrayOf(FEATURE_BYTES))
            putExtra("pi", identify(context))
        }
        return try {
            context.sendBroadcast(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    fun unregister(context: Context) {
        val store = prefs(context)
        val token = store.getString(KEY_TOKEN, null)
        val distributor = store.getString(KEY_DISTRIBUTOR, null)
        if (token != null && distributor != null) {
            try {
                context.sendBroadcast(
                    Intent(ACTION_UNREGISTER).apply {
                        `package` = distributor
                        putExtra("token", token)
                        putExtra("application", context.packageName)
                        putExtra("pi", identify(context))
                    },
                )
            } catch (t: Throwable) {
            }
        }
        store.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_DISTRIBUTOR)
            .remove(KEY_ENDPOINT)
            .commit()
    }

    fun state(context: Context): Map<String, String>? {
        val store = prefs(context)
        val endpoint = store.getString(KEY_ENDPOINT, null) ?: return null
        val pub = store.getString(KEY_PUBLIC, null) ?: return null
        val auth = store.getString(KEY_AUTH, null) ?: return null
        return mapOf(
            "endpoint" to endpoint,
            "p256dh" to pub,
            "auth" to auth,
            "distributor" to (store.getString(KEY_DISTRIBUTOR, null) ?: ""),
        )
    }

    fun setChannelName(context: Context, name: String?) {
        if (name != null) prefs(context).edit().putString(KEY_CHANNEL, name).apply()
    }

    fun takePushed(context: Context): List<String> {
        val store = prefs(context)
        val raw = store.getString(KEY_PUSHED, null) ?: return emptyList()
        store.edit().remove(KEY_PUSHED).apply()
        return try {
            val list = JSONArray(raw)
            (0 until list.length()).mapNotNull { list.optString(it).takeIf { id -> id.isNotEmpty() } }
        } catch (t: Throwable) {
            emptyList()
        }
    }

    private fun notePushed(context: Context, id: String) {
        val store = prefs(context)
        val list = try {
            JSONArray(store.getString(KEY_PUSHED, null) ?: "[]")
        } catch (t: Throwable) {
            JSONArray()
        }
        val kept = JSONArray()
        val start = if (list.length() >= PUSHED_MAX) list.length() - PUSHED_MAX + 1 else 0
        for (i in start until list.length()) kept.put(list.optString(i))
        kept.put(id)
        store.edit().putString(KEY_PUSHED, kept.toString()).apply()
    }

    fun trusted(context: Context, intent: Intent): Boolean {
        val token = intent.getStringExtra("token") ?: return false
        if (token != token(context)) return false
        val saved = distributor(context) ?: return false
        val pi = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra("pi", PendingIntent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<PendingIntent>("pi")
        }
        return pi == null || pi.creatorPackage == saved
    }

    fun endpoint(context: Context, endpoint: String?) {
        val edit = prefs(context).edit()
        if (endpoint.isNullOrEmpty()) edit.remove(KEY_ENDPOINT) else edit.putString(KEY_ENDPOINT, endpoint)
        edit.apply()
    }

    fun ack(context: Context, id: String) {
        val token = token(context) ?: return
        val distributor = distributor(context) ?: return
        try {
            context.sendBroadcast(
                Intent(ACTION_ACK).apply {
                    `package` = distributor
                    putExtra("token", token)
                    putExtra("id", id)
                },
            )
        } catch (t: Throwable) {
        }
    }

    fun message(context: Context, body: ByteArray): Boolean {
        val store = prefs(context)
        val own = store.getString(KEY_PRIVATE, null) ?: return false
        val pub = store.getString(KEY_PUBLIC, null) ?: return false
        val auth = store.getString(KEY_AUTH, null) ?: return false
        val plain = try {
            val key = KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(Base64.decode(own, B64))) as ECPrivateKey
            WebPushDecrypt.decrypt(body, key, Base64.decode(pub, B64), Base64.decode(auth, B64))
        } catch (t: Throwable) {
            null
        } ?: return false
        val data = try {
            JSONObject(String(plain, Charsets.UTF_8))
        } catch (t: Throwable) {
            return false
        }
        val state = data.optString("state")
        val chat = data.optString("chat").takeIf { it.isNotEmpty() }
            ?: data.optString("asked").takeIf { it.isNotEmpty() }
            ?: data.optString("schedule").takeIf { it.isNotEmpty() }
            ?: return false
        val asked = data.optString("asked").takeIf { it.isNotEmpty() }
        val texts = try {
            JSONObject(store.getString(KEY_TEXTS, null) ?: "{}")
        } catch (t: Throwable) {
            JSONObject()
        }
        val title = texts.optString(if (state in PR_STATES) "title:pr" else "title:$state").takeIf { it.isNotEmpty() }
            ?: data.optString("title").takeIf { it.isNotEmpty() }
            ?: "Nymbot"
        val text = texts.optString(state).takeIf { it.isNotEmpty() && state != "done" && state != "due" }
            ?: data.optString("body")
        val channel = store.getString(KEY_CHANNEL, null) ?: "Replies"
        val shown = ReplyNotifier.post(context, chat, title, text, channel, asked)
        if (asked != null) notePushed(context, asked)
        return shown
    }
}

class UnifiedPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!UnifiedPush.trusted(context, intent)) return
        when (intent.action) {
            UnifiedPush.ACTION_NEW_ENDPOINT -> UnifiedPush.endpoint(context, intent.getStringExtra("endpoint"))
            UnifiedPush.ACTION_FAILED, UnifiedPush.ACTION_UNREGISTERED -> UnifiedPush.endpoint(context, null)
            UnifiedPush.ACTION_MESSAGE -> {
                val body = intent.getByteArrayExtra("bytesMessage")
                    ?: intent.getStringExtra("message")?.toByteArray(Charsets.UTF_8)
                if (body != null) UnifiedPush.message(context, body)
                intent.getStringExtra("id")?.let { UnifiedPush.ack(context, it) }
            }
        }
    }
}
