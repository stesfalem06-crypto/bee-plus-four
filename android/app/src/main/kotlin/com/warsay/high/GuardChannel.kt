package com.warsay.high

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
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
 *  - env     STRICT environment scan (root, hook, emulator, virtual container, risky apps)
 *  - uninstall  open system uninstall dialog for a package (default: ourselves)
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

        // Share B of the bundled-content key (4 1.0.4+, see tool/encrypt_assets.py). Key = A xor B xor C: A is in
        // lib/licensing/secrets.dart, C is compiled into the Dart code from a gitignored file at build time.
        private val CONTENT_B = byteArrayOf(-42, -61, -5, 66, 11, -56, 19, -23, 55, 59, -100, 69, 15, -119, -24, 104, 105, -14, 62, -2, -22, 111, -72, -23, 29, -19, 15, -109, 19, -121, -44, -5)

        /** Content key from the Dart share (A xor C) and this side's share B. */
        internal fun contentKey(dartShare: ByteArray): ByteArray? {
            if (dartShare.size != CONTENT_B.size) return null
            return ByteArray(CONTENT_B.size) { (dartShare[it].toInt() xor CONTENT_B[it].toInt()).toByte() }
        }
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
                        "uninstall" -> uninstall(call.argument<String>("pkg"))
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
        val debugger = Debug.isDebuggerConnected() || Debug.waitingForDebugger()
        val props = HashMap<String, String>()
        prop("ro.debuggable")?.let { props["ro.debuggable"] = it }
        prop("ro.secure")?.let { props["ro.secure"] = it }
        // Xposed class present?
        try {
            Class.forName("de.robv.android.xposed.XposedBridge")
            props["four.xposed"] = "1"
        } catch (_: Throwable) {}
        try {
            Class.forName("com.android.internal.os.XposedBridge")
            props["four.xposed"] = "1"
        } catch (_: Throwable) {}

        val build = StrictDetect.BuildBits(
            tags = Build.TAGS,
            fingerprint = Build.FINGERPRINT ?: "",
            model = Build.MODEL ?: "",
            hardware = Build.HARDWARE ?: "",
            product = Build.PRODUCT ?: "",
            manufacturer = Build.MANUFACTURER ?: "",
            brand = Build.BRAND ?: "",
            device = Build.DEVICE ?: "",
            board = Build.BOARD ?: "",
            dataDir = activity.applicationInfo.dataDir ?: "",
            debuggableFlag = debuggable,
            debuggerAttached = debugger,
            props = props,
        )
        val apps = StrictDetect.Apps {
            val pm = activity.packageManager
            val out = ArrayList<Pair<String, String>>()
            for (pkg in StrictDetect.knownPackages()) {
                try {
                    val ai = pm.getApplicationInfo(pkg, 0)
                    val label = try { pm.getApplicationLabel(ai).toString() } catch (_: Throwable) { pkg }
                    out.add(pkg to label)
                } catch (_: Throwable) {}
            }
            // Also scan launched apps' labels for Lucky Patcher randomised packages (limited set via <queries>)
            // PackageManager.getInstalledApplications without QUERY_ALL_PACKAGES only returns launcher + queried.
            try {
                @Suppress("DEPRECATION")
                val list = pm.getInstalledApplications(0)
                val known = StrictDetect.knownPackages().toHashSet()
                for (ai in list) {
                    if (ai.packageName in known) continue
                    val label = try { pm.getApplicationLabel(ai).toString() } catch (_: Throwable) { continue }
                    out.add(ai.packageName to label)
                }
            } catch (_: Throwable) {}
            out
        }
        val r = StrictDetect.scan(StrictDetect.RealFs(), apps, build)
        return mapOf(
            "debuggable" to r.debuggable,
            "debugger" to r.debugger,
            "hook" to r.hook,
            "rooted" to r.rooted,
            "emulator" to r.emulator,
            "virtual" to r.virtual,
            "blocked" to r.blocked,
            "installer" to installer(),
            "reasons" to r.reasons,
            "riskyApps" to r.riskyApps.map { mapOf("pkg" to it.first, "label" to it.second) },
        )
    }

    private fun prop(name: String): String? = try {
        val cl = Class.forName("android.os.SystemProperties")
        cl.getMethod("get", String::class.java).invoke(null, name) as? String
    } catch (_: Throwable) { null }

    /** Open the system "uninstall this app?" dialog. Returns true if the activity was started. */
    private fun uninstall(pkg: String?): Boolean {
        val target = pkg?.takeIf { it.isNotBlank() } ?: activity.packageName
        return try {
            val i = Intent(Intent.ACTION_DELETE, Uri.parse("package:$target"))
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(i)
            true
        } catch (e: Throwable) {
            HighLog.w("guard uninstall failed: ${e.javaClass.simpleName}")
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun installer(): String? = try {
        if (Build.VERSION.SDK_INT >= 30) activity.packageManager.getInstallSourceInfo(activity.packageName).installingPackageName
        else activity.packageManager.getInstallerPackageName(activity.packageName)
    } catch (_: Throwable) { null }

    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
}
