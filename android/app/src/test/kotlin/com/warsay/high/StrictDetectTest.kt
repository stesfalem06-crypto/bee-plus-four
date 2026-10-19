package com.warsay.high

import org.junit.Assert.*
import org.junit.Test

/** JVM unit tests for STRICT detection rules (fakes only — no Android runtime). */
class StrictDetectTest {

    private class MemFs(
        private val files: MutableMap<String, String> = HashMap(),
        private val dirs: MutableMap<String, List<String>> = HashMap(),
        private val ports: MutableSet<Int> = HashSet(),
    ) : StrictDetect.Fs {
        fun put(path: String, content: String = "") { files[path] = content }
        fun putDir(path: String, names: List<String>) { dirs[path] = names }
        fun openPort(port: Int) { ports.add(port) }
        override fun exists(path: String) = files.containsKey(path) || dirs.containsKey(path)
        override fun readText(path: String, max: Int) = files[path]?.take(max)
        override fun listNames(path: String) = dirs[path] ?: emptyList()
        override fun portOpen(host: String, port: Int, timeoutMs: Int) = ports.contains(port)
    }

    private class MemApps(private val list: List<Pair<String, String>>) : StrictDetect.Apps {
        override fun installed() = list
    }

    private fun cleanBuild(dataDir: String = "/data/user/0/com.four.student") = StrictDetect.BuildBits(
        tags = "release-keys",
        fingerprint = "samsung/a14/a14:14/UP1A/A145FXX:user/release-keys",
        model = "SM-A145F",
        hardware = "exynos850",
        product = "a14xxx",
        manufacturer = "samsung",
        brand = "samsung",
        device = "a14",
        board = "exynos850",
        dataDir = dataDir,
    )

    @Test
    fun decodePackageList_containsMagiskAndMtManager() {
        val pkgs = StrictDetect.knownPackages()
        assertTrue(pkgs.contains("com.topjohnwu.magisk"))
        assertTrue(pkgs.contains("bin.mt.plus"))
        assertTrue(pkgs.contains("com.gmail.heagoo.apkeditor"))
        assertTrue(pkgs.contains("com.chelpus.lackypatch"))
        assertTrue(pkgs.size >= 60)
    }

