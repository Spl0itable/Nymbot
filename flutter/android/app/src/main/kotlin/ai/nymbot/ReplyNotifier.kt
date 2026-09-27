package ai.nymbot

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object ReplyNotifier {
    private const val CHANNEL = "ai.nymbot/notify"
    private const val ACTION_OPEN = "ai.nymbot.OPEN_CHAT"
    private const val EXTRA_CHAT = "ai.nymbot.notify.chat"
    private const val WAITING_CHANNEL = "nymbot_waiting"
    private const val REPLY_CHANNEL = "nymbot_replies"
    private const val REPLY_ID = 7312
    private const val PERMISSION_REQUEST = 4211

    private var channel: MethodChannel? = null
    private var pendingChat: String? = null

    fun attach(activity: Activity, engine: FlutterEngine) {
        chatOf(activity.intent)?.let { pendingChat = it }
        val made = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        made.setMethodCallHandler { call, result -> handle(activity, call, result) }
        channel = made
    }

    fun handleIntent(intent: Intent?): Boolean {
        val chat = chatOf(intent) ?: return false
        val live = channel
        if (live == null) {
            pendingChat = chat
        } else {
            live.invokeMethod("open", chat, object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(code: String, message: String?, details: Any?) {
                    pendingChat = chat
                }
                override fun notImplemented() {
                    pendingChat = chat
                }
            })
        }
        return true
    }

    private fun chatOf(intent: Intent?): String? {
        if (intent?.action != ACTION_OPEN) return null
        return intent.getStringExtra(EXTRA_CHAT)?.takeIf { it.isNotEmpty() }
    }

    private fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val context = activity.applicationContext
        when (call.method) {
            "permission" -> result.success(askPermission(activity))
            "wait" -> result.success(
                ReplyWaitService.start(
                    context,
                    call.argument<String>("title") ?: "Nymbot",
                    call.argument<String>("text") ?: "",
                    call.argument<String>("channel") ?: "Nymbot",
                ),
            )
            "stopWaiting" -> {
                ReplyWaitService.stop(context)
                result.success(null)
            }
            "reply" -> result.success(
                showReply(
                    context,
                    call.argument<String>("chat") ?: return result.success(false),
                    call.argument<String>("title") ?: "Nymbot",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("channel") ?: "Nymbot",
                ),
            )
            "viewing" -> {
                call.argument<String>("chat")?.let { chat ->
                    try {
                        manager(context).cancel(chat, REPLY_ID)
                    } catch (t: Throwable) {
                    }
                }
                result.success(null)
            }
            "initial" -> {
                val chat = pendingChat
                pendingChat = null
                result.success(chat)
            }
            "token", "beginBackground", "endBackground" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun granted(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun askPermission(activity: Activity): Boolean {
        if (granted(activity)) return true
        try {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                PERMISSION_REQUEST,
            )
        } catch (t: Throwable) {
        }
        return false
    }

    private fun manager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel(context: Context, id: String, name: String, importance: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val made = NotificationChannel(id, name, importance)
        made.setShowBadge(id == REPLY_CHANNEL)
        manager(context).createNotificationChannel(made)
    }

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            Notification.Builder(context)
        }

    private fun launch(context: Context, chat: String?): PendingIntent? {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (chat != null) {
                action = ACTION_OPEN
                putExtra(EXTRA_CHAT, chat)
            } else {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
        }
        val code = chat?.hashCode() ?: 0
        return PendingIntent.getActivity(
            context,
            code,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun waitingNotification(context: Context, title: String, text: String, channelName: String): Notification {
        ensureChannel(context, WAITING_CHANNEL, channelName, NotificationManager.IMPORTANCE_LOW)
        return builder(context, WAITING_CHANNEL)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .apply { launch(context, null)?.let { setContentIntent(it) } }
            .build()
    }

    private fun showReply(context: Context, chat: String, title: String, body: String, channelName: String): Boolean {
        if (!granted(context)) return false
        return try {
            ensureChannel(context, REPLY_CHANNEL, channelName, NotificationManager.IMPORTANCE_HIGH)
            val shown = builder(context, REPLY_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle(title)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setPublicVersion(
                    builder(context, REPLY_CHANNEL)
                        .setSmallIcon(android.R.drawable.stat_notify_chat)
                        .setContentTitle(title)
                        .build(),
                )
                .apply {
                    if (body.isNotEmpty()) setContentText(body)
                    launch(context, chat)?.let { setContentIntent(it) }
                }
                .build()
            manager(context).notify(chat, REPLY_ID, shown)
            true
        } catch (t: Throwable) {
            false
        }
    }
}
