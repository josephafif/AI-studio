// Självtest utan gränssnitt: Lennart.exe --sjalvtest [resultatfil]
//
// Läser in varje förinstallerad modell, ställer en fråga och skriver svaren till en textfil. Används i
// byggflödet på Windows (GitHub Actions) för att bevisa att motorn, DLL:en och modellerna fungerar
// på riktig Windows innan programmet skickas ut. Går också att köra själv om något krånglar.
import 'dart:io';

import '../agent/agent.dart';
import '../agent/verktyg.dart';
import 'catalog.dart';
import 'engine.dart';
import 'tokenizer.dart';

Future<void> runSelfTest(List<String> args) async {
  final i = args.indexOf('--sjalvtest');
  final outPath = i >= 0 && i + 1 < args.length ? args[i + 1] : 'sjalvtest.txt';
  final log = StringBuffer();
  void line(String s) => log.writeln(s);
  var ok = true;
  try {
    line('Lennart självtest ${DateTime.now().toIso8601String()}');
    line('Program: ${Platform.resolvedExecutable}');
    line('System: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}, ${Platform.numberOfProcessors} kärnor');
    final catalog = await Catalog.open();
    line('Modellmapp: ${catalog.bundled?.path}');
    line('Modeller: ${catalog.models.map((m) => m.name).join(', ')}');
    if (catalog.models.isEmpty) throw StateError('inga modeller hittades');
    final engine = LennartEngine();
    for (final m in catalog.models) {
      final sw = Stopwatch()..start();
      await engine.load(m.id, catalog.modelPath(m), catalog.tokenizerPath(m));
      final loadMs = sw.elapsedMilliseconds;
      for (final effort in [Effort.snabb, Effort.djupPlus]) {
        final buf = StringBuffer();
        GenDone? done;
        await for (final e in engine.generate([
          ChatTurn(true, 'Hej! Vem är du?'),
        ], GenSettings(temperature: effort == Effort.snabb ? 0 : 0.7, maxTokens: 40, topK: 40, effort: effort))) {
          switch (e) {
            case GenToken(:final text):
              buf.write(text);
            case GenSegment(:final text):
              buf.write(text);
            case GenChosen(:final text):
              buf.write(text);
            case GenError(:final message):
              ok = false;
              buf.write('FEL: $message');
            case GenDone():
              done = e;
            default:
          }
        }
        final svar = buf.toString().trim();
        if (svar.isEmpty || done == null) ok = false;
        line(
          '[${m.name} · ${effort.label} · inläst ${loadMs} ms · ${done?.tokens} tokens · '
          '${done?.tokensPerSecond.toStringAsFixed(1)} tok/s] $svar',
        );
      }
    }
    // Agentens verktyg på riktig Windows (sökvägar, filer, räknare)
    final tmp = await Directory.systemTemp.createTemp('lennart_sjalvtest');
    await File('${tmp.path}${Platform.pathSeparator}anteckning.txt').writeAsString('Köp kaffe.\nRing banken.');
    final agent = Agent(
      verktyg: standardVerktyg(),
      miljo: AgentMiljo(arbetsmapp: tmp),
      generera: (_) async => '',
      godkann: (_, __) async => true,
    );
    for (final call in [
      VerktygsAnrop('raknare', {'uttryck': '12*7'}, '', ''),
      VerktygsAnrop('sok_i_filer', {'text': 'banken'}, '', ''),
      VerktygsAnrop('las_fil', {'fil': '../utanfor.txt'}, '', ''),
    ]) {
      final r = await agent.korAnrop(call);
      line('[verktyg ${call.namn}] ${r.fel ? 'fel: ' : ''}${r.resultat}');
    }
    final r1 = await agent.korAnrop(VerktygsAnrop('raknare', {'uttryck': '12*7'}, '', ''));
    final r3 = await agent.korAnrop(VerktygsAnrop('las_fil', {'fil': '../utanfor.txt'}, '', ''));
    if (r1.resultat != '84' || !r3.fel) ok = false;
    await tmp.delete(recursive: true);
  } catch (e, st) {
    ok = false;
    line('FEL: $e\n$st');
  }
  line(ok ? 'RESULTAT: OK' : 'RESULTAT: MISSLYCKADES');
  await File(outPath).writeAsString(log.toString());
}
