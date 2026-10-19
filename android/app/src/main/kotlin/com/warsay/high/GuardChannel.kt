package com.warsay.high

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import android.util.Base64
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.util.concurrent.Executors
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * Anti-clone / anti-tamper helpers for 4 (1.0.3). Channel `com.four.student/guard`, used by
 * lib/licensing/device_guard.dart. Every method answers; failures come back as "unknown" values so the Dart
 * side can stay on the safe (do-not-relock) path.
 *
 *  - hw      ANDROID_ID (per signing key + phone + user, never copied by Smart Switch/backup) + Build values
 *  - probe   what flutter_secure_storage of 1.0.0–1.0.2 left behind, read WITHOUT decrypting it
 *  - ksMac   HMAC-SHA256 with a non-exportable Android Keystore key (created on demand)
 *  - signer  SHA-256 of the APK signing certificate(s)
 *  - env     soft signals: debuggable, debugger, Frida/Xposed in this process, root, emulator, installer
 */
class GuardChannel(private val activity: Activity) {
    companion object {
        const val CHANNEL = "com.four.student/guard"
        private const val KS = "AndroidKeyStore"
        private const val BIND_ALIAS = "four_bind_hmac_v1"
        // flutter_secure_storage 11.x defaults (no storageNamespace): data prefs, wrapped-key prefs, RSA alias
        private const val FSS_DATA = "FlutterSecureStorage"
        private const val FSS_KEYS = "FlutterSecureKeyStorage"
        private const val FSS_PROOF_SUFFIX = "_four_res_unlock_v1"
        // flutter_secure_storage 11.2.0 (the only version any 1.0.x used): RSA-OAEP key in the Keystore wraps a
        // 16-byte AES key stored in FlutterSecureKeyStorage under this name (StorageCipherImplementationGCM).
        private const val FSS_OAEP_SUFFIX = ".FlutterSecureStoragePluginKeyOAEP"
        private const val FSS_WRAPPED_AES = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
    }

