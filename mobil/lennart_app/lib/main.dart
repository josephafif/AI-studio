import 'package:flutter/material.dart';

import 'core/catalog.dart';
import 'core/chats.dart';
import 'core/prefs.dart';
import 'ui/ascii.dart';
import 'ui/chat_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appearance.load();
  await Prefs.load();
  runApp(const LennartApp());
}

class LennartApp extends StatelessWidget {
  const LennartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appearance,
      builder: (_, mode, __) => MaterialApp(
        title: 'Lennart',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: const _Startup(),
      ),
    );
  }
}

/// Första start: modellfilerna packas upp till appens lagring. Därefter direkt till chatten.
class _Startup extends StatefulWidget {
  const _Startup();
  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> {
  Catalog? _catalog;
  ChatStore? _store;
  String _label = 'Startar …';
  double _progress = 0;
  bool _setup = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final catalog = await Catalog.open();
      final store = ChatStore();
      await store.open();
      if (await catalog.needsSetup()) {
        setState(() => _setup = true);
        await catalog.setup((label, done) => setState(() {
              _label = label;
              _progress = done;
            }));
      }
      setState(() {
        _catalog = catalog;
        _store = store;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_catalog != null) return ChatScreen(catalog: _catalog!, store: _store!);
    final c = context.c;
    return Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: AsciiRain(color: Palette.green)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const AsciiSphere(size: 240, color: Palette.green, thinking: true),
              ScrambleText('lennart_', style: mono.copyWith(fontSize: 34, fontWeight: FontWeight.w800, color: c.text)),
              const SizedBox(height: 18),
              if (_error != null)
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger))
              else if (_setup) ...[
                BrailleSpinner(color: c.accent, text: 'förbereder $_label'),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: _progress, minHeight: 6, backgroundColor: c.stroke, color: c.accent),
                ),
                const SizedBox(height: 10),
                Text('// bara första gången – modellerna packas upp till telefonen',
                    textAlign: TextAlign.center, style: mono.copyWith(color: c.muted, fontSize: 11)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}
