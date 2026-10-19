# 4 — anti-clone binding and the 1.0.3 migration

Problem (≤ 1.0.2): the unlock was a random id + `unlocked=true` in plain SharedPreferences and
`android:allowBackup` defaulted to true. Samsung Smart Switch (or any backup/restore) copied an unlocked 4 —
with the same id — to another phone.

## What 1.0.3 does

1. **Nothing leaves the phone.** `allowBackup="false"`, `fullBackupContent="false"`,
   `dataExtractionRules` excluding every domain for `cloud-backup` **and** `device-transfer` (Android 12+ ignores
   allowBackup for device-to-device transfer), `hasFragileUserData="false"`.
2. **Phone-bound id.** `hardwareDeviceId()` = SHA-256 of `ANDROID_ID | manufacturer | model | device` → 12 characters
   from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (same look as the old ids, so Bee Seller is unchanged). On Android 8+
   ANDROID_ID is unique per signing key + phone + user, survives reinstall/app updates and is not copied by
   Smart Switch or Google backup. Board/hardware/brand and the full fingerprint are NOT used (they can change with
   OS updates).
3. **Signed state.** One JSON record (`four_bind_v2`: id, accepted ids, unlocked, used nonces) sealed with
   * an HMAC from a **non-exportable Android Keystore key** (`four_bind_hmac_v1`) — it never leaves the phone;
   * a software HMAC keyed with the phone id (fallback when the Keystore misbehaves).
   Editing the XML on a rooted phone, or copying it to another phone, makes the record fail.
4. **Native guard** (`GuardChannel.kt`, channel `com.four.student/guard`): ANDROID_ID + Build values, Keystore HMAC,
   probe of the 1.0.x secure storage, APK signer SHA-256, soft environment signals.

## Launch decision (`decideLaunch` in `lib/licensing/device_binding.dart`, tested in `test/anti_clone_test.dart`)

Rule: **relock only on positive evidence** that the unlock was made on another phone or edited.
When unsure, a genuine student stays unlocked.

### A 1.0.3 record exists
| Keystore HMAC | software seal + same phone id | record says | result |
|---|---|---|---|
| verifies | – | – | **keep** (if the phone id changed, e.g. OS update renamed the model, the new id is added) |
| key missing / Keystore error | ok (id from ANDROID_ID, or Keystore never worked there) | – | **keep**, Keystore key re-created |
| does not verify | fails | locked | **fresh** (re-created locked, nothing lost) |
| does not verify | fails, other phone id | unlocked | **relock (moved)** |
| does not verify | fails, same phone id | unlocked | **relock (tampered)** |
| record unreadable | | | **relock (tampered)** |

### First launch of 1.0.3 (migration of 1.0.0 – 1.0.2)
Every 1.0.x that could store a proof used flutter_secure_storage **11.2.0** with default options: a Keystore RSA-OAEP
key `<package>.FlutterSecureStoragePluginKeyOAEP` wraps an AES key kept in `FlutterSecureKeyStorage.xml`; the
encrypted proof is `…_four_res_unlock_v1` in `FlutterSecureStorage.xml`. Smart Switch / backup copied both XML
files but never the Keystore key.

The native probe runs **before anything opens flutter_secure_storage**: on first use the plugin silently creates a
new RSA key when it has none (`createRSAKeysIfNeeded`), which would hide the "no Keystore key" evidence. It does
not delete the copied data (`resetOnError` defaults to false in 11.2.0; its migration fails at the first unwrap,
before it deletes or re-wraps anything), so a copy that 1.0.2 already opened keeps the copied wrapped key next to
a new RSA key that does not fit it. The probe is read-only: it creates, changes and deletes nothing.

