# 4 — encrypted study content (1.0.4)

Up to 1.0.3 about 99 MB of notes, exams, matric questions/tips, exercises, tutor index and pictures were plain
files in the APK: unzip it and read them. From 1.0.4 the APK only carries encrypted blobs.

## What is encrypted
Everything listed in `tool/content_assets.txt` (1 220 files, 98.9 MB): notes (`assets/high/notes/**`, incl. split
units, unit questions and lesson SVGs), all exams and matric papers (`exams/`, `matric_lazy/`, exam pictures), matric
tips / similar questions (inside the exam packs), exercises and school papers, tutor index + concepts, study coach
and motivation texts, media pictures + 3D models, board codes (`codes.json`).

Not encrypted (on purpose): the fonts and the app's how-to video (`assets/high/howto/`, app help, played by the
native video player). GPA rules are Dart code, not an asset.

## Build
```
python3 tool/encrypt_assets.py          # assets/c/<blob> + .four_content_define.json (both gitignored)
python3 tool/encrypt_assets.py --verify
flutter build apk --release --obfuscate --split-debug-info=<private dir> \
  --dart-define-from-file=.four_content_define.json --split-per-abi --target-platform android-arm
```
or simply `tool/build_release.sh --split-per-abi --target-platform android-arm`.

* The plain sources stay in git exactly as before (all content tools keep working). `pubspec.yaml` bundles only
  `assets/c/` (+ how-to video + fonts). **Never add an `assets/high/<content>` folder to pubspec again.** A new
  content folder goes into `tool/content_assets.txt`.
* `assets/c/` is generated and gitignored (re-running is incremental: unchanged files are kept; ~4 s for all).
  Committing ~32 MB of random-looking binaries that change on every run would only bloat the repo.
* A build without `--dart-define-from-file=.four_content_define.json` has no content key and shows no content.
* CI (`.github/workflows/build-four-apk.yml`, only runs on `main`) does not encrypt yet: the push token has no
  `workflow` scope, so the change is kept as a patch outside the repo (`four_1.0.4_ci_workflow.patch`). It adds an
  encrypt step that needs the repository secret `FOUR_CONTENT_KEY_B64` (`base64 -w0 content_key.bin`) and builds
  with the define file. Until it is applied, a CI build has no content. Keep the repo private if you add the secret.

## Format (tool/encrypt_assets.py = lib/content/content_vault.dart = ContentChannel.kt)
Blob name = first 32 hex of SHA-256(`four-content-v1|<asset path>`) → no file names in the APK either.
`'4CF' | version 1 | flags (bit0 = gzip) | plain length (u32) | 12-byte random nonce | AES-256-GCM ciphertext+tag`,
AAD = the 9 header bytes + the asset path (a blob cannot be renamed/swapped or edited). Text is gzip'd before
encryption (98.9 MB → 32.3 MB), which keeps the APK the same size as before.

## Key
A fresh random 32-byte key, **not** related to the old resource master key. Real key: `/workspace/keys/four/content_key.bin`
(backup `/workspace/backups/four_content_key/content_key.bin`) — never in git. In the app it is rebuilt as
`A xor B xor C`: A = `_contentA` (lib/licensing/secrets.dart), B = `CONTENT_B` (GuardChannel.kt), C = compiled in from
the gitignored `.four_content_define.json`. A and B are public, so the repo alone does not give the key. Lose the key
file and you can still rebuild it from A, B and C of a build — but keep the backup.
Rotating: new key file + new masks (tool/gen_secret_masks.py for A and B), re-run the encryptor. Old APKs are not
affected (each APK carries its own blobs).

## Runtime
`contentBundle` (lib/content/content_vault.dart) replaces rootBundle for every content path; Image.asset gets
`bundle: contentBundle`. On Android the blob is read from the APK and decrypted in `ContentChannel.kt` on a
background thread pool (javax.crypto + GZIP); Dart sends its share once. Plain bytes are kept in an LRU cache
(24 MB); repos stay lazy (one split unit / one exam pack at a time). Tests/desktop use a Dart decrypter
(background isolate for big files); `test/flutter_test_config.dart` hands it the key file, or falls back to the plain
sources when no key file exists.

## Honest limits
This stops copying the content by unzipping the APK. It does **not** stop someone with a rooted phone + Frida (or a
patched app) from hooking the decrypt call or dumping the decrypted text from memory, and whoever fully
reverse-engineers one APK can rebuild the key. Offline apps cannot do better; it makes copying slow and skilled.
