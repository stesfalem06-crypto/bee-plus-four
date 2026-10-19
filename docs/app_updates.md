# App updates for 4 (file only, never over the internet)

4 never downloads updates. Wi-Fi and mobile data are not used for updates at all, and the release app has no
`INTERNET` permission. A new version reaches a phone as an **APK file** (SHAREit, Bluetooth, Nearby Share, cable),
and 4 picks it up by itself.

## What the student sees
1. A friend (or the teacher) sends the new 4 APK, e.g. by SHAREit, into the phone.
2. The student opens 4 (or comes back to it). After a few seconds Home shows **"New 4 version X · Found in your
   resources folder · checked — Install"**. No button press is needed to find it.
   - If the file landed somewhere 4 is not watching: Settings → App updates → **Find update file** (opens the
     Android file picker in *Download*; pick the `.apk`, one tap).
3. **Install** → Android's installer asks once: **Update** (one tap; Android never allows a silent install of a
   sideloaded app). The first time, Android first asks to allow "Install unknown apps" for 4; after the student
   allows it and comes back, the install continues by itself.
4. 4 restarts on the new version. Unlock, progress and imported resources stay (same app id + same signing key).
5. To pass it on: Settings → App updates → **Send 4 to a friend (version)** opens the share sheet (SHAREit,
   Bluetooth, Nearby Share, …) with the installed APK. So updates spread phone to phone.

Locked phones never reach the app UI and do not look for updates; they simply install the received APK fresh,
as before (unlocking happens after install).

## Where 4 looks, and why not everywhere
- **Automatically, on start and on every return to the app** (debounced: at most once per 45 s; all file work on
  an Android background thread):
  - the **resources folder** chosen under Extra resources (the SAF folder 4 already has permission for), 3 levels deep;
  - an optional **update folder**: Settings → App updates → *Watch a folder for updates*, e.g. `SHAREit/apps` or
    `Download/SHAREit`. Chosen once with the system folder picker; the permission persists.
  - Resources → Refresh still checks the resources folder too.
- **Not** the whole `Download` / `SHAREit` folders without being asked: on Android 10+ an app cannot list other apps'
  files there without `MANAGE_EXTERNAL_STORAGE` / `READ_EXTERNAL_STORAGE` (dangerous or special permissions,
  and on Android 13+ not even those cover APK files). 4 adds no such permission. Instead the student either picks
  a watched folder once or uses the one-tap **Find update file** picker. (Android 11+ does not allow picking the
  `Download` root itself as a folder, but its sub-folders such as `Download/SHAREit` are fine.)

## Checks before an update is offered
Every candidate file must pass all of these (`Updater.verdict` in `lib/update/updater.dart`):
1. Package name is 4's (`com.four.student`).
2. `versionCode` is **higher** than the installed one.
3. The signing certificate (SHA-256) is **identical** to the installed app's.

To keep this cheap on low-end phones, the folder scan (`UpdateChannel.findApks`) first reads only each APK's
manifest (package + versionCode, through the file descriptor, without copying). Only a newer 4 is copied to
`cacheDir/updates` and fully checked (certificate) there; that checked copy is what the installer gets. APKs of
other apps, older 4s and wrong-key 4s are remembered by `uri|size|modified` and not opened again. If a 4 APK is
signed with another key, the update page says so ("Found 4 X, but it is signed with a different key").
Old copies are deleted once the installed version has caught up.

## IMPORTANT: updates only install over an existing 4 if every build has the same release key
Android installs an APK over an existing app only when both are signed with the **same key**, and the
`versionCode` must be higher. Today `.github/workflows/build-four-apk.yml`:
1. signs with a **debug key generated anew on each GitHub runner**, so every CI APK has a different signature.
   Android refuses one over another ("App not installed"), and 4 refuses it with "different key";
2. always produces `versionCode` 1 (`pubspec.yaml` `1.0.0+1`), so no build counts as newer.

`android/app/build.gradle.kts` already signs with a stable release key when one is provided (env vars or
`android/key.properties`), falling back to debug otherwise. The workflow must be changed by someone with workflow
permission (user side):

