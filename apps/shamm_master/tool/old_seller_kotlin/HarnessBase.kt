import com.beeplus.licensing.QrPayload
import java.io.File
// Feeds Shamm Master 1.0.1 codes to the real old Bee Seller QrPayload.parseRechargeCode (all versions) and,
// where present, readRechargeCode (1.1.1+) / readMasterGrant (1.1.2).
fun main(args: Array<String>) {
    val ver = args[1]
    val rows = File(args[0]).readLines().filter { it.isNotBlank() }.map { it.split('\t') }
    var ok = 0; var refused = 0; var fail = 0
    val used = HashSet<String>()
    for ((fmt, id, app, n, code) in rows) {
        val r = QrPayload.parseRechargeCode(code)
        val accepted = r != null && r.credits == n.toInt()
        // single use as in SellerCreditManager.redeemRechargeCode: usage tracked by raw code
        val firstUse = used.add(code)
        val tamperedRefused = QrPayload.parseRechargeCode(code.replaceFirst("|$n|", "|${n.toInt() + 1}|")) == null
        var extra = true
        extra = extra && Extra.check(fmt, code, n.toInt())
        val expectAccept = fmt == "RCH1"
        if (expectAccept) { if (accepted && firstUse && tamperedRefused && extra) ok++ else { fail++; println("FAIL $fmt $app $n $code") } }
        else { if (!accepted) refused++ else { fail++; println("UNEXPECTED ACCEPT $fmt $code") } }
    }
    println("Bee Seller $ver: RCH1 accepted=$ok, BEE1 (not RCH1) refused by RCH1 reader=$refused, failures=$fail")
    Extra.summary(rows)
    if (fail > 0) kotlin.system.exitProcess(1)
}
