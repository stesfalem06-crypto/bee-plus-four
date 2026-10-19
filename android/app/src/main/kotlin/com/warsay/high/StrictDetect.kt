package com.warsay.high

import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Pure, unit-testable environment checks for 4 STRICT mode (1.0.5).
 *
 * All I/O goes through [Fs] / [Apps] / [BuildBits] so JVM tests can inject fakes.
 * Never throws: a failed probe is treated as "not found".
 */
object StrictDetect {
    /** XOR key for the packed package / label lists (not a secret — just keeps plain names out of strings). */
    private val XOR = byteArrayOf(
        0x4F, 0x75, 0x72, 0x53, 0x74, 0x72, 0x69, 0x63,
        0x74, 0x47, 0x31, 0x30, 0x35, 0x21, 0xA5.toByte(), 0x3C,
    )

    // Null-separated XOR'd package names (Base64). See tool notes in docs/anti_clone.md.
    private const val PKG_B64 =
        "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"

    private const val LBL_B64 =
        "DSMAETgNUhkCACRZVUcMIwAROA0CCBcXL1RCCiIBUj4VHAgEETUKIQVSPhUcCAQRNQouBRlzERYAFxs1CS4FGScbHQVDGQwoFB82EwcIERAuUF4NKBQfNlQVHAIGI1hRWwk8HR0kVBgIFRUKLgUCcxceBg0RNQ4/FAAyGB4MD1Q0QVFWRAgnFAIjDR8GBwknFAIjDVIEDBAGIhQVOgcZCCQQAD0RHhoWByMGAjwHFw0IKhEKIxsBDAc="

    /** Filesystem probes. */
    interface Fs {
        fun exists(path: String): Boolean
        fun readText(path: String, max: Int = 256_000): String?
        fun listNames(path: String): List<String>
        /** Try a quick TCP connect; return true if something answered. */
        fun portOpen(host: String, port: Int, timeoutMs: Int = 40): Boolean
    }

    /** Installed apps (package name + label). Only packages visible via <queries>. */
    fun interface Apps {
        fun installed(): List<Pair<String, String>>
    }

    data class BuildBits(
        val tags: String? = null,
        val fingerprint: String = "",
        val model: String = "",
        val hardware: String = "",
        val product: String = "",
        val manufacturer: String = "",
        val brand: String = "",
        val device: String = "",
        val board: String = "",
        val dataDir: String = "",
        val debuggableFlag: Boolean = false,
        val debuggerAttached: Boolean = false,
        /** System properties: ro.debuggable, ro.secure, … */
        val props: Map<String, String> = emptyMap(),
    )

    data class Hit(val kind: String, val detail: String)

    data class Report(
        val rooted: Boolean,
        val hook: Boolean,
        val emulator: Boolean,
        val virtual: Boolean,
        val debuggable: Boolean,
        val debugger: Boolean,
        val riskyApps: List<Pair<String, String>>,
        val reasons: List<String>,
    ) {
        /** STRICT: any of these means the app must not open. */
        val blocked: Boolean
            get() = rooted || hook || emulator || virtual || debuggable || debugger || riskyApps.isNotEmpty()
    }

    fun decodeList(b64: String): List<String> {
        // Length-prefixed XOR chunks (a null separator would collide with XOR output).
        val raw = java.util.Base64.getDecoder().decode(b64)
        val out = ArrayList<String>()
        var i = 0
        while (i < raw.size) {
            val n = raw[i].toInt() and 0xff
            i++
            if (n == 0 || i + n > raw.size) break
            val chunk = ByteArray(n)
            for (k in 0 until n) chunk[k] = (raw[i + k].toInt() xor XOR[k % XOR.size].toInt()).toByte()
            out.add(String(chunk, Charsets.UTF_8))
            i += n
        }
        return out
    }

    fun knownPackages(): List<String> = decodeList(PKG_B64)
    fun knownLabels(): List<String> = decodeList(LBL_B64)

    fun scan(fs: Fs, apps: Apps, build: BuildBits): Report {
        val reasons = ArrayList<String>()
        val rootHits = root(fs, apps, build, reasons)
        val hookHits = hook(fs, build, reasons)
        val emu = emulator(build, reasons)
        val virt = virtualContainer(build, reasons)
        val risky = riskyApps(apps, reasons)
        if (build.debuggableFlag) reasons.add("debuggable")
        if (build.debuggerAttached) reasons.add("debugger")
        return Report(
            rooted = rootHits,
            hook = hookHits,
            emulator = emu,
            virtual = virt,
            debuggable = build.debuggableFlag,
            debugger = build.debuggerAttached,
            riskyApps = risky,
            reasons = reasons,
        )
    }

    // ── root ─────────────────────────────────────────────────────────────────

