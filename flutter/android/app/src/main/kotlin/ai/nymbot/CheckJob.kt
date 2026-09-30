package ai.nymbot

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class CheckJob : JobService() {
    private var engine: FlutterEngine? = null
    private var params: JobParameters? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { finish() }

    override fun onStartJob(job: JobParameters): Boolean {
        params = job
        handler.postDelayed(timeout, TIMEOUT_MS)
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationCompleteAsync(applicationContext, null, handler) {
                start(loader.findAppBundlePath())
            }
        } catch (t: Throwable) {
            finish()
        }
        return true
    }

    override fun onStopJob(job: JobParameters): Boolean {
        handler.removeCallbacks(timeout)
        params = null
        release()
        return false
    }

    private fun start(bundle: String) {
        if (params == null) return
        try {
            val made = FlutterEngine(applicationContext)
            engine = made
            ReplyNotifier.attachBackground(applicationContext, made)
            MethodChannel(made.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                if (call.method == "done") {
                    result.success(null)
                    handler.post { finish() }
                } else {
                    result.notImplemented()
                }
            }
            made.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, ENTRYPOINT))
        } catch (t: Throwable) {
            finish()
        }
    }

    private fun finish() {
        handler.removeCallbacks(timeout)
        val job = params
        params = null
        release()
        if (job != null) {
            try {
                jobFinished(job, false)
            } catch (t: Throwable) {
            }
        }
    }

    private fun release() {
        val made = engine ?: return
        engine = null
        try {
            made.destroy()
        } catch (t: Throwable) {
        }
    }

    companion object {
        private const val JOB_ID = 7320
        private const val CHANNEL = "ai.nymbot/check"
        private const val ENTRYPOINT = "nymbotCheck"
        private const val TIMEOUT_MS = 90_000L
        private const val PERIOD_MS = 15 * 60 * 1000L

        fun set(context: Context, on: Boolean): Boolean {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return false
            if (!on) {
                try {
                    scheduler.cancel(JOB_ID)
                } catch (t: Throwable) {
                }
                return true
            }
            if (scheduler.allPendingJobs.any { it.id == JOB_ID }) return true
            val info = JobInfo.Builder(JOB_ID, ComponentName(context, CheckJob::class.java))
                .setPeriodic(PERIOD_MS)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPersisted(true)
                .build()
            return try {
                scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
            } catch (t: Throwable) {
                false
            }
        }
    }
}