### One-time setup (on your computer)
```
keytool -genkeypair -v -keystore four-release.jks -alias four -keyalg RSA -keysize 4096 -validity 36500
base64 -w0 four-release.jks > four-release.jks.b64        # macOS: base64 -i four-release.jks
```
- Keep `four-release.jks` and its passwords **safe and backed up**. If they are lost, phones can never be updated
  again: users would have to uninstall, which loses their unlock.
- Add repository secrets: `FOUR_KEYSTORE_B64` (contents of the .b64 file), `FOUR_KEYSTORE_PASSWORD`,
  `FOUR_KEY_ALIAS` (= `four`), `FOUR_KEY_PASSWORD`.
- Optional, to make encrypted resources stronger: add `FOUR_MK` (from `four_encrypt newkey`) and use it in the
  Mac encryptor too.

### Workflow change
Copy `docs/ci/build-four-apk-signed.yml` over `.github/workflows/build-four-apk.yml`. Same content steps as today, plus:
- release signing from the secrets;
- `--build-number=${{ github.run_number }}`, so every build has a higher `versionCode`;
- universal + per-ABI APKs. **Share the universal APK** phone to phone (it installs on every phone);
- an optional GitHub Release on manual runs. The release (and its `four-update.json`) is only a convenient place to
  download the APK onto a computer; the app never reads it.

### Switching existing phones (once)
Phones with a CI build signed by an old random debug key cannot update to the first release-key build. Install it
once by uninstalling first (this loses unlock and resources on that phone), or keep those phones as they are.
From then on, every update keeps data.

## Releasing a new version (each time)
1. Build with the release key and a higher build number: CI (after the workflow change) or by hand:
   ```
   flutter build apk --release --build-number=<higher number> --obfuscate --split-debug-info=<private dir>   # with FOUR_KEYSTORE… env set
   # keep <private dir> (symbols for crash stack traces) off GitHub; --obfuscate is required for release since 1.0.3
   ```
2. Put `build/app/outputs/flutter-apk/app-release.apk` (universal) on one phone by cable / SHAREit, install it.
3. From that phone, **Send 4 to a friend**; each receiving phone gets the Home card on its next start.
`tool/publish_update.py` still works for making a GitHub Release with the APKs, but phones do not check it.

## Code
- `lib/update/updater.dart`: auto scan (start/resume, debounced), skip list, `verdict`, picker, install, share.
- `lib/update/update_ui.dart`: Home card, update page, Settings section.
- `android/.../UpdateChannel.kt`: `info`, `findApks` (SAF walk + manifest peek), `inspectApk`, `pickApk`
  (`ACTION_OPEN_DOCUMENT`, starts in Download), `install` (FileProvider → system installer), `shareSelf`
  (copies `ApplicationInfo.sourceDir` + any `splitSourceDirs` to `cacheDir/share`, `ACTION_SEND` /
  `ACTION_SEND_MULTIPLE` chooser).
- `lib/main.dart`: scan 4 s after start (unlocked phones) and on resume.

## Tests
`flutter test test/updater_test.dart` (Android side mocked): the verdict gate (other app, same/older version,
different or missing key), newest candidate picked and only 4 candidates copied, wrong-key refusal remembered,
other apps skipped next time, debounce, update folder, re-check of an earlier copy, cleanup after updating,
the file picker, install continuing after "Install unknown apps", sharing, and a guard that the updater has no
HTTP code and the release manifest has no `INTERNET` permission.

## Limits
- One tap on **Update** in Android's installer is always needed.
- Split installs (Play-style App Bundles) cannot be shared as one APK; *Send 4* then sends all parts and warns.
  CI builds are universal, so this normally does not happen.
- Some Bluetooth stacks refuse `.apk` files; SHAREit, Nearby Share or a cable work.
- Release builds strip `INTERNET` / `ACCESS_NETWORK_STATE` even when a library would merge them in
  (`android/app/src/release/AndroidManifest.xml`, `tools:node="remove"`; e.g. ML Kit telemetry). No 4 feature needs
  the network (ML Kit models are bundled, video/PDF read local files). Debug/profile builds keep `INTERNET` for hot reload.