| 1.0.x state | evidence | result |
|---|---|---|
| locked | – | **fresh**: new id shown; a code already bought for the old id is still accepted once |
| unlocked | proof + wrapped key present, plugin RSA key **missing** | **relock (moved)** — Smart Switch / restore copy, not opened with 1.0.2 yet (proof is not even read) |
| unlocked | proof readable, HMAC ok, made for the old id | **migrateVerified** (silent, stays unlocked) — wins over every other signal |
| unlocked | plugin cannot read the proof **and** this phone's RSA key provably does not fit the stored wrapped key (OAEP `BadPaddingException`) | **relock (moved)** — copy that 1.0.2 already opened on the new phone |
| unlocked | plugin cannot read the proof, no key-mismatch evidence (Keystore busy, timeout 8 s, other error) | **migrateUnverified** (stays unlocked) |
| unlocked | proof readable but for another id / other HMAC key | **migrateUnverified** (stays unlocked) |
| unlocked | no proof at all | **migrateUnverified** (stays unlocked); `--dart-define=FOUR_STRICT_LEGACY=true` would relock |
| probe failed | – | never treated as a copy |
| no native guard | – | **legacyMode** = 1.0.2 behaviour (tests/desktop; never expected on a real phone) |

Safety of the key-mismatch rule: it needs two independent failures (the plugin's own read **and** the native
unwrap with the specific padding error; Keystore's generic errors map to other exceptions and are ignored). A
genuine phone whose proof reads fine is migrated before this rule is looked at, so a mistake in the native
check cannot relock it (tested).

After a migration the old id stays accepted **on that phone only** (it is inside the Keystore-sealed record);
from then on any copy relocks. After a relock only the new phone id is accepted, so a code made for the
source phone does not open the copy.

### Why "no proof" is not relocked
A 1.0.x install has no proof if it was unlocked before encrypted resources existed (builds before 7 Oct 2026)
or the proof write failed. A copy of such a phone has no proof either. Offline these cannot be told apart. They
stay unlocked but are bound to the phone at that moment, so they cannot be copied again. See the audit for the
update strategy that limits this.

### Possible false relocks (rare, documented)
* The phone's Keystore lost the flutter_secure_storage key (Keystore reset by an OS bug, "clear credentials" on
  some old Android versions) **and** the proof file is still there → treated as a copy (also when 1.0.2 then
  re-created the key). The student shows the new id and gets a new code.
* Keystore key lost **and** the phone id changed (OS update renamed MANUFACTURER/MODEL/DEVICE) at the same time.
* A factory reset always gives a new ANDROID_ID (all data is gone anyway).

### Session blocks (not stored, next clean start is normal)
* APK not signed with the 4 release certificate (SHA-256 `F7:08:BC:…:8F:1C`) or `debuggable` → "This copy of 4 was changed".

### STRICT mode (1.0.5+)
On launch and on resume, Four runs a cheap native scan (`StrictDetect` / `GuardChannel.env`). If **any** of
these is found, Four does **not** open: a full-screen page asks the student to uninstall Four (and the tool app
when one is the cause), then try again:

* **Root:** `su` in common paths, Magisk / KernelSU / APatch paths and mounts, Superuser packages, `test-keys`,
  `ro.debuggable=1` / `ro.secure=0`, writable `/system`.
* **Hooking:** Frida (maps, threads, ports 27042/27043), Xposed / LSPosed / EdXposed / Substrate, attached debugger,
  app `debuggable` flag, signature mismatch (existing check).
* **Tooling apps installed:** MT Manager, NP Manager, APK Editor, APKTool M, Lucky Patcher (also by app label),
  GameGuardian, APK extractors, Show Java, App Cloner, Parallel Space / virtual hosts, HappyMod, etc. Package names
  are stored XOR-masked in the APK; a `<queries>` manifest block lists them (no `QUERY_ALL_PACKAGES`).
* **Emulator** and **running inside a virtual / clone container** (data-dir path heuristics).

Developer options / USB debugging alone are **not** flagged (normal on Samsung / Tecno / Infinix / Xiaomi stock).
