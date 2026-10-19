// 1.0.3 anti-clone + migration tests. A "phone" is simulated by a FakeGuard (ANDROID_ID + its own Android
// Keystore + what flutter_secure_storage left behind) and the SharedPreferences map of the app.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high/licensing/device_binding.dart';
import 'package:high/licensing/device_guard.dart';
import 'package:high/licensing/qr_payload.dart';
import 'package:high/licensing/secrets.dart';
import 'package:high/licensing/unlock_store.dart';
import 'package:high/resources/gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _signer = 'f708bcb37986008ebc61e9ac029a3f010b6056a60c4fdf8e7006509bad648f1c';

/// One phone's native side.
class FakeGuard implements DeviceGuard {
  FakeGuard(this.androidId, {this.model = 'SM-A145F', this.probe = const LegacyProbe(), this.signer = _signer, this.env = const EnvReport()});
  String androidId;
  String model;
  LegacyProbe probe;
  String signer;
  EnvReport env;
  bool keystoreBroken = false;
  List<int>? _ksKey; // the non-exportable key: never copied to another FakeGuard
  int probes = 0;

  bool get hasKey => _ksKey != null;
  void loseKeystore() => _ksKey = null;

  @override
  Future<bool> available() async => true;
  @override
  Future<HwInfo?> hardware() async => HwInfo(androidId: androidId, manufacturer: 'samsung', brand: 'samsung', model: model, device: 'a14', board: 'exynos850');
  @override
  Future<LegacyProbe> probeLegacy() async {
    probes++;
    return probe;
  }

  @override
  Future<KsMac> keystoreMac(String data, {bool create = false}) async {
    if (keystoreBroken) return const KsMac(KsStatus.unavailable);
    if (_ksKey == null) {
      if (!create) return const KsMac(KsStatus.missing);
      final r = Random.secure();
      _ksKey = List.generate(32, (_) => r.nextInt(256));
    }
    return KsMac(KsStatus.ok, Hmac(sha256, _ksKey!).convert(utf8.encode(data)).toString());
  }

  @override
  Future<List<String>?> signerDigests() async => [signer];
  @override
  Future<EnvReport> environment() async => env;
}

