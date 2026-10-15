package app.overblast.feedback.flutter

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The Android half of the `overblast_feedback/device` channel (docs/feedback-reports.md §8).
 *
 * Every key is an EC P-256 signing key in the Android Keystore, so the private half never leaves the
 * device's keystore (TEE, or StrongBox where there is one):
 *
 * - `attestAndroid(alias, nonce)` makes the key with `setAttestationChallenge(nonce)` and answers its
 *   certificate chain, leaf first. Google's hardware attestation in that chain names the app's
 *   package and signing certificate, which is what lets the worker call the device `attested`. This
 *   is key attestation, not Play Integrity: nothing here talks to Google, and it needs no Play
 *   services and no credential.
 * - `createPlainKey(alias)` makes the same kind of key without a challenge, for the proof-of-work
 *   fallback, and answers its SPKI.
 * - `sign(alias, data)` (also answered as `signAndroid`) is SHA256withECDSA, which is DER.
 * - `deleteKey(alias)`.
 * - `lastExit()` (docs/feedback-reports.md §3.4): how the app's previous process ended, from
 *   `ApplicationExitInfo` on API 30+, when that was a crash, an ANR or the system reclaiming memory.
 *
 * Binary answers are base64url without padding, except the chain, which is standard base64 DER as
 * the contract writes it. Errors carry one of the codes the Dart side reads: `unsupported`,
 * `invalid_key`, `bad_args`, `failed`.
 */
class OverblastFeedbackPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    // Key generation can take seconds (StrongBox especially); none of it runs on the main thread.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "overblast_feedback/device")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "appAttest" to false,
                    "androidKeyAttestation" to true,
                    "plainKey" to true,
                    "secureHardware" to hasStrongBox(),
                ),
            )
            "attestAndroid" -> {
                val alias = call.argument<String>("alias")
                val nonce = call.argument<String>("nonce")?.let(::decode)
                if (alias.isNullOrEmpty() || nonce == null) return badArgs(result, "alias, nonce")
                run(result) {
                    generate(alias, nonce)
                    val chain = keyStore().getCertificateChain(alias)
                        ?: throw DeviceKeyError("failed", "no certificate chain for the new key")
                    chain.map { Base64.encodeToString(it.encoded, Base64.NO_WRAP) }
                }
            }
            "createPlainKey" -> {
                val alias = call.argument<String>("alias")
                if (alias.isNullOrEmpty()) return badArgs(result, "alias")
                run(result) { encode(generate(alias, null)) }
            }
            "sign", "signAndroid" -> {
                val alias = call.argument<String>("alias")
                val data = call.argument<String>("data")?.let(::decode)
                if (alias.isNullOrEmpty() || data == null) return badArgs(result, "alias, data")
                run(result) {
                    val key = keyStore().getKey(alias, null) as? PrivateKey
                        ?: throw DeviceKeyError("invalid_key", "no key under $alias")
                    val signer = Signature.getInstance("SHA256withECDSA")
                    signer.initSign(key)
                    signer.update(data)
                    encode(signer.sign())
                }
            }
            "lastExit" -> run(result) { lastExit() }
            "deleteKey" -> {
                val alias = call.argument<String>("alias") ?: return badArgs(result, "alias")
                run(result) {
                    val store = keyStore()
                    if (store.containsAlias(alias)) store.deleteEntry(alias)
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Makes a fresh P-256 signing key under [alias] (replacing any key there) and answers its SPKI.
     * With a [challenge], the keystore attests it. StrongBox is tried first where the device has it,
     * then the TEE: some StrongBox implementations refuse attestation or a curve, and the TEE level
     * is still hardware for the worker's purposes (§8.1).
     */
    private fun generate(alias: String, challenge: ByteArray?): ByteArray {
        val store = keyStore()
        if (store.containsAlias(alias)) store.deleteEntry(alias)
        var lastError: Exception? = null
        for (strongBox in if (hasStrongBox()) listOf(true, false) else listOf(false)) {
            try {
                val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                if (challenge != null) spec.setAttestationChallenge(challenge)
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
                val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
                generator.initialize(spec.build())
                return generator.generateKeyPair().public.encoded // X.509 SubjectPublicKeyInfo
            } catch (e: Exception) {
                lastError = e
                if (store.containsAlias(alias)) store.deleteEntry(alias)
            }
        }
        throw DeviceKeyError("failed", "key generation failed: ${lastError?.message ?: lastError?.javaClass?.name}")
    }

    /**
     * The newest exit record for this package, mapped to the contract's kinds: a crash (Java or
     * native, or a failed start) is `crash`, an ANR or a kill for excessive resource use is `killed`,
     * low memory is `oom`. An ordinary exit (the app finishing, the user swiping it away, an update)
     * answers null. The Dart side only uses a record from inside a session that never closed.
     */
    private fun lastExit(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val ctx = context ?: return null
        val manager = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
        val info = manager.getHistoricalProcessExitReasons(ctx.packageName, 0, 1).firstOrNull() ?: return null
        val (kind, name) = when (info.reason) {
            ApplicationExitInfo.REASON_CRASH -> "crash" to "crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash" to "native crash"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "crash" to "initialization failure"
            ApplicationExitInfo.REASON_ANR -> "killed" to "ANR"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "killed" to "excessive resource use"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "oom" to "low memory"
            else -> return null
        }
        val description = info.description?.takeIf { it.isNotBlank() }
        return mapOf(
            "kind" to kind,
            "source" to "exit_info",
            "at" to info.timestamp,
            "message" to (if (description == null) name else "$name: $description").take(2000),
        )
    }

    private fun hasStrongBox(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context?.packageManager?.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE) == true

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: DeviceKeyError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("failed", "${e.javaClass.simpleName}: ${e.message}", null) }
            }
        }
    }

    private fun badArgs(result: MethodChannel.Result, names: String) =
        result.error("bad_args", "missing or malformed: $names", null)

    private class DeviceKeyError(val code: String, message: String) : Exception(message)

    private companion object {
        fun encode(bytes: ByteArray): String =
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

        /** base64 or base64url, padded or not. */
        fun decode(text: String): ByteArray? = try {
            Base64.decode(text.replace('-', '+').replace('_', '/'), Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}
