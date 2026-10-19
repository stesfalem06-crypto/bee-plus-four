// Runs before every test file. 4 1.0.4+ bundles study content only encrypted (assets/c/, tool/encrypt_assets.py).
// With the content key file present (default /workspace/keys/four/content_key.bin, or $FOUR_CONTENT_KEY_FILE) and
// the blobs generated, every content read in the tests goes through the real decrypter. Without the key (a fresh
// clone, CI without the secret) the loader reads the plain source files from the repo instead, so the content tests
// still run; test/content_vault_test.dart then skips its encrypted checks.
import 'dart:async';
import 'dart:io';

import 'package:high/content/content_vault.dart';
import 'package:high/high/app.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final kf = File(Platform.environment['FOUR_CONTENT_KEY_FILE'] ?? '/workspace/keys/four/content_key.bin');
  final blobs = Directory('assets/c');
  final haveBlobs = blobs.existsSync() && blobs.listSync().length > 1;
  if (kf.existsSync() && haveBlobs && Platform.environment['FOUR_CONTENT_PLAIN'] != 'true') {
    ContentVault.instance.debugUseKey(kf.readAsBytesSync());
  } else {
    ContentVault.instance.debugUsePlainFiles(Directory.current.path);
  }
  HighShellState.dedupPushes = false; // 1.0.6 double-tap guard: tests push the same page type back to back
  await testMain();
}