    private val bg = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            bg.execute {
                val out: Any? = try {
                    when (call.method) {
                        "ping" -> "ok"
                        "hw" -> hw()
                        "probe" -> probe()
                        "ksMac" -> ksMac(call.argument<String>("data") ?: "", call.argument<Boolean>("create") ?: false)
                        "signer" -> signers()
                        "env" -> env()
                        else -> NOT_IMPLEMENTED
                    }
                } catch (e: Throwable) {
                    HighLog.w("guard ${call.method} failed: ${e.javaClass.simpleName}")
                    null
                }
                main.post {
                    if (out === NOT_IMPLEMENTED) result.notImplemented() else result.success(out)
                }
            }
        }
    }

    private object NOT_IMPLEMENTED

    private fun hw(): Map<String, Any?> = mapOf(
        "androidId" to (Settings.Secure.getString(activity.contentResolver, Settings.Secure.ANDROID_ID) ?: ""),
        "manufacturer" to Build.MANUFACTURER,
        "brand" to Build.BRAND,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "board" to Build.BOARD,
        "hardware" to Build.HARDWARE,
    )

    private fun prefsNames(prefix: String): List<String> {
        val dir = File(activity.applicationInfo.dataDir, "shared_prefs")
        val names = dir.listFiles()?.map { it.name.removeSuffix(".xml") } ?: emptyList()
        return names.filter { it == prefix || it.startsWith("$prefix:") }
    }

    private fun probe(): Map<String, Any?> {
        return try {
            val dataNames = prefsNames(FSS_DATA)
            val proofData = dataNames.any { n ->
                activity.getSharedPreferences(n, Context.MODE_PRIVATE).all.keys.any { it.endsWith(FSS_PROOF_SUFFIX) }
            }
            val wrapped = prefsNames(FSS_KEYS).any { n -> activity.getSharedPreferences(n, Context.MODE_PRIVATE).all.isNotEmpty() }
            val ks = KeyStore.getInstance(KS).apply { load(null) }
            val prefix = activity.packageName + ".FlutterSecureStoragePluginKey"
            val alias = ks.aliases().toList().any { it.startsWith(prefix) }
            val unwrap = if (proofData && wrapped && alias) unwrapCheck(ks) else "n/a"
            mapOf("ok" to true, "proofData" to proofData, "wrappedKey" to wrapped, "pluginAlias" to alias, "unwrap" to unwrap)
        } catch (e: Throwable) {
            HighLog.w("guard probe failed: ${e.javaClass.simpleName}")
            mapOf("ok" to false)
        }
    }

    /**
     * Read-only: can THIS phone's plugin RSA key unwrap the stored AES key? Creates and deletes nothing.
     *  "ok"    unwrapped (normal genuine phone)
     *  "fail"  the RSA key here is not the one that wrapped it (BadPadding): the wrapped key + proof were made on
     *          another phone and 1.0.2 later created a fresh RSA key here (Smart Switch copy opened with 1.0.2)
     *  "error" anything else (Keystore busy, unexpected layout) - proves nothing
     * The Dart side relocks on "fail" only if the plugin itself also cannot read the proof, so a mistake here can
     * never relock a phone whose 1.0.x proof still reads fine.
     */
    private fun unwrapCheck(ks: KeyStore): String = try {
        val alias = activity.packageName + FSS_OAEP_SUFFIX
        val key = ks.getKey(alias, null) as? PrivateKey
        val b64 = activity.getSharedPreferences(FSS_KEYS, Context.MODE_PRIVATE).getString(FSS_WRAPPED_AES, null)
        if (key == null || b64 == null) "error" else {
            val c = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround")
            c.init(Cipher.UNWRAP_MODE, key, OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT))
            c.unwrap(Base64.decode(b64, Base64.DEFAULT), "AES", Cipher.SECRET_KEY)
            "ok"
        }
    } catch (e: Throwable) {
        var t: Throwable? = e
        var bad = false
        while (t != null && !bad) {
            // only OAEP unpadding failure (BC software, wrong key); Keystore maps unknown errors to
            // IllegalBlockSizeException, so that one is NOT treated as evidence
            bad = t is BadPaddingException
            val next = t.cause
            t = if (next === t) null else next
        }
        HighLog.w("guard unwrap: ${e.javaClass.simpleName}")
        if (bad) "fail" else "error"
    }

    private fun bindKey(create: Boolean): SecretKey? {
        val ks = KeyStore.getInstance(KS).apply { load(null) }
        (ks.getKey(BIND_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, KS)
        gen.init(KeyGenParameterSpec.Builder(BIND_ALIAS, KeyProperties.PURPOSE_SIGN).build())
        return gen.generateKey()
    }

    private fun ksMac(data: String, create: Boolean): Map<String, Any?> {
        return try {
            val key = bindKey(create) ?: return mapOf("status" to "missing")
            val mac = Mac.getInstance("HmacSHA256").apply { init(key) }.doFinal(data.toByteArray(Charsets.UTF_8))
            mapOf("status" to "ok", "mac" to hex(mac))
        } catch (e: Throwable) {
            HighLog.w("guard ksMac failed: ${e.javaClass.simpleName}")
            mapOf("status" to "error")
        }
    }

    @Suppress("DEPRECATION")
    private fun signers(): List<String> {
        val pm = activity.packageManager
        val certs = if (Build.VERSION.SDK_INT >= 28) {
            val info = pm.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            info.signingInfo?.apkContentsSigners?.toList() ?: emptyList()
        } else {
            pm.getPackageInfo(activity.packageName, PackageManager.GET_SIGNATURES).signatures?.toList() ?: emptyList()
        }
        val md = MessageDigest.getInstance("SHA-256")
        return certs.map { hex(md.digest(it.toByteArray())) }
    }

    private fun env(): Map<String, Any?> {
        val debuggable = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        return mapOf(
            "debuggable" to debuggable,
            "debugger" to (Debug.isDebuggerConnected() || Debug.waitingForDebugger()),
            "hook" to hookFramework(),
            "rooted" to rooted(),
            "emulator" to emulator(),
            "installer" to installer(),
        )
    }

    /** Frida (agent / gadget) or Xposed / LSPosed / Substrate mapped into THIS process. */
    private fun hookFramework(): Boolean {
        val words = listOf("frida", "gum-js", "gadget", "xposed", "lsposed", "substrate")
        try {
            File("/proc/self/maps").useLines { lines ->
                if (lines.any { l -> val s = l.lowercase(); words.any { s.contains(it) } }) return true
            }
        } catch (_: Throwable) {}
        try {
            File("/proc/self/task").listFiles()?.forEach { t ->
                val name = try { File(t, "comm").readText().trim().lowercase() } catch (_: Throwable) { "" }
                if (name.startsWith("gum-js") || name.contains("frida")) return true
            }
        } catch (_: Throwable) {}
        return try {
            Class.forName("de.robv.android.xposed.XposedBridge"); true
        } catch (_: Throwable) { false }
    }

    private fun rooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true
        val paths = listOf("/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/sbin/su", "/vendor/bin/su", "/data/adb/magisk", "/system/app/Superuser.apk")
        return paths.any { try { File(it).exists() } catch (_: Throwable) { false } }
    }

    private fun emulator(): Boolean {
        val f = Build.FINGERPRINT.lowercase()
        return f.startsWith("generic") || f.contains("emulator") || f.contains("sdk_gphone") ||
            Build.MODEL.contains("Emulator") || Build.MODEL.contains("Android SDK built for") ||
            Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk") || Build.MANUFACTURER.contains("Genymotion")
    }

    @Suppress("DEPRECATION")
    private fun installer(): String? = try {
        if (Build.VERSION.SDK_INT >= 30) activity.packageManager.getInstallSourceInfo(activity.packageName).installingPackageName
        else activity.packageManager.getInstallerPackageName(activity.packageName)
    } catch (_: Throwable) { null }

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
