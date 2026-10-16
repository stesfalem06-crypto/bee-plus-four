# Shamm Master

The owner's Android app that makes **top-up codes** for Bee Seller. Each code adds credit for ONE app:
**Four** (Grade 9–12) or **Winner** (Junior). Separate app: `applicationId com.shamm.master`, so it installs next to
Bee Seller, Four (`com.four.student`) and Winner. Was `lib/master_main.dart` inside Four before.

## What it does
- **Admin PIN** (4–6 numbers) on open, and again after 60 s in the background. 5 wrong tries → wait.
- **Make code**: seller (type, paste, recent-seller chips, or **scan the seller's ID QR** from Bee Seller), app
  (Four / Winner), amount (10, 20, 50, 100, 200, 500 or Other) → QR + text code with **Share** and **Copy**.
- **Check code**: scan or paste any code → real or not, app, credit, seller, and whether this phone made it.
  Reads new `BEE1|WHOLESALE:FOUR|WINNER:n|…`, old `BEE1|WHOLESALE:n|…` and old `RCH1|…` codes.
- **History**: every code made, search (seller, name, app, amount), **CSV export** (share sheet).
- First-launch **step-by-step guide** (menu → Show the guide again). Every text box has a Clear (X) button and
  stays above the keyboard.

## Code format (1.0.1: selectable, default Classic RCH1)
- **Classic (default)** `RCH1|{sellerId}|{n}|{nonce10}|{timeMs}|{hmac24}` — read by every Bee Seller (Android
  1.0.0-beta, 1.1.0, 1.1.1, 1.1.2, 1.2.0; Windows). Old sellers have one balance (1.2.0 adds it to Four). Not bound
  to the seller: anyone holding the code can redeem it once.
- **BEE1 (Seller 1.1.2+)** `BEE1|WHOLESALE:{n}|{sellerId}|{nonce12}|{hmac64}` — Android 1.1.2+, Flutter com.bee.seller.
- **Per app (Seller 1.2.0)** `BEE1|WHOLESALE:{FOUR|WINNER}:{n}|…` — Bee Seller 1.2.0 / Windows 3.2.0 only.
See `lib/grant.dart`, `test/old_seller_compat_test.dart`, `tool/old_seller_kotlin/`.

## Scanner
`android/.../ScanActivity.kt` is Four's working CameraX + bundled ML Kit barcode scanner (auto-zoom, torch,
tap-to-focus, late-callback-safe), without the text-recognition pass (smaller APK, faster on low-end phones).
`android/app/proguard-rules.pro` carries Four's R8 keep rule for ML Kit's `ComponentRegistrar` constructors —
without it R8 full mode strips them and `BarcodeScanning.getClient()` crashes.

## Build
    flutter test
    tool/bee_seller_compat.sh        # SELLER_REPO=…/bee-plus-ecosystem GRADLE=gradle: runs Bee Seller's own parser on our codes
    flutter build apk --release --split-per-abi --target-platform android-arm

Release signing: `android/key.properties` (git-ignored) or env `MASTER_KEYSTORE`, `MASTER_KEYSTORE_PASSWORD`,
`MASTER_KEY_ALIAS`, `MASTER_KEY_PASSWORD`. The key is NOT in git.
