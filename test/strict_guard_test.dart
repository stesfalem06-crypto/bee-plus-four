import 'package:flutter_test/flutter_test.dart';
import 'package:high/licensing/device_guard.dart';
import 'package:high/licensing/strict_block_screen.dart';
import 'package:flutter/widgets.dart';

void main() {
  group('EnvReport STRICT', () {
    test('clean report is not blocked', () {
      expect(const EnvReport().strictBlock, isFalse);
      expect(const EnvReport().hostile, isFalse);
    });

    test('each signal alone is enough', () {
      expect(const EnvReport(rooted: true).strictBlock, isTrue);
      expect(const EnvReport(emulator: true).strictBlock, isTrue);
      expect(const EnvReport(virtualContainer: true).strictBlock, isTrue);
      expect(const EnvReport(hookFramework: true).strictBlock, isTrue);
      expect(const EnvReport(debuggerAttached: true).strictBlock, isTrue);
      expect(const EnvReport(debuggable: true).strictBlock, isTrue);
      expect(const EnvReport(riskyApps: [RiskyApp('bin.mt.plus', 'MT Manager')]).strictBlock, isTrue);
    });

    test('fromMap parses risky apps and reasons', () {
      final e = EnvReport.fromMap({
        'rooted': true,
        'hook': false,
        'emulator': false,
        'virtual': true,
        'debuggable': false,
        'debugger': false,
        'reasons': ['root:path:/sbin/su', 'virtual:/parallel'],
        'riskyApps': [
          {'pkg': 'bin.mt.plus', 'label': 'MT Manager'},
        ],
      });
      expect(e.rooted, isTrue);
      expect(e.virtualContainer, isTrue);
      expect(e.riskyApps.single.packageName, 'bin.mt.plus');
      expect(e.reasons, contains('root:path:/sbin/su'));
      expect(e.strictBlock, isTrue);
    });
  });

  group('StrictBlockScreen copy', () {
    testWidgets('shows Uninstall Four and Check again; never says offline', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StrictBlockScreen(
            env: const EnvReport(rooted: true, riskyApps: [RiskyApp('bin.mt.plus', 'MT Manager')]),
            onUninstallFour: () {},
            onCheckAgain: () {},
            onUninstallTool: (_) {},
          ),
        ),
      );
      expect(find.text('Uninstall Four'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.textContaining('Uninstall MT Manager'), findsOneWidget);
      // No forbidden word
      final texts = find.byType(Text);
      for (final e in texts.evaluate()) {
        final t = e.widget as Text;
        final data = t.data ?? '';
        expect(data.toLowerCase().contains('offline'), isFalse, reason: data);
      }
    });
  });
}
