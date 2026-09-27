package ai.nymbot

import android.app.Activity
import android.os.Build
import android.os.CancellationSignal
import androidx.core.content.ContextCompat
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object PasskeyBridge {
    private const val CHANNEL = "ai.nymbot/passkey"

    fun attach(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(activity, call, result) }
    }

    private fun manager(activity: Activity): CredentialManager? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return try {
            CredentialManager.create(activity)
        } catch (e: Throwable) {
            null
        }
    }

    private fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(manager(activity) != null)
            "create" -> create(activity, call.argument<String>("request"), result)
            "get" -> get(activity, call.argument<String>("request"), result)
            else -> result.notImplemented()
        }
    }

    private fun create(activity: Activity, request: String?, result: MethodChannel.Result) {
        val credentials = manager(activity)
        if (credentials == null || request == null) {
            result.error("unavailable", null, null)
            return
        }
        val made = try {
            CreatePublicKeyCredentialRequest(request)
        } catch (e: Throwable) {
            result.error("failed", e.message, null)
            return
        }
        credentials.createCredentialAsync(
            activity,
            made,
            CancellationSignal(),
            ContextCompat.getMainExecutor(activity),
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(response: CreateCredentialResponse) {
                    if (response is CreatePublicKeyCredentialResponse) {
                        result.success(response.registrationResponseJson)
                    } else {
                        result.error("failed", "unexpected response", null)
                    }
                }

                override fun onError(e: CreateCredentialException) {
                    if (e is CreateCredentialCancellationException) {
                        result.error("cancelled", null, null)
                    } else {
                        result.error("failed", e.message, null)
                    }
                }
            },
        )
    }

    private fun get(activity: Activity, request: String?, result: MethodChannel.Result) {
        val credentials = manager(activity)
        if (credentials == null || request == null) {
            result.error("unavailable", null, null)
            return
        }
        val asked = try {
            GetCredentialRequest(listOf(GetPublicKeyCredentialOption(request)))
        } catch (e: Throwable) {
            result.error("failed", e.message, null)
            return
        }
        credentials.getCredentialAsync(
            activity,
            asked,
            CancellationSignal(),
            ContextCompat.getMainExecutor(activity),
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(response: GetCredentialResponse) {
                    val credential = response.credential
                    if (credential is PublicKeyCredential) {
                        result.success(credential.authenticationResponseJson)
                    } else {
                        result.error("failed", "unexpected credential", null)
                    }
                }

                override fun onError(e: GetCredentialException) {
                    when (e) {
                        is GetCredentialCancellationException -> result.error("cancelled", null, null)
                        is NoCredentialException -> result.error("none", null, null)
                        else -> result.error("failed", e.message, null)
                    }
                }
            },
        )
    }
}
