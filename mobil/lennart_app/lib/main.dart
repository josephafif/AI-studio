import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/catalog.dart';
import 'core/chats.dart';
import 'ui/aurora.dart';
import 'ui/chat_screen.dart';
import 'ui/orb.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Palette.bg,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const LennartApp());
}

class LennartApp extends StatelessWidget {
  const LennartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lennart',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Startup(),
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
    return Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: Aurora(accent: Palette.green)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Orb(size: 190, color: Palette.green, thinking: true),
              const SizedBox(height: 12),
              const Text('Lennart', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1)),
              const SizedBox(height: 18),
              if (_error != null)
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Palette.danger))
              else if (_setup) ...[
                Text('Förbereder $_label', style: const TextStyle(color: Palette.muted)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                      value: _progress, minHeight: 6, backgroundColor: Palette.stroke, color: Palette.green),
                ),
                const SizedBox(height: 10),
                const Text('Bara första gången – modellerna packas upp till telefonen.',
                    textAlign: TextAlign.center, style: TextStyle(color: Palette.muted, fontSize: 12)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}