/// Bee Seller (Kotlin layout, unchanged): BEE1|id|H|nonce|ts|hmac12
String sellerCode(String id, {String nonce = 'a1b2c3d4', String pkg = 'H'}) {
  final body = 'BEE1|$id|$pkg|$nonce|1760000000000';
  final mac = Hmac(sha256, utf8.encode(FourSecrets.sellerKey())).convert(utf8.encode(body)).bytes.take(12);
  return '$body|${mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

const _oldId = 'QWE234RTY567';

/// SharedPreferences of an unlocked 1.0.2 install.
Map<String, Object> unlocked102({String id = _oldId}) => {'four_device_id_v1': id, 'four_highschool_unlocked': true, 'four_used_nonces': <String>['5e1f0c2a']};

String validProof(String id) => jsonEncode({'d': id, 'n': '5e1f0c2a', 's': QrPayload.resourceSecret(id, '5e1f0c2a')});

Future<Map<String, Object>> snapshot() async {
  final p = await SharedPreferences.getInstance();
  return {for (final k in p.getKeys()) k: p.get(k)!};
}

Future<UnlockStore> launch(FakeGuard phone, Map<String, Object> prefs, {String? proof, bool strict = false, bool integrity = true}) async {
  SharedPreferences.setMockInitialValues(prefs);
  FlutterSecureStorage.setMockInitialValues({UnlockStore.legacyProofKey: ?proof});
  final s = UnlockStore(guard: phone, readLegacyProof: () async => proof, enforceIntegrity: integrity, strictLegacy: strict);
  await s.init();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hardware id', () {
    test('same format as the old ids, stable, different per phone', () {
      const a = HwInfo(androidId: '9f3c2a7b11d04e55', manufacturer: 'samsung', model: 'SM-A145F', device: 'a14');
      final id = hardwareDeviceId(a);
      expect(id, matches(RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{12}$')));
      expect(hardwareDeviceId(a), id);
      expect(hardwareDeviceId(const HwInfo(androidId: '9f3c2a7b11d04e56', manufacturer: 'samsung', model: 'SM-A145F', device: 'a14')), isNot(id));
      // same ANDROID_ID on another model (root tools copying settings_ssaid.xml) still differs
      expect(hardwareDeviceId(const HwInfo(androidId: '9f3c2a7b11d04e55', manufacturer: 'samsung', model: 'SM-A055F', device: 'a05')), isNot(id));
      // board / hardware / brand are not used (they can change with an OS update)
      expect(hardwareDeviceId(const HwInfo(androidId: '9f3c2a7b11d04e55', manufacturer: 'samsung', model: 'SM-A145F', device: 'a14', board: 'x', hardware: 'y', brand: 'z')), id);
      expect(const HwInfo(androidId: '').androidIdUsable, isFalse);
      expect(const HwInfo(androidId: '9774d56d682e549c').androidIdUsable, isFalse);
    });

    test('the masked keys still equal the Bee Seller keys (Bee Seller unchanged)', () {
      // compared by SHA-256 so the test does not repeat the keys in plain text
      String h(List<int> b) => sha256.convert(b).toString();
      expect(h(utf8.encode(FourSecrets.sellerKey())), 'ad7229188447cc9480a9271744025a0112f5bbbd83d91b4339492b9db0e16032');
      expect(h(utf8.encode(FourSecrets.flutterKey())), '9f07e6a39892060c882dc8ae03929030e54ba388c643bcf2f459a3290d53652c');
      expect(h(FourSecrets.devMasterKey()), '4934a2bd64717734daa442e1c6e9f54e4bea0fbe9f45ae52708c4a1e3c3db21a');
      expect(FourSecrets.releaseSigner().map((b) => b.toRadixString(16).padLeft(2, '0')).join(), _signer);
      // a real 1.0.2 test code still verifies
      expect(QrPayload.tryParse('BEE1|QWE234RTY567|H|5e1f0c2a|1759741234567|bf495ccc3de2d37f7a177f9e')!.signatureOk, isTrue);
    });
  });

  group('decideLaunch (migration table)', () {
    LaunchAction first({bool unlocked = true, LegacyProbe probe = const LegacyProbe(), ProofCheck proof = ProofCheck.absent, bool strict = false}) => decideLaunch(LaunchInput(
          guardAvailable: true,
          currentHw: 'NEWID2345678',
          legacyUnlocked: unlocked,
          probe: probe,
          proof: proof,
          strictLegacy: strict,
        )).action;
    const copied = LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: false);
    const genuine = LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true);

    test('no native guard → 1.0.2 behaviour', () {
      expect(decideLaunch(const LaunchInput(guardAvailable: false, currentHw: 'X')).action, LaunchAction.legacyMode);
    });
    test('locked install → fresh, never relock', () => expect(first(unlocked: false, probe: copied), LaunchAction.fresh));
    test('genuine unlock with verified proof → migrateVerified', () => expect(first(probe: genuine, proof: ProofCheck.valid), LaunchAction.migrateVerified));
    test('Smart Switch copy (proof + wrapped key, no Keystore key) → relockMoved', () => expect(first(probe: copied), LaunchAction.relockMoved));
    test('copy is caught even if the proof would read as valid', () => expect(first(probe: copied, proof: ProofCheck.valid), LaunchAction.relockMoved));
    test('Keystore key here but proof undecryptable → benefit of the doubt', () => expect(first(probe: genuine, proof: ProofCheck.unreadable), LaunchAction.migrateUnverified));
    const reKeyed = LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true, unwrapFailed: true);
    test('copy already opened with 1.0.2 (new RSA key does not fit the copied wrapped key) + proof unreadable → relockMoved',
        () => expect(first(probe: reKeyed, proof: ProofCheck.unreadable), LaunchAction.relockMoved));
    test('unwrap says "wrong key" but the plugin reads a valid proof → still migrateVerified (proof wins)',
        () => expect(first(probe: reKeyed, proof: ProofCheck.valid), LaunchAction.migrateVerified));
    test('unwrap "wrong key" alone (proof readable for another id) → never relock',
        () => expect(first(probe: reKeyed, proof: ProofCheck.mismatch), LaunchAction.migrateUnverified));
    test('unwrap failure ignored when the probe itself failed',
        () => expect(first(probe: const LegacyProbe(ok: false, proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true, unwrapFailed: true), proof: ProofCheck.unreadable), LaunchAction.migrateUnverified));
    test('probe map: only unwrap == "fail" counts', () {
      expect(LegacyProbe.fromMap({'proofData': true, 'wrappedKey': true, 'pluginAlias': true, 'unwrap': 'fail'}).keyMismatch, isTrue);
      for (final u in ['ok', 'error', 'n/a', null]) {
        expect(LegacyProbe.fromMap({'proofData': true, 'wrappedKey': true, 'pluginAlias': true, 'unwrap': u}).keyMismatch, isFalse);
      }
    });
    test('proof for another id / other HMAC key → benefit of the doubt', () => expect(first(probe: genuine, proof: ProofCheck.mismatch), LaunchAction.migrateUnverified));
    test('no proof at all (old unlock) → migrateUnverified', () => expect(first(), LaunchAction.migrateUnverified));
    test('no proof at all, strict build → relock', () => expect(first(strict: true), LaunchAction.relockMoved));
    test('probe failed → never treated as a copy', () => expect(first(probe: const LegacyProbe(ok: false, proofDataPresent: true, wrappedKeyPresent: true)), LaunchAction.migrateUnverified));
    test('proof data but no wrapped key → not a copy signal', () => expect(first(probe: const LegacyProbe(proofDataPresent: true)), LaunchAction.migrateUnverified));

    SealedRecord rec(String hw, {bool unlocked = true, String? ks = 'kk'}) {
      final body = jsonEncode(BindState(hw: hw, ids: [hw], unlocked: unlocked).toJson());
      return SealedRecord(body, ks, SealedRecord.softwareMac(body, hw));
    }

    LaunchAction later(SealedRecord r, {required String hw, KsStatus ks = KsStatus.ok, bool ksMatch = true, bool? swMatch, bool hwStable = true}) => decideLaunch(LaunchInput(
          guardAvailable: true,
          currentHw: hw,
          hwStable: hwStable,
          record: r,
          recordPresent: true,
          ksStatus: ks,
          ksMacMatches: ksMatch,
          swMacMatches: swMatch ?? constantTimeEq(SealedRecord.softwareMac(r.body, hw), r.swMac),
        )).action;

    test('Keystore verifies → keep (even if the phone id changed)', () {
      expect(later(rec('AAAA2345BBBB'), hw: 'AAAA2345BBBB'), LaunchAction.keep);
      expect(later(rec('AAAA2345BBBB'), hw: 'CCCC2345DDDD'), LaunchAction.keep);
    });
    test('Keystore key lost on the same phone → keep (software seal + same ANDROID_ID)', () {
      expect(later(rec('AAAA2345BBBB'), hw: 'AAAA2345BBBB', ks: KsStatus.missing, ksMatch: false), LaunchAction.keep);
      expect(later(rec('AAAA2345BBBB'), hw: 'AAAA2345BBBB', ks: KsStatus.unavailable, ksMatch: false), LaunchAction.keep);
    });
    test('record copied to another phone → relockMoved', () {
      expect(later(rec('AAAA2345BBBB'), hw: 'CCCC2345DDDD', ks: KsStatus.missing, ksMatch: false), LaunchAction.relockMoved);
    });
    test('copied locked record → fresh (nothing to relock)', () {
      expect(later(rec('AAAA2345BBBB', unlocked: false), hw: 'CCCC2345DDDD', ks: KsStatus.missing, ksMatch: false), LaunchAction.fresh);
    });
    test('edited record on the same phone → relockTampered', () {
      expect(later(rec('AAAA2345BBBB'), hw: 'AAAA2345BBBB', ksMatch: false, swMatch: false), LaunchAction.relockTampered);
    });
    test('software seal is not trusted alone when the id is not ANDROID_ID based', () {
      expect(later(rec('AAAA2345BBBB'), hw: 'AAAA2345BBBB', ks: KsStatus.missing, ksMatch: false, hwStable: false), LaunchAction.relockTampered);
      // …unless the Keystore never worked on that phone
      expect(later(rec('AAAA2345BBBB', ks: null), hw: 'AAAA2345BBBB', ks: KsStatus.unavailable, ksMatch: false, hwStable: false), LaunchAction.keep);
    });
    test('garbage record → relockTampered', () {
      expect(decideLaunch(const LaunchInput(guardAvailable: true, currentHw: 'X', recordPresent: true)).action, LaunchAction.relockTampered);
    });
  });

  group('UnlockStore on simulated phones', () {
    test('genuine 1.0.2 user updates → stays unlocked silently, new id shown, old id codes still accepted', () async {
      final phoneA = FakeGuard('a1a1a1a1a1a1a1a1', probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true));
      final s = await launch(phoneA, unlocked102(), proof: validProof(_oldId));
      expect(s.lastDecision!.action, LaunchAction.migrateVerified);
      expect(s.isUnlocked, isTrue);
      expect(s.notice, isNull);
      final hw = await s.deviceId();
      expect(hw, isNot(_oldId));
      expect(hw, hardwareDeviceId(await phoneA.hardware() as HwInfo));
      expect(s.acceptedIds, containsAll([hw, _oldId]));
      expect(phoneA.hasKey, isTrue);
      // relaunch: verified by the Keystore, nothing changes
      final again = await launch(phoneA, await snapshot());
      expect(again.lastDecision!.action, LaunchAction.keep);
      expect(again.isUnlocked, isTrue);
      expect(await again.deviceId(), hw);
      // a code made for the OLD id (e.g. a 2nd code for an add-on) still works on this phone
      expect((await again.applyPayload(sellerCode(_oldId, nonce: '0badc0de'))).isOk, isTrue);
      expect((await again.applyPayload(sellerCode(hw, nonce: '0badc0df'))).isOk, isTrue);
    });

    test('Smart Switch copy of an unlocked 1.0.2 → relocks on the new phone with a friendly message', () async {
      // Smart Switch copied SharedPreferences (incl. flutter_secure_storage files), but not the Keystore.
      final phoneB = FakeGuard('b2b2b2b2b2b2b2b2', probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: false));
      var proofReads = 0;
      SharedPreferences.setMockInitialValues(unlocked102());
      FlutterSecureStorage.setMockInitialValues({});
      final s = UnlockStore(guard: phoneB, readLegacyProof: () async {
        proofReads++;
        return validProof(_oldId);
      }, enforceIntegrity: true);
      await s.init();
      expect(s.lastDecision!.action, LaunchAction.relockMoved);
      expect(proofReads, 0, reason: 'decided from the probe alone, before secure storage is touched');
      expect(s.isUnlocked, isFalse);
      final id = await s.deviceId();
      expect(s.notice, contains(id));
      expect(s.notice, contains('Bee Seller'));
      // the source phone's code / id no longer opens the copy
      final r = await s.applyPayload(sellerCode(_oldId, nonce: '11112222'));
      expect(r.reason, UnlockFail.otherPhone);
      expect(r.error, contains(id));
      // stays locked on the next launch (the relock is sealed for this phone)
      final again = await launch(phoneB, await snapshot());
      expect(again.isUnlocked, isFalse);
      expect(again.notice, contains(id));
      // a new Bee Seller code for this phone's id unlocks it and clears the message
      expect((await again.applyPayload(sellerCode(id, nonce: '33334444'))).isOk, isTrue);
      expect(again.isUnlocked, isTrue);
      expect(again.notice, isNull);
      expect((await launch(phoneB, await snapshot())).isUnlocked, isTrue);
    });

    test('Smart Switch copy that was already opened with 1.0.2 on the new phone → relocks on update', () async {
      // 1.0.2 touched secure storage on phone B: the plugin made a NEW RSA key, the copied wrapped key does not fit
      // (BadPadding), and the plugin read of the proof throws.
      final phoneB = FakeGuard('b7b7b7b7b7b7b7b7',
          probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true, unwrapFailed: true));
      SharedPreferences.setMockInitialValues(unlocked102());
      FlutterSecureStorage.setMockInitialValues({});
      final s = UnlockStore(guard: phoneB, readLegacyProof: () async => throw Exception('Key mismatch'), enforceIntegrity: true);
      await s.init();
      expect(s.lastDecision!.action, LaunchAction.relockMoved);
      expect(s.isUnlocked, isFalse);
      expect(s.notice, contains(await s.deviceId()));
      expect((await s.applyPayload(sellerCode(_oldId, nonce: '55556666'))).reason, UnlockFail.otherPhone);
    });

    test('genuine phone whose proof read fails for another reason (no key mismatch) → stays unlocked', () async {
      final phone = FakeGuard('a8a8a8a8a8a8a8a8', probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true));
      SharedPreferences.setMockInitialValues(unlocked102());
      FlutterSecureStorage.setMockInitialValues({});
      final s = UnlockStore(guard: phone, readLegacyProof: () async => throw Exception('Keystore busy'), enforceIntegrity: true);
      await s.init();
      expect(s.lastDecision!.action, LaunchAction.migrateUnverified);
      expect(s.isUnlocked, isTrue);
    });

    test('genuine phone: unwrap check wrongly says "fail" but the proof reads fine → stays unlocked (verified)', () async {
      final phone = FakeGuard('a9a9a9a9a9a9a9a9',
          probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true, unwrapFailed: true));
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      expect(s.lastDecision!.action, LaunchAction.migrateVerified);
      expect(s.isUnlocked, isTrue);
    });

    test('1.0.0 user unlocked before resources existed (no proof) → stays unlocked, bound from now on', () async {
      final phone = FakeGuard('c3c3c3c3c3c3c3c3');
      final s = await launch(phone, unlocked102());
      expect(s.lastDecision!.action, LaunchAction.migrateUnverified);
      expect(s.isUnlocked, isTrue);
      final prefs = await snapshot();
      // copying THAT phone's 1.0.3 data to another phone now relocks
      final other = await launch(FakeGuard('d4d4d4d4d4d4d4d4'), prefs);
      expect(other.lastDecision!.action, LaunchAction.relockMoved);
      expect(other.isUnlocked, isFalse);
      // strict builds would have relocked it
      expect((await launch(FakeGuard('c3c3c3c3c3c3c3c3'), unlocked102(), strict: true)).isUnlocked, isFalse);
    });

    test('root user flips "u" to true in the stored record → relocked as tampered', () async {
      final phone = FakeGuard('e5e5e5e5e5e5e5e5');
      final s = await launch(phone, {'four_device_id_v1': _oldId});
      expect(s.isUnlocked, isFalse);
      final prefs = await snapshot();
      final rec = SealedRecord.decode(prefs[BindState.prefsKey] as String)!;
      final hacked = SealedRecord(rec.body.replaceFirst('"u":false', '"u":true'), rec.ksMac, rec.swMac);
      prefs[BindState.prefsKey] = hacked.encode();
      prefs['four_highschool_unlocked'] = true; // the old flag is not trusted any more
      final t = await launch(phone, prefs);
      expect(t.lastDecision!.action, LaunchAction.relockTampered);
      expect(t.isUnlocked, isFalse);
    });

    test('Keystore key lost on the same phone → still unlocked, key re-created', () async {
      final phone = FakeGuard('f6f6f6f6f6f6f6f6');
      await launch(phone, unlocked102(), proof: validProof(_oldId));
      final prefs = await snapshot();
      phone.loseKeystore();
      final s = await launch(phone, prefs);
      expect(s.lastDecision!.action, LaunchAction.keep);
      expect(s.isUnlocked, isTrue);
      expect(phone.hasKey, isTrue);
      expect((await launch(phone, await snapshot())).lastDecision!.why, 'keystore ok');
    });

    test('OS update changes the model string → Keystore proves same phone, both ids accepted', () async {
      final phone = FakeGuard('a7a7a7a7a7a7a7a7');
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      final before = await s.deviceId();
      phone.model = 'SM-A145F/DS';
      final s2 = await launch(phone, await snapshot());
      expect(s2.isUnlocked, isTrue);
      expect(await s2.deviceId(), isNot(before));
      expect(s2.acceptedIds, containsAll([before, await s2.deviceId(), _oldId]));
    });

    test('Keystore not working at all on a phone → software seal + ANDROID_ID keep it unlocked', () async {
      final phone = FakeGuard('b8b8b8b8b8b8b8b8')..keystoreBroken = true;
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      expect(s.isUnlocked, isTrue);
      final again = await launch(phone, await snapshot());
      expect(again.isUnlocked, isTrue);
      final moved = await launch(FakeGuard('c9c9c9c9c9c9c9c9')..keystoreBroken = true, await snapshot());
      expect(moved.lastDecision!.action, LaunchAction.relockMoved);
      expect(moved.isUnlocked, isFalse);
    });

    test('locked 1.0.2 install: a code already bought for the old id still works once', () async {
      final phone = FakeGuard('d0d0d0d0d0d0d0d0');
      final s = await launch(phone, {'four_device_id_v1': _oldId});
      expect(s.lastDecision!.action, LaunchAction.fresh);
      expect(s.notice, isNull);
      expect((await s.applyPayload(sellerCode(_oldId))).isOk, isTrue);
      expect((await s.applyPayload(sellerCode(_oldId))).reason, UnlockFail.alreadyUsed);
    });

    test('fresh 1.0.3 install shows the hardware id and unlocks with a code for it', () async {
      final phone = FakeGuard('e1e1e1e1e1e1e1e1');
      final s = await launch(phone, {});
      final id = await s.deviceId();
      expect(id, hardwareDeviceId(await phone.hardware() as HwInfo));
      expect(s.acceptedIds, [id]);
      expect((await s.applyPayload(sellerCode('OTHER2345678'))).reason, UnlockFail.otherPhone);
      expect((await s.applyPayload(sellerCode(id.toLowerCase()))).isOk, isTrue);
      // reinstall on the same phone gives the same id (ANDROID_ID survives reinstall) → same code works again
      final re = await launch(FakeGuard('e1e1e1e1e1e1e1e1'), {});
      expect(await re.deviceId(), id);
    });

    test('repackaged APK (other signing key) or debuggable build → cannot be unlocked', () async {
      final fake = await launch(FakeGuard('a2a2a2a2a2a2a2a2', signer: '00' * 32), unlocked102(), proof: validProof(_oldId));
      expect(fake.isUnlocked, isFalse);
      expect(fake.notice, contains('changed'));
      expect((await fake.applyPayload(sellerCode(await fake.deviceId()))).reason, UnlockFail.blocked);
      final dbg = await launch(FakeGuard('a3a3a3a3a3a3a3a3', env: const EnvReport(debuggable: true)), unlocked102());
      expect(dbg.isUnlocked, isFalse);
    });

    test('Frida / Xposed blocks only this session; the unlock itself is kept', () async {
      final phone = FakeGuard('a4a4a4a4a4a4a4a4', env: const EnvReport(hookFramework: true));
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      expect(s.isUnlocked, isFalse);
      expect(s.notice, contains('Frida'));
      phone.env = const EnvReport(rooted: true, emulator: true); // root / emulator alone are allowed
      final clean = await launch(phone, await snapshot());
      expect(clean.isUnlocked, isTrue);
    });

    test('resource gate keeps strong mode with the 1.0.x proof made for the old id', () async {
      final phone = FakeGuard('a5a5a5a5a5a5a5a5', probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: true));
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      final g = ResourceGate.install(s);
      expect(await g.mode(), GateMode.strong);
      expect(await g.deviceKey(), isNotNull);
      expect(await g.masterKey(1), isNotNull);
    });

    test('relocked copy: resources are locked too', () async {
      final phone = FakeGuard('a6a6a6a6a6a6a6a6', probe: const LegacyProbe(proofDataPresent: true, wrappedKeyPresent: true, pluginAliasPresent: false));
      final s = await launch(phone, unlocked102(), proof: validProof(_oldId));
      final g = ResourceGate.install(s);
      expect(await g.mode(), GateMode.locked);
      expect(await g.masterKey(1), isNull);
    });
  });
}
