package com.warsay.high

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Finds a Bee Seller unlock code inside noisy text (camera OCR, a photo, or a hand-typed code)
 * and returns the exact payload **only if its HMAC verifies**. The signature is the error check,
 * so OCR look-alikes (0/O, 1/l/|, 5/S, 8/B …) can be tried safely: a wrong guess never verifies.
 *
 * Two legit layouts (same as lib/licensing/qr_payload.dart):
 *  - Kotlin Bee Seller (bee-plus-ecosystem core-licensing QrPayload.createUnlockCode):
 *      BEE1|<deviceId>|<J|H|K…>|<nonce 8 hex>|<timestamp ms>|<hmac 12 bytes = 24 hex>
 *  - Flutter Bee Seller (old seller_main.dart / Windows seller):
 *      BEE1|<HIGHSCHOOL|JUNIOR>|<deviceId>|<nonce hex>|<hmac-sha256 64 hex>
 *
 * Device binding, package and single-use nonce are still enforced in Dart (UnlockStore).
 * Pure JVM code (no Android APIs) so it is unit tested in src/test.
 */
object UnlockCodeRecovery {
    // Seller HMAC keys, XOR-split so they are not plain strings in classes.dex (obfuscation only; must stay
    // equal to Bee Seller's keys, see lib/licensing/secrets.dart).
    private val SELLER_A = byteArrayOf(-36, -27, -48, 64, 67, 76, 122, 83, 62, -97, 3, 79, 123, -26, -5, -112, -54, -106, -88, 74, 103, 13, 119, -32, -30, -71, 23, -128, 29, -85, 55, 80, -65, 124, 75, -90, 118, -98, -29)
    private val SELLER_B = byteArrayOf(-98, -96, -107, 109, 19, 0, 47, 0, 19, -48, 69, 9, 55, -81, -75, -43, -25, -59, -19, 9, 53, 72, 35, -51, -108, -120, 58, -59, 73, -122, 5, 96, -115, 74, 102, -11, 62, -33, -82)
    private val FLUTTER_A = byteArrayOf(111, 115, 117, 63, 50, 70, -113, -54, -94, -99, 33, -74, 46, 16, -99, 10, 103, 21, -127, -67, 29, -8, 82, -42, -119, -43, 0, -45, -4, -60, 7, 95, -96, 89, -48, -83, 79, 94, -92, 26, -44, 23, 59, -4, -2, -25, -90, 35, -41, 63)
    private val FLUTTER_B = byteArrayOf(45, 54, 48, 96, 98, 10, -38, -103, -3, -40, 115, -1, 122, 66, -40, 75, 56, 90, -57, -5, 81, -79, 28, -109, -42, -99, 77, -110, -65, -101, 81, 110, -1, 26, -104, -20, 1, 25, -31, 69, -99, 89, 100, -82, -69, -85, -29, 98, -124, 122)
    private fun unmask(a: ByteArray, b: ByteArray) = ByteArray(a.size) { (a[it].toInt() xor b[it].toInt()).toByte() }

    /** Upper bound of signature checks for one piece of text (keeps low-end phones responsive). */
    private const val MAX_CHECKS = 4000

    private val START = Regex("[Bb8][Ee3][Ee3][1lI|!iL]")

    /** Characters OCR may produce for the `|` separator. */
    private const val SEPS = "|lI1!i/\\:;[]()L"

    private val HEX_LOOKALIKE: Map<Char, CharArray> = buildMap {
        for (c in "0123456789abcdef") put(c, charArrayOf(c))
        for (c in "ACDEF") put(c, charArrayOf(c.lowercaseChar()))
        put('B', charArrayOf('8', 'b'))
        put('b', charArrayOf('b', '6'))
        for (c in "OoQDU") put(c, charArrayOf('0'))
        for (c in "IlLi|!jJT") put(c, charArrayOf('1'))
        for (c in "Zz") put(c, charArrayOf('2'))
        for (c in "Ss$") put(c, charArrayOf('5'))
        put('G', charArrayOf('6'))
        for (c in "gq") put(c, charArrayOf('9'))
    }

    private val DIGIT_LOOKALIKE: Map<Char, CharArray> = buildMap {
        for (c in "0123456789") put(c, charArrayOf(c))
        for (c in "OoQDU") put(c, charArrayOf('0'))
        for (c in "IlLi|!jJT") put(c, charArrayOf('1'))
        for (c in "Zz") put(c, charArrayOf('2'))
        for (c in "Ss$") put(c, charArrayOf('5'))
        for (c in "Gb") put(c, charArrayOf('6'))
        put('B', charArrayOf('8'))
        for (c in "gq") put(c, charArrayOf('9'))
        put('A', charArrayOf('4'))
    }

    data class Recovered(val payload: String, val layout: String)

