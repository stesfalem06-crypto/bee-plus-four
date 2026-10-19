import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'device_guard.dart';

const _ink = Color(0xFF3E3129);
const _cream = Color(0xFFFFFCF7);
const _coral = Color(0xFFC24E32);
const _peach = Color(0xFFFFC9A3);

TextStyle _ts(double size, FontWeight w, [Color c = _ink]) =>
    TextStyle(fontFamily: 'HighNunito', fontSize: size, fontWeight: w, color: c, height: 1.3);

/// Full-screen block shown when STRICT mode detects root, hooking, emulator, a virtual container,
/// or a known APK-dissecting / patching tool. The app content never opens behind this page.
class StrictBlockScreen extends StatelessWidget {
  const StrictBlockScreen({
    super.key,
    required this.env,
    required this.onUninstallFour,
    required this.onCheckAgain,
    this.onUninstallTool,
  });

  final EnvReport env;
  final VoidCallback onUninstallFour;
  final VoidCallback onCheckAgain;
  final void Function(RiskyApp app)? onUninstallTool;

  String get _title {
    if (env.hookFramework || env.debuggerAttached) return 'A hacking tool is running';
    if (env.riskyApps.isNotEmpty) return 'A rooting or hacking tool is installed';
    if (env.rooted) return 'This phone is rooted';
    if (env.emulator) return 'Four cannot run on an emulator';
    if (env.virtualContainer) return 'Four cannot run inside a clone app';
    if (env.debuggable) return 'This copy of Four was changed';
    return 'Four cannot run on this phone';
  }

  String get _body {
    final buf = StringBuffer();
    buf.writeln(
      'This phone has a rooting or hacking tool (or is an emulator / clone app), so Four cannot open.',
    );
    buf.writeln();
    if (env.riskyApps.isNotEmpty) {
      final names = env.riskyApps.map((a) => a.label.isNotEmpty ? a.label : a.packageName).toSet().take(4);
      buf.writeln('Tool found: ${names.join(', ')}.');
      buf.writeln();
    }
    buf.writeln('Uninstall Four, then remove the tool. After that you can install Four again from your Bee seller.');
    return buf.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final tools = env.riskyApps;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: ColoredBox(
        color: _cream,
        child: SafeArea(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('4', textAlign: TextAlign.center, style: _ts(48, FontWeight.w900, _coral)),
                  const SizedBox(height: 18),
                  Text(_title, textAlign: TextAlign.center, style: _ts(22, FontWeight.w900)),
                  const SizedBox(height: 14),
                  Text(_body, textAlign: TextAlign.center, style: _ts(15, FontWeight.w700)),
                  const Spacer(),
                  _BigButton(label: 'Uninstall Four', color: _coral, onTap: onUninstallFour),
                  if (tools.isNotEmpty && onUninstallTool != null) ...[
                    const SizedBox(height: 12),
                    _BigButton(
                      label: tools.length == 1
                          ? 'Uninstall ${tools.first.label.isNotEmpty ? tools.first.label : 'the tool'}'
                          : 'Uninstall ${tools.first.label.isNotEmpty ? tools.first.label : 'tool'}…',
                      color: _ink,
                      onTap: () => onUninstallTool!(tools.first),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _BigButton(label: 'Check again', color: _peach, ink: _ink, onTap: onCheckAgain),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.color, required this.onTap, this.ink = const Color(0xFFFFFFFF)});
  final String label;
  final Color color;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.all(Radius.circular(999))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          child: Text(label, textAlign: TextAlign.center, style: _ts(16, FontWeight.w900, ink)),
        ),
      ),
    );
  }
}