    private val SU_PATHS = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/sbin/su",
        "/vendor/bin/su", "/su/bin/su", "/data/local/su", "/data/local/bin/su",
        "/data/local/xbin/su", "/system/app/Superuser.apk",
        "/data/adb/magisk", "/sbin/.magisk", "/data/adb/ksu", "/data/adb/apatch",
        "/data/adb/modules",
    )

    private val ROOT_PKGS_PREFIX = listOf(
        "com.topjohnwu.magisk", "io.github.vvb2060.magisk", "io.github.huskydg.magisk",
        "me.weishu.kernelsu", "me.bmax.apatch", "com.rifsxd.ksunext",
        "eu.chainfire.supersu", "com.noshufou.android.su", "com.koushikdutta.superuser",
        "com.thirdparty.superuser", "com.yellowes.su", "com.kingroot.kinguser",
        "com.kingo.root", "com.alephzain.framaroot",
    )

    fun root(fs: Fs, apps: Apps, build: BuildBits, reasons: MutableList<String>): Boolean {
        var hit = false
        if (build.tags?.contains("test-keys") == true) {
            reasons.add("root:test-keys"); hit = true
        }
        for (p in SU_PATHS) {
            if (fs.exists(p)) {
                reasons.add("root:path:$p"); hit = true; break
            }
        }
        // Magisk mount / stub
        val mounts = fs.readText("/proc/self/mounts") ?: ""
        if (mounts.contains("magisk") || mounts.contains("/sbin/.magisk")) {
            reasons.add("root:magisk-mount"); hit = true
        }
        if (fs.exists("/sbin/.magisk") || fs.exists("/data/adb/magisk")) {
            reasons.add("root:magisk"); hit = true
        }
        if (fs.exists("/data/adb/ksu") || fs.exists("/data/adb/ksud")) {
            reasons.add("root:kernelsu"); hit = true
        }
        if (fs.exists("/data/adb/apatch")) {
            reasons.add("root:apatch"); hit = true
        }
        // Props: do NOT flag merely "ADB enabled" / developer options — only insecure build props.
        val roDeb = build.props["ro.debuggable"]
        val roSec = build.props["ro.secure"]
        if (roDeb == "1") { reasons.add("root:ro.debuggable"); hit = true }
        if (roSec == "0") { reasons.add("root:ro.secure"); hit = true }
        // Writable /system (rw mount)
        for (line in mounts.lineSequence()) {
            val parts = line.split(Regex("\\s+"))
            if (parts.size >= 4 && (parts[1] == "/system" || parts[1] == "/")) {
                if (parts[3].split(',').any { it == "rw" } && parts[1] == "/system") {
                    reasons.add("root:system-rw"); hit = true; break
                }
            }
        }
        // Known root-manager packages
        val installed = apps.installed().map { it.first }.toHashSet()
        for (p in ROOT_PKGS_PREFIX) {
            if (installed.contains(p)) {
                reasons.add("root:pkg:$p"); hit = true
            }
        }
        // Magisk hidden-name stub: package whose label is exactly "Manager" / "Magisk" and
        // which coexists with magisk paths — already covered by path checks; also catch label.
        for ((pkg, label) in apps.installed()) {
            val l = label.lowercase()
            if (l == "magisk" || l == "kernelsu" || l == "apatch") {
                reasons.add("root:label:$pkg"); hit = true
            }
        }
        return hit
    }

    // ── hooking ──────────────────────────────────────────────────────────────

    private val MAP_WORDS = listOf(
        "frida", "gum-js", "frida-agent", "frida-gadget", "libfrida",
        "xposed", "lsposed", "edxposed", "substrate", "libsubstrate",
    )
    private val THREAD_WORDS = listOf("gum-js", "gmain", "gdbus", "frida", "pool-frida")

    fun hook(fs: Fs, build: BuildBits, reasons: MutableList<String>): Boolean {
        var hit = false
        val maps = fs.readText("/proc/self/maps")?.lowercase() ?: ""
        for (w in MAP_WORDS) {
            if (maps.contains(w)) {
                reasons.add("hook:maps:$w"); hit = true; break
            }
        }
        // Threads
        for (name in fs.listNames("/proc/self/task")) {
            val comm = (fs.readText("/proc/self/task/$name/comm") ?: "").trim().lowercase()
            if (THREAD_WORDS.any { comm.contains(it) || comm.startsWith(it) }) {
                reasons.add("hook:thread:$comm"); hit = true; break
            }
        }
        // Frida default port
        if (fs.portOpen("127.0.0.1", 27042) || fs.portOpen("127.0.0.1", 27043)) {
            reasons.add("hook:frida-port"); hit = true
        }
        // frida-server binary name in maps already covered; also check common paths
        for (p in listOf("/data/local/tmp/frida-server", "/data/local/tmp/re.frida.server")) {
            if (fs.exists(p)) { reasons.add("hook:frida-bin"); hit = true; break }
        }
        // Xposed class (best-effort; Class.forName is done by caller via BuildBits props flag)
        if (build.props["four.xposed"] == "1") {
            reasons.add("hook:xposed-class"); hit = true
        }
        return hit
    }

    // ── emulator ─────────────────────────────────────────────────────────────

    fun emulator(build: BuildBits, reasons: MutableList<String>): Boolean {
        val f = build.fingerprint.lowercase()
        val hit = f.startsWith("generic") || f.contains("emulator") || f.contains("sdk_gphone") ||
            f.contains("unknown") && build.model.contains("sdk", ignoreCase = true) ||
            build.model.contains("Emulator") || build.model.contains("Android SDK built for") ||
            build.hardware.contains("goldfish") || build.hardware.contains("ranchu") ||
            build.hardware.contains("vbox86") ||
            build.product.contains("sdk") || build.product.contains("emulator") ||
            build.product.contains("google_sdk") || build.product.contains("sdk_gphone") ||
            build.manufacturer.contains("Genymotion", ignoreCase = true) ||
            build.brand.startsWith("generic") && build.device.startsWith("generic") ||
            build.board.contains("nox", ignoreCase = true) ||
            build.product.contains("nox", ignoreCase = true)
        if (hit) reasons.add("emulator")
        return hit
    }

    // ── virtual container ────────────────────────────────────────────────────

    private val VIRT_MARKERS = listOf(
        "/parallel", "/virtual", "/plugin", "/virt/",
        "com.lbe.parallel", "com.excelliance", "com.vphone",
        "com.wx.multy", "multiaccount", "com.cloneapp",
        "/BlackBox", "/VirtualXposed", "/va/",
    )

    fun virtualContainer(build: BuildBits, reasons: MutableList<String>): Boolean {
        val d = build.dataDir
        if (d.isEmpty()) return false
        // Normal: /data/user/0/com.four.student or /data/data/com.four.student
        val normal = d.startsWith("/data/user/") || d.startsWith("/data/data/com.four.student")
        if (normal && VIRT_MARKERS.none { d.contains(it, ignoreCase = true) }) return false
        for (m in VIRT_MARKERS) {
            if (d.contains(m, ignoreCase = true)) {
                reasons.add("virtual:$m"); return true
            }
        }
        // Data dir that nests another package host before ours
        if (!d.contains("/com.four.student") && d.contains("four")) {
            // still ok
        }
        if (!normal) {
            reasons.add("virtual:datadir"); return true
        }
        return false
    }

    // ── risky tooling apps ───────────────────────────────────────────────────

    fun riskyApps(apps: Apps, reasons: MutableList<String>): List<Pair<String, String>> {
        val known = knownPackages().toHashSet()
        val labels = knownLabels()
        val found = ArrayList<Pair<String, String>>()
        // Packages that are root managers are also "rooted"; still list them as risky for uninstall UX.
        for ((pkg, label) in apps.installed()) {
            var match = known.contains(pkg)
            if (!match) {
                val ll = label.lowercase()
                match = labels.any { ll == it || ll.contains(it) }
            }
            // Magisk random stub: short random-looking package + label Manager, with no normal vendor prefix
            if (!match) {
                val ll = label.lowercase().trim()
                if ((ll == "manager" || ll == "settings") && pkg.count { it == '.' } >= 2 &&
                    !pkg.startsWith("com.android.") && !pkg.startsWith("com.samsung.") &&
                    !pkg.startsWith("com.google.") && !pkg.startsWith("com.miui.") &&
                    !pkg.startsWith("com.tecno.") && !pkg.startsWith("com.infinix.") &&
                    !pkg.startsWith("com.transsion.") && !pkg.startsWith("com.xiaomi.") &&
                    pkg.length in 12..40
                ) {
                    // Too aggressive alone — only when magisk path evidence exists the caller already
                    // flags root. Skip stub-by-label-alone to avoid OEM false positives.
                }
            }
            if (match) {
                found.add(pkg to label)
                reasons.add("app:$pkg")
            }
        }
        return found
    }

    /** Real filesystem for the phone. */
    class RealFs : Fs {
        override fun exists(path: String): Boolean = try { File(path).exists() } catch (_: Throwable) { false }
        override fun readText(path: String, max: Int): String? = try {
            File(path).bufferedReader().use { it.readText().take(max) }
        } catch (_: Throwable) { null }
        override fun listNames(path: String): List<String> = try {
            File(path).list()?.toList() ?: emptyList()
        } catch (_: Throwable) { emptyList() }
        override fun portOpen(host: String, port: Int, timeoutMs: Int): Boolean = try {
            Socket().use { s ->
                s.connect(InetSocketAddress(host, port), timeoutMs)
                true
            }
        } catch (_: Throwable) { false }
    }
}
