// Secrets kept out of plain sight. Each value is split into two random-looking byte lists that are XOR-ed
// together only when needed, so `strings libapp.so` / a hex search of the APK no longer shows them.
// This is obfuscation, not encryption: someone who reverse-engineers the Dart AOT code can still rebuild
// them (see the 1.0.3 security audit). Release builds also use --obfuscate.
//
// Regenerate (only when rotating keys!) with tool/gen_secret_masks.py. Changing seller/flutter/devMk
// breaks every existing Bee Seller code / encrypted resource, so they must stay the same values.
import 'dart:convert';
import 'dart:typed_data';

abstract final class FourSecrets {
  static Uint8List _x(List<int> a, List<int> b) {
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  static const _sellerA = <int>[178, 199, 34, 32, 97, 117, 12, 195, 120, 74, 120, 9, 150, 75, 73, 234, 145, 57, 221, 147, 76, 145, 25, 25, 33, 211, 250, 132, 50, 230, 224, 54, 255, 231, 19, 211, 243, 22, 222];
  static const _sellerB = <int>[240, 130, 103, 13, 49, 57, 89, 144, 85, 5, 62, 79, 218, 2, 7, 175, 188, 106, 152, 208, 30, 212, 77, 52, 87, 226, 215, 193, 102, 203, 210, 6, 205, 209, 62, 128, 187, 87, 147];

  static const _flutterA = <int>[42, 79, 97, 31, 15, 186, 54, 75, 164, 203, 72, 215, 80, 5, 221, 246, 55, 245, 124, 93, 106, 223, 220, 248, 38, 178, 151, 178, 202, 202, 145, 4, 115, 205, 164, 206, 26, 31, 205, 132, 37, 82, 148, 172, 205, 20, 110, 9, 116, 37];
  static const _flutterB = <int>[104, 10, 36, 64, 95, 246, 99, 24, 251, 142, 26, 158, 4, 87, 152, 183, 104, 186, 58, 27, 38, 150, 146, 189, 121, 250, 218, 243, 137, 149, 199, 53, 44, 142, 236, 143, 84, 88, 136, 219, 108, 28, 203, 254, 136, 88, 43, 72, 39, 96];

  static const _devMkA = <int>[103, 48, 217, 116, 239, 198, 147, 50, 82, 45, 165, 183, 45, 201, 214, 30, 92, 236, 159, 227, 244, 225, 131, 58, 17, 254, 219, 110, 231, 213, 184, 118];
  static const _devMkB = <int>[114, 248, 22, 183, 155, 77, 197, 166, 247, 194, 233, 106, 78, 233, 142, 222, 51, 96, 231, 206, 40, 35, 160, 13, 69, 56, 61, 42, 150, 5, 197, 37];

  static const _bindSwA = <int>[184, 5, 128, 175, 163, 93, 94, 252, 178, 168, 59, 134, 206, 141, 78, 36, 121, 15, 27, 33, 221, 22, 96, 37, 221, 206, 153, 79, 237, 225, 15, 1];
  static const _bindSwB = <int>[69, 218, 36, 65, 11, 248, 102, 31, 173, 122, 170, 18, 252, 99, 41, 230, 34, 63, 69, 168, 119, 200, 255, 68, 207, 192, 104, 105, 203, 213, 191, 128];

  // content key share A (4 1.0.4+). The content key is A xor B xor C: B is CONTENT_B in GuardChannel.kt and C is
  // compiled in from the gitignored .four_content_define.json (tool/encrypt_assets.py). A alone is useless.
  static const _contentA = <int>[205, 66, 18, 190, 24, 254, 189, 34, 7, 24, 90, 135, 141, 251, 34, 83, 109, 234, 151, 109, 188, 127, 11, 59, 176, 180, 164, 40, 0, 0, 235, 21];

  static const _signerA = <int>[39, 219, 181, 196, 92, 60, 128, 38, 8, 152, 112, 48, 31, 74, 1, 156, 34, 57, 67, 39, 178, 62, 86, 15, 208, 61, 131, 180, 73, 90, 6, 177];
  static const _signerB = <int>[208, 211, 9, 119, 37, 186, 128, 168, 180, 249, 153, 156, 29, 208, 62, 157, 41, 89, 21, 129, 190, 113, 137, 129, 160, 59, 211, 47, 228, 62, 137, 173];


  /// Kotlin Bee Seller HMAC key (6-field codes). Must match Bee Seller: never change.
  static String sellerKey() => utf8.decode(_x(_sellerA, _sellerB));

  /// Flutter / Windows seller default HMAC key (5-field codes) and resource-proof key. Never change.
  static String flutterKey() => utf8.decode(_x(_flutterA, _flutterB));

  /// Master key v1 of encrypted add-on resources (= SHA-256 of the old DEV string). Never change: every
  /// .4pdf/.4web/.4vid already handed out is sealed with it.
  static Uint8List devMasterKey() => _x(_devMkA, _devMkB);

  /// Software HMAC key for the signed unlock state (second factor next to the Android Keystore key).
  static Uint8List bindSoftwareKey() => _x(_bindSwA, _bindSwB);

  /// Dart share of the bundled-content key (A xor C) that is handed to the native side once (ContentChannel.kt
  /// adds its share B). Empty when the build has no FOUR_CK (debug/tests without the key file).
  static Uint8List contentShare() {
    const c = String.fromEnvironment('FOUR_CK');
    if (c.length != 64) return Uint8List(0);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = _contentA[i] ^ int.parse(c.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// SHA-256 of the one release signing certificate of 4 (CN=Four, O=Four, C=ER; F7:08:BC…8F:1C).
  static Uint8List releaseSigner() => _x(_signerA, _signerB);
}