    /**
     * @param text raw text (may contain other words, line breaks, look-alike characters)
     * @param deviceId this phone's id (helps when OCR misreads the device field); may be null
     */
    fun recover(text: String, deviceId: String?): Recovered? {
        if (text.isBlank()) return null
        val s = normalizeRaw(text)
        val budget = intArrayOf(MAX_CHECKS)
        for (m in START.findAll(s)) {
            val rest = s.substring(m.range.last + 1)
            recoverKotlin(rest, deviceId, budget)?.let { return Recovered(it, "seller6") }
            recoverFlutter(rest, deviceId, budget)?.let { return Recovered(it, "flutter5") }
            if (budget[0] <= 0) break
        }
        return null
    }

    /** True if [text] contains something that starts like an unlock code (for scanner hints). */
    fun looksLikeCode(text: String): Boolean = START.containsMatchIn(normalizeRaw(text))

    /** Exact (already clean) payload signature check, both layouts. */
    fun verifyExact(payload: String): Boolean {
        val p = payload.trim().split("|")
        if (p.isEmpty() || p[0] != "BEE1") return false
        if (p.size == 6) {
            val body = p.subList(0, 5).joinToString("|")
            return hmac12(body).equals(p[5], ignoreCase = true)
        }
        if (p.size == 5) {
            val body = p.subList(0, 4).joinToString("|")
            return hmacFull(body).equals(p[4], ignoreCase = true)
        }
        return false
    }

