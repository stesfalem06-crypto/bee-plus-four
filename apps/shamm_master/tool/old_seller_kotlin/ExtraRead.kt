import com.beeplus.licensing.QrPayload
object Extra {
    fun check(f: String, c: String, n: Int): Boolean {
        if (f != "RCH1") return true
        val r = QrPayload.readRechargeCode(c)
        return r is QrPayload.RechargeRead.Ok && r.canonical == c && r.payload.credits == n
    }
    fun summary(r: List<List<String>>) {}
}
