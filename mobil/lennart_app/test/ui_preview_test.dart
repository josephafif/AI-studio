// Skärmdumpar av gränssnittet (utan telefon). Körs bara på begäran:
//   LENNART_PREVIEW=1 flutter test test/ui_preview_test.dart --update-goldens
// Bilderna hamnar i test/preview/ (ignoreras av git).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lennart_app/core/catalog.dart';
import 'package:lennart_app/core/chats.dart';
import 'package:lennart_app/core/engine.dart';
import 'package:lennart_app/core/prefs.dart';
import 'package:lennart_app/core/tokenizer.dart';
import 'package:lennart_app/ui/ascii.dart';
import 'package:lennart_app/ui/chat_screen.dart';
import 'package:lennart_app/ui/theme.dart';

/// Låtsasmotor som spelar upp ett tänkande med tre utkast.
class _FakeEngine extends LennartEngine {
  @override
  Future<void> load(String id, String modelPath, String tokenizerPath) async {}

  @override
  Stream<GenEvent> generate(List<ChatTurn> turns, GenSettings s) async* {
    // Agentläge: frågan om 12 gånger 7 besvaras med ett verktygsanrop, och resultatet med ett svar.
    if (turns.last.text.startsWith('<resultat')) {
      for (final w in '12 gånger 7 är 84. Räknaren håller med mig, så det är nog rätt.'.split(' ')) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        yield GenToken('$w ');
      }
      yield GenDone(16, 0.8, 30, 1, score: -0.1);
      return;
    }
    if (turns.last.text.contains('12 gånger 7')) {
      yield GenToken('<verktyg namn="raknare">{"uttryck": "12*7"}</verktyg>');
      yield GenDone(14, 0.5, 12, 1, score: -0.1);
      return;
    }
    if (s.effort.sentenceWise) {
      const meningar = [
        ['Ett starkt lösenord är långt och unikt för varje tjänst.', 'Ett starkt lösenord är långt från din lokala enhet.',
          'Ett starkt lösenord är långt och unikt för varje tjänst.', 'Ett starkt lösenord är långt och unikt för varje tjänst.'],
        [' Använd gärna en lösenfras av flera slumpmässiga ord.', ' En lösenfras av flera slumpmässiga ord är lätt att minnas.',
          ' Byt lösenord varje månad.', ' En lösenfras av flera slumpmässiga ord är lätt att minnas.', ' Ha samma lösenord överallt.'],
        [' Låt en lösenordshanterare hålla koll.', ' Låt en lösenordshanterare hålla koll.', ' Låt en lösenordshanterare hålla koll.'],
      ];
      const valda = [0, 1, 0];
      var i = 0;
      for (var g = 0; g < meningar.length; g++) {
        final start = i;
        for (final m in meningar[g]) {
          for (final w in m.split(' ')) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            yield GenDraft(i, 20, '$w ', segment: g);
          }
          yield GenDraftEnd(i, -0.3, false);
          i++;
        }
        yield GenSegment(g, start + valda[g], meningar[g][valda[g]]);
      }
      yield GenDone(140, 9.1, 20, i, score: -0.2);
      return;
    }
    const drafts = [
      'Ett starkt lösenord är långt, gärna minst 14 tecken, och unikt för varje tjänst.',
      'Ett starkt lösenord är långt från din lokala enhet och skapar en grupp av',
      'Ett starkt lösenord är långt, gärna minst 14 tecken, och unikt för varje tjänst. En lösenfras av flera slumpmässiga ord är både stark och lätt att minnas. Använd en lösenordshanterare.',
    ];
    final scores = [-0.38, -99.0, -0.02];
    for (var i = 0; i < 3; i++) {
      for (final w in drafts[i].split(' ')) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        yield GenDraft(i, 3, '$w ');
      }
      yield GenDraftEnd(i, scores[i], i == 1);
    }
    yield GenChosen(2, drafts[2]);
    yield GenDone(96, 6.4, 20, 3);
  }
}

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  final flutter = Platform.environment['FLUTTER_ROOT'] ?? '/root/tools/flutter';
  final mf = '$flutter/bin/cache/artifacts/material_fonts';
  await load('Roboto', ['$mf/Roboto-Regular.ttf', '$mf/Roboto-Medium.ttf', '$mf/Roboto-Bold.ttf']);
  await load('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
  await load('monospace', [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
  ]);
  await load('serif', ['/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf']);
}

ModelInfo _m(String id, String name, int params, double hue) => ModelInfo.fromJson({
      'id': id, 'name': name, 'description': 'Svensk AI-assistent', 'params': params, 'steps': 32408,
      'context': 512, 'vocab': 32768, 'quant': 'int8', 'temperature': 0.7, 'max_tokens': 150, 'top_k': 40, 'hue': hue,
    });