    internal fun normalizeRaw(text: String): String {
        val sb = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                c.isWhitespace() -> {}
                c == '%' && i + 2 < text.length && text.substring(i + 1, i + 3).equals("7C", true) -> {
                    sb.append('|'); i += 2
                }
                c == '\uFF5C' || c == '\u00A6' || c == '\u2223' || c == '\u01C0' -> sb.append('|')
                else -> sb.append(c)
            }
            i++
        }
        return sb.toString()
    }

    // ── Kotlin seller: BEE1|dev|pkg|nonce8|ts13|hmac24 ─────────────────────────

    private fun recoverKotlin(rest: String, deviceId: String?, budget: IntArray): String? {
        for (p0 in sepOptions(rest, 0)) {
            for ((devEnd, devs) in deviceOptions(rest, p0, deviceId)) {
                for (p1 in sepOptions(rest, devEnd)) {
                    for (pkgLen in 1..3) {
                        val pkgRaw = rest.safeSub(p1, p1 + pkgLen) ?: continue
                        val pkg = pkgRaw.uppercase()
                        if (!pkg.all { it == 'J' || it == 'H' || it == 'K' }) continue
                        for (p2 in sepOptions(rest, p1 + pkgLen)) {
                            val nonceRaw = rest.safeSub(p2, p2 + 8) ?: continue
                            val nonces = expand(nonceRaw, HEX_LOOKALIKE, 16) ?: continue
                            for (p3 in sepOptions(rest, p2 + 8)) {
                                val tsRaw = rest.safeSub(p3, p3 + 13) ?: continue
                                val tss = expand(tsRaw, DIGIT_LOOKALIKE, 8) ?: continue
                                for (p4 in sepOptions(rest, p3 + 13)) {
                                    val sigRaw = rest.safeSub(p4, p4 + 24) ?: continue
                                    if (!compatibleShape(sigRaw, HEX_LOOKALIKE)) continue
                                    for (dev in devs) for (n in nonces) for (ts in tss) {
                                        if (budget[0]-- <= 0) return null
                                        val body = "BEE1|$dev|$pkg|$n|$ts"
                                        val sig = hmac12(body)
                                        if (compatible(sigRaw, sig, HEX_LOOKALIKE)) return "$body|$sig"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return null
    }

    // ── Flutter seller: BEE1|HIGHSCHOOL|dev|nonce|hmac64 ──────────────────────

    private val WORDS = listOf("HIGHSCHOOL", "JUNIOR")

    private fun recoverFlutter(rest: String, deviceId: String?, budget: IntArray): String? {
        for (p0 in sepOptions(rest, 0)) {
            for (word in WORDS) {
                val raw = rest.safeSub(p0, p0 + word.length) ?: continue
                if (!wordLike(raw, word)) continue
                for (p1 in sepOptions(rest, p0 + word.length)) {
                    for ((devEnd, devs) in deviceOptions(rest, p1, deviceId)) {
                        for (p2 in sepOptions(rest, devEnd)) {
                            for (nLen in intArrayOf(12, 8, 16, 10, 32)) {
                                val nonceRaw = rest.safeSub(p2, p2 + nLen) ?: continue
                                val nonces = expand(nonceRaw, HEX_LOOKALIKE, 8) ?: continue
                                for (p3 in sepOptions(rest, p2 + nLen)) {
                                    val sigRaw = rest.safeSub(p3, p3 + 64) ?: continue
                                    if (!compatibleShape(sigRaw, HEX_LOOKALIKE)) continue
                                    for (dev in devs) for (n in nonces) {
                                        if (budget[0]-- <= 0) return null
                                        val body = "BEE1|$word|$dev|$n"
                                        val sig = hmacFull(body)
                                        if (compatible(sigRaw, sig, HEX_LOOKALIKE)) return "$body|$sig"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return null
    }

    // ── helpers ────────────────────────────────────────────────────────────

    /** Positions after an optional separator at [pos]. A real '|' must be consumed. */
    private fun sepOptions(s: String, pos: Int): List<Int> {
        if (pos >= s.length) return emptyList()
        val c = s[pos]
        return when {
            c == '|' -> listOf(pos + 1)
            SEPS.indexOf(c) >= 0 -> listOf(pos + 1, pos)
            else -> listOf(pos, pos + 1) // OCR dropped the bar, or read it as something odd
        }
    }

    /**
     * Device field candidates: (endIndex, list of exact device strings to try in the HMAC).
     * The seller signs exactly what was typed; we try this phone's id (as-is / lowercase)
     * when the OCR'd field has the same length, plus the OCR'd token itself.
     */
    private fun deviceOptions(s: String, start: Int, deviceId: String?): List<Pair<Int, List<String>>> {
        if (start >= s.length) return emptyList()
        val out = ArrayList<Pair<Int, List<String>>>(3)
        val id = deviceId?.trim().orEmpty()
        if (id.isNotEmpty()) {
            val tok = s.safeSub(start, start + id.length)
            if (tok != null && looselySame(tok, id)) {
                out.add(start + id.length to linkedSetOf(id, id.lowercase(), id.uppercase(), tok).toList())
            }
        }
        val bar = s.indexOf('|', start)
        if (bar > start && bar - start <= 64 && out.none { it.first == bar }) {
            out.add(bar to listOf(s.substring(start, bar)))
        }
        return out
    }

    /** ≥ 2/3 of characters match ignoring case and look-alikes. */
    private fun looselySame(tok: String, id: String): Boolean {
        var ok = 0
        for (i in tok.indices) {
            val a = tok[i].uppercaseChar()
            val b = id[i].uppercaseChar()
            if (a == b || canon(a) == canon(b)) ok++
        }
        return ok * 3 >= id.length * 2
    }

    private fun canon(c: Char): Char = when (c) {
        'O', 'Q', 'D', '0' -> '0'
        'I', 'L', '1', '|', '!', 'J', 'T' -> '1'
        'Z', '2' -> '2'
        'S', '5', '$' -> '5'
        'B', '8' -> '8'
        'G', '6' -> '6'
        else -> c
    }

    private fun wordLike(raw: String, word: String): Boolean {
        var ok = 0
        for (i in word.indices) if (canon(raw[i].uppercaseChar()) == canon(word[i])) ok++
        return ok * 4 >= word.length * 3
    }

    /** All exact strings [raw] could be (bounded); null if a char cannot belong to the field. */
    private fun expand(raw: String, map: Map<Char, CharArray>, cap: Int): List<String>? {
        var acc = listOf("")
        for (c in raw) {
            val opts = map[c] ?: return null
            if (opts.size == 1) {
                acc = acc.map { it + opts[0] }
            } else {
                val next = ArrayList<String>(acc.size * opts.size)
                for (a in acc) for (o in opts) next.add(a + o)
                acc = if (next.size > cap) next.subList(0, cap) else next
            }
        }
        return acc
    }

    private fun compatibleShape(raw: String, map: Map<Char, CharArray>): Boolean = raw.all { map.containsKey(it) }

    private fun compatible(raw: String, expected: String, map: Map<Char, CharArray>): Boolean {
        if (raw.length != expected.length) return false
        for (i in raw.indices) {
            val opts = map[raw[i]] ?: return false
            if (opts.none { it == expected[i] }) return false
        }
        return true
    }

    private fun String.safeSub(a: Int, b: Int): String? =
        if (a < 0 || b > length || a > b) null else substring(a, b)

    private fun newMac(key: ByteArray): Mac = Mac.getInstance("HmacSHA256").apply {
        init(SecretKeySpec(key, "HmacSHA256"))
    }

    private val sellerMac = ThreadLocal.withInitial { newMac(unmask(SELLER_A, SELLER_B)) }
    private val flutterMac = ThreadLocal.withInitial { newMac(unmask(FLUTTER_A, FLUTTER_B)) }

    private fun hex(bytes: ByteArray, n: Int): String {
        val digits = "0123456789abcdef"
        val sb = StringBuilder(n * 2)
        for (i in 0 until n) {
            val v = bytes[i].toInt() and 0xff
            sb.append(digits[v ushr 4]).append(digits[v and 0x0f])
        }
        return sb.toString()
    }

    internal fun hmac12(body: String): String =
        hex(sellerMac.get()!!.doFinal(body.toByteArray(Charsets.UTF_8)), 12)

    internal fun hmacFull(body: String): String =
        hex(flutterMac.get()!!.doFinal(body.toByteArray(Charsets.UTF_8)), 32)
}
