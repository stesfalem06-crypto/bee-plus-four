package com.warsay.high

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.EnumMap
import java.util.EnumSet
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Unlock scanning for the lock screen. Method channel `com.warsay.high/secure`, logcat tag HighSecure.
 *
 *  - scanUnlock            → in-app [ScanActivity] (CameraX + ML Kit QR + text recognition)
 *  - capturePhotoAndScanQr → system camera photo → ML Kit QR → ZXing → text recognition
 *  - recoverCode           → clean up a typed / pasted code (look-alike characters), HMAC-checked
 *
 * Scan results are maps: {status: ok|cancelled|error|no_code, payload, via, frames, nonBee,
 * sawCodeText, code, message}. If Android recreated this activity while the camera was open
 * (low memory), the result is kept and handed to Dart via `takePendingScan`.
 */
class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL = "com.warsay.high/secure"
        private const val MAX_DECODE_EDGE = 2400
        private const val MIN_PHOTO_BYTES = 2_048
        private const val STATE_PHOTO = "high.unlock.photo"
        private const val STATE_DEVICE = "high.unlock.device"
        /** If ScanActivity has not started this long after launch, report it and let Dart fall back. */
        private const val OPEN_WATCHDOG_MS = 9_000L
    }

    private class OnceResult(private val inner: MethodChannel.Result) : MethodChannel.Result {
        @Volatile private var done = false
        override fun success(result: Any?) {
            if (done) return
            done = true
            inner.success(result)
        }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (done) return
            done = true
            inner.error(errorCode, errorMessage, errorDetails)
        }
        override fun notImplemented() {
            if (done) return
            done = true
            inner.notImplemented()
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val bg = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    /** Crash / kill report from the previous run, read once in onCreate (before anything overwrites it). */
    private var startupReport: Map<String, Any?>? = null
    private val cameraWaiters = mutableListOf<MethodChannel.Result>()
    private var scanAfterPermission: MethodChannel.Result? = null
    private var scanPending: MethodChannel.Result? = null
    private var photoPending: MethodChannel.Result? = null
    private var photoFile: File? = null
    private var scanDeviceId: String? = null
    /** Result that arrived after the Flutter side lost its pending call (activity recreated). */
    private var orphanResult: Map<String, Any?>? = null

    /** Add-on resources: SAF folder import + FLAG_SECURE (must register before STARTED). */
    private val resources = ResourcesChannel(this)
    private val video = FourVideoChannel(this)
    private val updates = UpdateChannel(this)
    private val guard = GuardChannel(this)

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            HighLog.i("camera permission result granted=$granted")
            val waiters = cameraWaiters.toList()
            cameraWaiters.clear()
            waiters.forEach { it.success(granted) }
            val pending = scanAfterPermission
            if (pending != null) {
                scanAfterPermission = null
                if (granted) launchScanActivity(pending) else pending.success(err("permission_denied", "Camera permission denied"))
            }
        }

    private val scanLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            main.removeCallbacks(openWatchdog)
            HighLog.scanClosed(this)
            val data = res.data
            val payload = data?.getStringExtra(ScanActivity.EXTRA_PAYLOAD)
            val error = data?.getStringExtra(ScanActivity.EXTRA_ERROR)
            val out = HashMap<String, Any?>()
            out["frames"] = data?.getIntExtra(ScanActivity.EXTRA_FRAMES, 0) ?: 0
            out["sawCodeText"] = data?.getBooleanExtra(ScanActivity.EXTRA_SAW_TEXT, false) ?: false
            out["nonBee"] = data?.getStringExtra(ScanActivity.EXTRA_NON_BEE)
            when {
                res.resultCode == Activity.RESULT_OK && !payload.isNullOrBlank() -> {
                    out["status"] = "ok"
                    out["payload"] = payload
                    out["via"] = data?.getStringExtra(ScanActivity.EXTRA_VIA) ?: "qr"
                }
                error != null -> {
                    out["status"] = "error"
                    out["code"] = error
                    out["message"] = data?.getStringExtra(ScanActivity.EXTRA_MESSAGE)
                }
                else -> out["status"] = "cancelled"
            }
            HighLog.i("scan result status=${out["status"]} via=${out["via"]} frames=${out["frames"]} sawText=${out["sawCodeText"]} nonBee=${out["nonBee"]} code=${out["code"]}")
            val pending = scanPending
            scanPending = null
            deliver(pending, out)
        }

    private val takePictureLauncher =
        registerForActivityResult(ActivityResultContracts.TakePicture()) { success ->
            val pending = photoPending
            photoPending = null
            val file = photoFile
            photoFile = null
            val bytes = file?.takeIf { it.exists() }?.length() ?: -1L
            HighLog.i("TakePicture success=$success path=${file?.absolutePath} bytes=$bytes pendingLost=${pending == null}")
            if (!success || file == null) {
                file?.delete()
                deliver(pending, mapOf("status" to "cancelled"))
                return@registerForActivityResult
            }
            if (bytes in 0 until MIN_PHOTO_BYTES) {
                file.delete()
                deliver(pending, err("decode", "The camera did not save a usable photo. Try again, or use Scan unlock code."))
                return@registerForActivityResult
            }
            val device = scanDeviceId
            bg.execute {
                val out = try {
                    decodePhoto(file, device)
                } catch (e: Throwable) {
                    HighLog.e("decodePhoto crashed", e)
                    err("decode", "Could not read the photo: ${e.message ?: e.javaClass.simpleName}")
                } finally {
                    file.delete()
                }
                main.post { deliver(pending, out) }
            }
        }

    /** Fires when scanLauncher.launch() returned but ScanActivity never started (nothing on screen). */
    private val openWatchdog = Runnable {
        val pending = scanPending ?: return@Runnable
        if (ScanActivity.createdAt >= scanLaunchedAt) return@Runnable
        HighLog.e("ScanActivity did not open within ${OPEN_WATCHDOG_MS}ms")
        scanPending = null
        HighLog.scanClosed(this)
        pending.success(err("not_opened", "The scanner screen did not open."))
    }
    private var scanLaunchedAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        HighLog.installCrashCapture(this)
        super.onCreate(savedInstanceState)
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (savedInstanceState == null) {
            startupReport = HighLog.takeStartupReport(this)
            startupReport?.let { HighLog.w("previous run ended abnormally: ${it["code"]} ${it["message"]}") }
        }
        savedInstanceState?.getString(STATE_PHOTO)?.let { photoFile = File(it) }
        scanDeviceId = savedInstanceState?.getString(STATE_DEVICE)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        photoFile?.let { outState.putString(STATE_PHOTO, it.absolutePath) }
        scanDeviceId?.let { outState.putString(STATE_DEVICE, it) }
    }

    override fun onResume() {
        super.onResume()
        if (ResourcesChannel.secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        resources.attach(flutterEngine.dartExecutor.binaryMessenger)
        video.attach(flutterEngine)
        updates.attach(flutterEngine.dartExecutor.binaryMessenger)
        guard.attach(flutterEngine.dartExecutor.binaryMessenger)
        ch.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Throwable) {
                HighLog.e("channel ${call.method} failed", e)
                try { result.error("native", "${call.method}: ${e.javaClass.simpleName}: ${e.message}", null) } catch (_: Throwable) {}
            }
        }
        HighLog.i("MethodChannel $CHANNEL ready (in-app CameraX scanner + photo + text recovery)")
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "set" -> runOnUiThread {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                result.success(null)
            }
            "requestCamera" -> requestCamera(result)
            "hasCamera" -> result.success(hasCameraPermission())
            "shouldShowCameraRationale" -> result.success(
                ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.CAMERA),
            )
            "openAppSettings" -> runOnUiThread {
                try {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    intent.data = Uri.fromParts("package", packageName, null)
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    HighLog.e("openAppSettings failed", e)
                    result.error("settings", e.message, null)
                }
            }
            "scanUnlock", "captureAndScanQr", "scanQr" -> scanUnlock(argDevice(call.arguments), result)
            "capturePhotoAndScanQr" -> capturePhoto(argDevice(call.arguments), result)
            "recoverCode" -> {
                val args = call.arguments as? Map<*, *>
                val text = args?.get("text") as? String ?: ""
                val device = args?.get("deviceId") as? String
                bg.execute {
                    val hit = try { UnlockCodeRecovery.recover(text, device) } catch (e: Throwable) { null }
                    HighLog.i("recoverCode len=${text.length} hit=${hit?.layout}")
                    main.post { result.success(hit?.payload) }
                }
            }
            "takePendingScan" -> {
                val r = orphanResult
                orphanResult = null
                result.success(r)
            }
            "log" -> {
                HighLog.i("dart: " + (call.arguments?.toString() ?: ""))
                result.success(null)
            }
            "getLog" -> result.success(HighLog.snapshot())
            "cancelScan" -> {
                // Dart's watchdog: the scanner never came on screen. Release the pending call.
                main.removeCallbacks(openWatchdog)
                val pending = scanPending
                scanPending = null
                HighLog.scanClosed(this)
                HighLog.w("cancelScan pending=${pending != null}")
                pending?.success(err("not_opened", "The scanner screen did not open."))
                result.success(pending != null)
            }
            "takeStartupReport" -> result.success(startupReport.also { startupReport = null })
            else -> result.notImplemented()
        }
    }

    private fun argDevice(args: Any?): String? = when (args) {
        is Map<*, *> -> args["deviceId"] as? String
        is String -> args
        else -> null
    }

    private fun err(code: String, message: String): Map<String, Any?> =
        mapOf("status" to "error", "code" to code, "message" to message)

    /** Send to the waiting Dart call, or keep it for `takePendingScan` / push it if the call was lost. */
    private fun deliver(pending: MethodChannel.Result?, out: Map<String, Any?>) {
        if (pending != null) {
            pending.success(out)
            return
        }
        if (out["status"] == "ok") {
            HighLog.w("scan result arrived after activity recreation — handing to Dart as orphan")
            orphanResult = out
            try { channel?.invokeMethod("orphanScanResult", out) } catch (_: Exception) {}
        }
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestCamera(result: MethodChannel.Result) {
        runOnUiThread {
            if (hasCameraPermission()) {
                result.success(true)
                return@runOnUiThread
            }
            val once = OnceResult(result)
            cameraWaiters.add(once)
            try {
                cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
            } catch (e: Throwable) {
                HighLog.e("requestCamera launch failed", e)
                cameraWaiters.remove(once)
                once.success(false)
            }
        }
    }

    private fun busy(): Boolean = scanPending != null || photoPending != null || scanAfterPermission != null

    private fun scanUnlock(deviceId: String?, result: MethodChannel.Result) {
        runOnUiThread {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            if (busy()) {
                result.success(err("busy", "The camera is already opening. Wait a moment and try again."))
                return@runOnUiThread
            }
            scanDeviceId = deviceId
            val once = OnceResult(result)
            if (!hasCameraPermission()) {
                scanAfterPermission = once
                try {
                    cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                } catch (e: Throwable) {
                    HighLog.e("permission request failed", e)
                    scanAfterPermission = null
                    once.success(err("permission_request", e.message ?: "Camera permission request failed"))
                }
                return@runOnUiThread
            }
            launchScanActivity(once)
        }
    }

    private fun launchScanActivity(result: MethodChannel.Result) {
        try {
            scanPending = result
            val intent = Intent(this, ScanActivity::class.java)
                .putExtra(ScanActivity.EXTRA_DEVICE_ID, scanDeviceId)
            HighLog.i("launching in-app ScanActivity")
            scanLaunchedAt = android.os.SystemClock.elapsedRealtime()
            HighLog.scanOpening(this)
            scanLauncher.launch(intent)
            main.removeCallbacks(openWatchdog)
            main.postDelayed(openWatchdog, OPEN_WATCHDOG_MS)
        } catch (e: Throwable) {
            HighLog.e("launch ScanActivity failed", e)
            scanPending = null
            HighLog.scanClosed(this)
            result.success(err("launch", "Scanner could not open: ${e.message ?: e.javaClass.simpleName}"))
        }
    }

    private fun capturePhoto(deviceId: String?, result: MethodChannel.Result) {
        runOnUiThread {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            if (busy()) {
                result.success(err("busy", "The camera is already opening. Wait a moment and try again."))
                return@runOnUiThread
            }
            if (!hasCameraPermission()) {
                result.success(err("permission_denied", "Camera permission required"))
                return@runOnUiThread
            }
            scanDeviceId = deviceId
            try {
                val file = File(cacheDir, "unlock_photo_${System.currentTimeMillis()}.jpg")
                file.parentFile?.mkdirs()
                file.createNewFile()
                val uri = FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileprovider", file)
                if (Intent(MediaStore.ACTION_IMAGE_CAPTURE).resolveActivity(packageManager) == null) {
                    file.delete()
                    result.success(err("no_camera_app", "No camera app found on this phone. Use Scan unlock code instead."))
                    return@runOnUiThread
                }
                photoFile = file
                photoPending = OnceResult(result)
                HighLog.i("launching system camera uri=$uri")
                takePictureLauncher.launch(uri)
            } catch (e: Throwable) {
                HighLog.e("launch system camera failed", e)
                photoPending = null
                photoFile?.delete()
                photoFile = null
                result.success(err("camera", e.message ?: "Could not open the camera app"))
            }
        }
    }

    // ── Still-photo decode (background thread) ───────────────────────────────

    private fun decodePhoto(file: File, deviceId: String?): Map<String, Any?> {
        val base = loadBitmap(file, MAX_DECODE_EDGE)
            ?: return err("decode", "Could not read the photo from the camera.")
        HighLog.i("decodePhoto bitmap ${base.width}x${base.height}")
        var nonBee: String? = null
        // If ML Kit cannot start, still try ZXing and text below instead of failing the whole photo.
        val barcode = try {
            BarcodeScanning.getClient(
                BarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE, Barcode.FORMAT_AZTEC, Barcode.FORMAT_DATA_MATRIX, Barcode.FORMAT_PDF417)
                    .build(),
            )
        } catch (e: Throwable) {
            HighLog.e("photo ML Kit barcode client failed", e)
            null
        }
        if (barcode != null) try {
            for (angle in intArrayOf(0, 90, 180, 270)) {
                val bmp = rotate(base, angle)
                val values = try {
                    Tasks.await(barcode.process(InputImage.fromBitmap(bmp, 0)), 15, TimeUnit.SECONDS)
                        .mapNotNull { it.rawValue?.trim()?.takeIf { v -> v.isNotEmpty() } }
                } catch (e: Exception) {
                    HighLog.w("photo ML Kit rot=$angle failed: ${e.message}")
                    emptyList()
                }
                if (bmp !== base) bmp.recycle()
                val hit = pick(values, deviceId)
                if (hit != null) return ok(hit, "photo-qr")
                if (values.isNotEmpty()) nonBee = values.first()
            }
        } finally {
            try { barcode.close() } catch (_: Exception) {}
        }
        for (angle in intArrayOf(0, 90, 180, 270)) {
            val bmp = rotate(base, angle)
            val v = zxing(bmp)
            if (bmp !== base) bmp.recycle()
            if (v != null) {
                val hit = pick(listOf(v), deviceId)
                if (hit != null) return ok(hit, "photo-zxing")
                nonBee = v
            }
        }
        // The Compose Bee Seller shows the code as text — read it.
        var sawText = false
        val recognizer = if (OcrSupport.available) {
            try {
                TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            } catch (e: Throwable) {
                HighLog.e("text recognizer unavailable", e)
                null
            }
        } else {
            null
        }
        if (recognizer != null) try {
            for (angle in intArrayOf(0, 90, 270, 180)) {
                val bmp = rotate(base, angle)
                val text = try {
                    Tasks.await(recognizer.process(InputImage.fromBitmap(bmp, 0)), 20, TimeUnit.SECONDS).text
                } catch (e: Exception) {
                    HighLog.w("photo text rot=$angle failed: ${e.message}")
                    ""
                }
                if (bmp !== base) bmp.recycle()
                if (UnlockCodeRecovery.looksLikeCode(text)) {
                    sawText = true
                    val rec = UnlockCodeRecovery.recover(text, deviceId)
                    if (rec != null) return ok(rec.payload, "photo-text")
                }
            }
        } finally {
            try { recognizer.close() } catch (_: Exception) {}
        }
        HighLog.w("decodePhoto: nothing usable sawText=$sawText nonBee=${nonBee?.take(16)}")
        return mapOf(
            "status" to "no_code",
            "sawCodeText" to sawText,
            "nonBee" to nonBee?.let { if (it.length > 20) it.take(20) + "…" else it },
        )
    }

    private fun ok(payload: String, via: String): Map<String, Any?> {
        HighLog.i("photo decode OK via=$via len=${payload.length}")
        return mapOf("status" to "ok", "payload" to payload, "via" to via)
    }

    /** Prefer a BEE1 value; else a value that cleans up into a valid code. */
    private fun pick(values: List<String>, deviceId: String?): String? {
        values.firstOrNull { it.contains("BEE1", ignoreCase = true) }?.let { return it }
        for (v in values) UnlockCodeRecovery.recover(v, deviceId)?.let { return it.payload }
        return null
    }

    private fun zxing(bitmap: Bitmap): String? {
        for (invert in booleanArrayOf(false, true)) {
            try {
                val w = bitmap.width
                val h = bitmap.height
                val px = IntArray(w * h)
                bitmap.getPixels(px, 0, w, 0, 0, w, h)
                if (invert) for (i in px.indices) px[i] = px[i] xor 0x00ffffff
                val hints = EnumMap<DecodeHintType, Any>(DecodeHintType::class.java)
                hints[DecodeHintType.TRY_HARDER] = true
                hints[DecodeHintType.POSSIBLE_FORMATS] = EnumSet.of(BarcodeFormat.QR_CODE)
                val reader = MultiFormatReader().apply { setHints(hints) }
                val text = reader.decodeWithState(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(w, h, px)))).text
                if (!text.isNullOrBlank()) return text.trim()
            } catch (_: Exception) {
            } catch (_: OutOfMemoryError) {
                return null
            }
        }
        return null
    }

    private fun rotate(src: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return src
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    private fun loadBitmap(file: File, maxEdge: Int): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / sample > maxEdge || bounds.outHeight / sample > maxEdge) sample *= 2
            val bmp = BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            ) ?: return null
            val rotation = try {
                when (ExifInterface(file.absolutePath).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270
                    else -> 0
                }
            } catch (_: Exception) {
                0
            }
            if (rotation == 0) bmp else rotate(bmp, rotation).also { if (it !== bmp) bmp.recycle() }
        } catch (e: Throwable) {
            HighLog.e("loadBitmap failed", e)
            null
        }
    }

    override fun onDestroy() {
        main.removeCallbacks(openWatchdog)
        bg.shutdown()
        video.disposeAll()
        super.onDestroy()
    }
}
