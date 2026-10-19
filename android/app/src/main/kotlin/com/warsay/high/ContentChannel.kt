package com.warsay.high

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayInputStream
import java.util.zip.GZIPInputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Bundled study content (4 1.0.4+). Channel `com.four.student/content`, used by lib/content/content_vault.dart.
 * Reads one encrypted blob from the APK (assets/c/<name>, made by tool/encrypt_assets.py), checks + decrypts it with
 * AES-256-GCM (AAD = header + asset path, so blobs cannot be swapped), gunzips it and hands the plain bytes back.
 * Runs on a background task queue (several at once), never on the Android main thread. Nothing is written to disk.
 *
 *  - init  {s: Dart key share}   -> true when the key is complete (Dart share xor GuardChannel share B)
 *  - open  {n: blob asset, p: asset path} -> plain bytes; error "content" when the blob is missing or does not verify
 */
class ContentChannel(private val context: Context) {
    companion object {
        const val CHANNEL = "com.four.student/content"
        private val MAGIC = byteArrayOf('4'.code.toByte(), 'C'.code.toByte(), 'F'.code.toByte())
        private const val HDR = 21

        /** per process (survives an activity re-creation; the Dart side also re-sends it when told "no key") */
        @Volatile private var key: SecretKeySpec? = null
    }

    fun attach(messenger: BinaryMessenger) {
        val queue = messenger.makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions().setIsSerial(false))
        MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, queue).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "init" -> {
                        val k = GuardChannel.contentKey(call.argument<ByteArray>("s") ?: ByteArray(0))
                        if (k != null) key = SecretKeySpec(k, "AES")
                        k?.fill(0)
                        result.success(key != null)
                    }
                    "open" -> result.success(open(call.argument<String>("n")!!, call.argument<String>("p")!!))
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("content", e.javaClass.simpleName, null)
            }
        }
    }

    private fun open(name: String, path: String): ByteArray {
        val k = key ?: throw IllegalStateException("no key")
        val lookup = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(name)
        val blob = context.assets.open(lookup).use { it.readBytes() }
        if (blob.size < HDR + 16 || blob[0] != MAGIC[0] || blob[1] != MAGIC[1] || blob[2] != MAGIC[2] || blob[3].toInt() != 1) {
            throw IllegalStateException("bad blob")
        }
        val flags = blob[4].toInt()
        val n = ((blob[5].toInt() and 0xff) shl 24) or ((blob[6].toInt() and 0xff) shl 16) or
            ((blob[7].toInt() and 0xff) shl 8) or (blob[8].toInt() and 0xff)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, blob, 9, 12))
        c.updateAAD(blob, 0, 9)
        c.updateAAD(path.toByteArray(Charsets.UTF_8))
        val body = c.doFinal(blob, HDR, blob.size - HDR)
        if (flags and 1 == 0) return body
        val out = ByteArray(n)
        GZIPInputStream(ByteArrayInputStream(body), 64 * 1024).use { z ->
            var off = 0
            while (off < n) {
                val r = z.read(out, off, n - off)
                if (r < 0) break
                off += r
            }
            if (off != n) throw IllegalStateException("short blob")
        }
        return out
    }
}
