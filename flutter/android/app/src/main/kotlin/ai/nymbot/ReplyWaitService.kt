package ai.nymbot

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ReplyWaitService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Nymbot"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Waiting for Nymbot's reply…"
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL) ?: "Waiting for replies"
        val notification = ReplyNotifier.waitingNotification(this, title, text, channelName)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (t: Throwable) {
            stopSelf()
            return START_NOT_STICKY
        }
        hold()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        finish()
    }

    override fun onDestroy() {
        release()
        super.onDestroy()
    }

    private fun finish() {
        release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun hold() {
        if (wakeLock?.isHeld == true) return
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nymbot:reply-wait").apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (t: Throwable) {
            wakeLock = null
        }
    }

    private fun release() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (t: Throwable) {
        }
        wakeLock = null
    }

    companion object {
        const val NOTIFICATION_ID = 7311
        const val EXTRA_TITLE = "ai.nymbot.wait.title"
        const val EXTRA_TEXT = "ai.nymbot.wait.text"
        const val EXTRA_CHANNEL = "ai.nymbot.wait.channel"
        private const val WAKE_LOCK_TIMEOUT_MS = 11 * 60 * 1000L

        fun start(context: Context, title: String, text: String, channelName: String): Boolean {
            val intent = Intent(context, ReplyWaitService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_CHANNEL, channelName)
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (t: Throwable) {
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ReplyWaitService::class.java))
            } catch (t: Throwable) {
            }
        }
    }
}
