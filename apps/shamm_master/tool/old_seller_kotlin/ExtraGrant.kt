import com.beeplus.licensing.QrPayload
object Extra {
    fun check(f: String, c: String, n: Int): Boolean {
        if (f != "RCH1") return true
        val r = QrPayload.readRechargeCode(c)
        return r is QrPayload.RechargeRead.Ok && r.canonical == c && r.payload.credits == n
    }
    fun summary(rows: List<List<String>>) {
        val res = mutableMapOf<String, Int>()
        for ((fmt, id, app, n, code) in rows) {
            val g = QrPayload.readMasterGrant(code)
            val k = "$fmt/$app " + if (g is QrPayload.GrantRead.Ok && g.grant.toString().contains("$n")) "ACCEPTED" else "refused"
            res[k] = (res[k] ?: 0) + 1
        }
        println("  readMasterGrant (1.1.2 BEE1 reader): $res")
    }
}
