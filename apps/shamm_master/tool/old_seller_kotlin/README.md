Runs the REAL old Bee Seller Android validator (core-licensing QrPayload.kt from bee-plus-ecosystem:
1.0.0-beta 454b17b, 1.1.0 0af9b34, 1.1.1 b86a021, 1.1.2 afd62db) on build/old_seller_vectors.tsv
(written by `flutter test test/old_seller_compat_test.dart`). Put each version's QrPayload.kt in vXXX/ plus
core-common PackageType.kt, then compile with kotlin-compiler-embeddable (K2JVMCompiler) together with
HarnessBase.kt and ExtraNone.kt (1.0.0-beta, 1.1.0) / ExtraRead.kt (1.1.1) / ExtraGrant.kt (1.1.2), and run
`java -cp out:kotlin-stdlib.jar HarnessBaseKt old_seller_vectors.tsv <ver>`.
Result 2026-10-16: every version accepts all 30 RCH1 codes (Four + Winner, 1..100000, 3 seller IDs) once, refuses
tampered amounts; 1.1.2 also accepts BEE1|WHOLESALE:n (no app) and refuses BEE1|WHOLESALE:FOUR|WINNER:n.