void main() {
  final enabled = Platform.environment['LENNART_PREVIEW'] == '1';

  testWidgets('klotet i rörelse', (tester) async {
    await _loadFonts();
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const Scaffold(body: Center(child: AsciiSphere(size: 300, color: Color(0xFFB57BFF)))),
    ));
    for (var f = 0; f < 3; f++) {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(AsciiSphere), matchesGoldenFile('preview/klot-$f.png'));
    }
    await tester.pumpWidget(const SizedBox());
  }, skip: !enabled);

  testWidgets('telefon agent', (tester) async {
    debugDisableShadows = false;
    await _loadFonts();
    tester.view.physicalSize = const Size(412 * 2.5, 900 * 2.5);
    tester.view.devicePixelRatio = 2.5;
    Prefs.agent = true;
    final mapp = Directory.systemTemp.createTempSync('lennart_telefon');
    Prefs.arbetsmapp = mapp.path;
    final catalog = Catalog.preview([_m('lennart-3-4', 'Lennart 3.4', 298407936, 300)]);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: ChatScreen(catalog: catalog, store: ChatStore(), engine: _FakeEngine()),
    ));
    Future<void> send(String t) async {
      await tester.enterText(find.byType(TextField), t);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      // Verktygen gör riktig filhantering – låt den bli klar innan nästa kommando.
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 30));
        if (i > 3 && find.byIcon(Icons.arrow_upward_rounded).evaluate().isNotEmpty) break;
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await send('/anteckna Köp kaffe och ring banken');
    await send('/anteckna Byt lösenord på mejlen');
    await send('/dagar jul');
    await send('/räkna 1299*0,8');
    await send('/anteckningar');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/t-agent-mork.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    mapp.deleteSync(recursive: true);
    Prefs.agent = false;
    Prefs.arbetsmapp = null;
    debugDisableShadows = true;
  }, skip: !enabled);

  for (final dark in [true, false]) {
    testWidgets('dator ${dark ? 'mörk' : 'ljus'}', (tester) async {
      debugDisableShadows = false;
      await _loadFonts();
      tester.view.physicalSize = const Size(1280 * 1.25, 820 * 1.25);
      tester.view.devicePixelRatio = 1.25;
      Prefs.effort = Effort.snabb;
      Prefs.agent = true;
      Prefs.arbetsmapp = Directory.systemTemp.createTempSync('lennart_preview').path;
      final catalog = Catalog.preview([
        _m('lennart', 'Lennart', 995544, 152),
        _m('lennart-2', 'Lennart 2', 8130624, 192),
        _m('lennart-3', 'Lennart 3', 298407936, 262),
        _m('lennart-3-1', 'Lennart 3.1', 298407936, 322),
        _m('lennart-3-2', 'Lennart 3.2', 298407936, 20),
        _m('lennart-3-3', 'Lennart 3.3', 298407936, 60),
        _m('lennart-3-4', 'Lennart 3.4', 298407936, 300),
      ]);
      final store = ChatStore();
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(dark ? Brightness.dark : Brightness.light),
        home: ChatScreen(catalog: catalog, store: store, engine: _FakeEngine()),
      ));
      final mode = dark ? 'mork' : 'ljus';
      Future<void> wait(int n) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await wait(12);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/d1-start-$mode.png'));
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await wait(10);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/d2-modeller-$mode.png'));
      await tester.tapAt(const Offset(40, 40));
      await wait(10);
      await tester.enterText(find.byType(TextField), 'Vad är 12 gånger 7?');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await wait(10);
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/d3-agent-$mode.png'));
      await tester.tap(find.byIcon(Icons.add_rounded));
      await wait(8);
      await tester.tap(find.text('Agent och verktyg'));
      await wait(10);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/d4-agentinst-$mode.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      Prefs.agent = false;
      Prefs.effort = Effort.medel;
      debugDisableShadows = true;
    }, skip: !enabled);

    testWidgets('förhandsvisning ${dark ? 'mörk' : 'ljus'}', (tester) async {
      debugDisableShadows = false;
      await _loadFonts();
      tester.view.physicalSize = const Size(412 * 2.5, 900 * 2.5);
      tester.view.devicePixelRatio = 2.5;
      final catalog = Catalog.preview([
        _m('lennart', 'Lennart', 995544, 152),
        _m('lennart-2', 'Lennart 2', 8130624, 192),
        _m('lennart-3-4', 'Lennart 3.4', 298407936, 300),
      ]);
      final app = MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(dark ? Brightness.dark : Brightness.light),
        home: ChatScreen(catalog: catalog, store: ChatStore(), engine: _FakeEngine()),
      );
      await tester.pumpWidget(app);
      final mode = dark ? 'mork' : 'ljus';
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/1-start-$mode.png'));

      // Modellväljaren
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/2-modeller-$mode.png'));
      await tester.tapAt(const Offset(200, 40));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Fråga och tänkande
      await tester.enterText(find.byType(TextField), 'Hur skapar jag ett starkt lösenord?');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/3-tanker-$mode.png'));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/4-svar-$mode.png'));
      await tester.tap(find.textContaining('Tänkte i'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/5-utkast-$mode.png'));

      // Djup+: välj nivån i modellväljaren och fråga igen
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text('Djup+'));
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/6-djupplus-val-$mode.png'));
      await tester.tapAt(const Offset(200, 40));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byIcon(Icons.edit_square).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'Hur skapar jag ett starkt lösenord?');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/7-djupplus-tanker-$mode.png'));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.textContaining('Tänkte i'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/8-djupplus-svar-$mode.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      debugDisableShadows = true;
    }, skip: !enabled);
  }
}