    @Test
    fun cleanSamsungPhone_notBlocked() {
        val r = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild())
        assertFalse(r.blocked)
        assertFalse(r.rooted)
        assertFalse(r.hook)
        assertFalse(r.emulator)
        assertTrue(r.riskyApps.isEmpty())
    }

    @Test
    fun suBinary_flagsRoot() {
        val fs = MemFs().also { it.put("/system/xbin/su") }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.rooted)
        assertTrue(r.blocked)
        assertTrue(r.reasons.any { it.startsWith("root:path") })
    }

    @Test
    fun magiskMount_flagsRoot() {
        val fs = MemFs().also {
            it.put("/proc/self/mounts", "/dev/block/magisk /sbin/.magisk/mirror/system ext4 ro 0 0\n")
        }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.rooted)
        assertTrue(r.reasons.any { it.contains("magisk") })
    }

    @Test
    fun testKeys_aloneIsNotRoot_1_0_6() {
        // stock budget ROMs (Tecno / Itel / MTK) ship test-keys: must not block a normal phone
        val r = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild().copy(tags = "test-keys"))
        assertFalse(r.rooted)
        assertFalse(r.blocked)
    }

    @Test
    fun insecureProps_aloneAreNotRoot_butCountWithSu() {
        val props = mapOf("ro.debuggable" to "1", "ro.secure" to "0")
        val alone = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild().copy(props = props))
        assertFalse(alone.rooted)
        val fs = MemFs().also { it.put("/system/xbin/su") }
        val withSu = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild().copy(props = props))
        assertTrue(withSu.rooted)
        assertTrue(withSu.reasons.contains("root:insecure-build"))
        val clean = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild())
        assertFalse(clean.rooted)
    }

    @Test
    fun glibThreadNames_areNotFrida() {
        val fs = MemFs().also {
            it.putDir("/proc/self/task", listOf("1", "2"))
            it.put("/proc/self/task/2/comm", "gmain")
        }
        assertFalse(StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild()).hook)
    }

    @Test
    fun genericNoNameRom_singleWeakSignal_isNotEmulator() {
        val r = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild().copy(fingerprint = "generic/x6/x6:11/RP1A/1:user/release-keys"))
        assertFalse(r.emulator)
    }

    @Test
    fun adoptableStorage_isNotVirtualContainer() {
        val r = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild(dataDir = "/mnt/expand/1234-abcd/user/0/com.four.student"))
        assertFalse(r.virtual)
        assertFalse(r.blocked)
    }

    @Test
    fun fridaMaps_flagsHook() {
        val fs = MemFs().also {
            it.put("/proc/self/maps", "7a000000-7a100000 r-xp 00000000 00:00 0 /data/local/tmp/frida-agent-64.so\n")
        }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.hook)
        assertTrue(r.blocked)
    }

    @Test
    fun fridaPort_flagsHook() {
        val fs = MemFs().also { it.openPort(27042) }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.hook)
        assertTrue(r.reasons.contains("hook:frida-port"))
    }

    @Test
    fun gumJsThread_flagsHook() {
        val fs = MemFs().also {
            it.putDir("/proc/self/task", listOf("1", "2"))
            it.put("/proc/self/task/2/comm", "gum-js-loop")
        }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.hook)
    }

    @Test
    fun emulatorFingerprint_flagsEmulator() {
        val r = StrictDetect.scan(
            MemFs(), MemApps(emptyList()),
            cleanBuild().copy(fingerprint = "google/sdk_gphone64_arm64/emu64a:14/UE1A/123:user/dev-keys", hardware = "ranchu", product = "sdk_gphone64_arm64"),
        )
        assertTrue(r.emulator)
        assertTrue(r.blocked)
    }

    @Test
    fun mtManager_listedAsRisky() {
        val apps = MemApps(listOf("bin.mt.plus" to "MT Manager"))
        val r = StrictDetect.scan(MemFs(), apps, cleanBuild())
        assertEquals(1, r.riskyApps.size)
        assertEquals("bin.mt.plus", r.riskyApps[0].first)
        assertTrue(r.blocked)
    }

    @Test
    fun luckyPatcherByLabel_listedAsRisky() {
        val apps = MemApps(listOf("com.random.xyz123abc" to "Lucky Patcher"))
        val r = StrictDetect.scan(MemFs(), apps, cleanBuild())
        assertEquals(1, r.riskyApps.size)
        assertTrue(r.blocked)
    }

    @Test
    fun parallelSpaceDataDir_flagsVirtual() {
        val r = StrictDetect.scan(
            MemFs(), MemApps(emptyList()),
            cleanBuild(dataDir = "/data/data/com.lbe.parallel.intl/parallel_intl/0/com.four.student"),
        )
        assertTrue(r.virtual)
        assertTrue(r.blocked)
    }

    @Test
    fun stockTecnoXiaomiPaths_notVirtual() {
        for (dir in listOf(
            "/data/user/0/com.four.student",
            "/data/data/com.four.student",
            "/data/user/10/com.four.student", // work profile — allowed
        )) {
            val r = StrictDetect.scan(MemFs(), MemApps(emptyList()), cleanBuild(dataDir = dir))
            assertFalse("dir=$dir", r.virtual)
            assertFalse("dir=$dir", r.blocked)
        }
    }

    @Test
    fun writableSystem_flagsRoot() {
        val fs = MemFs().also {
            it.put("/proc/self/mounts", "/dev/block/dm-0 /system ext4 rw,seclabel 0 0\n")
        }
        val r = StrictDetect.scan(fs, MemApps(emptyList()), cleanBuild())
        assertTrue(r.rooted)
    }
}
