// Kör appens motor (isolat + FFI + tokenizer) utan Flutter: dart run tool/engine_check.dart <exportmapp>
import 'dart:io';
import '../lib/core/engine.dart';
import '../lib/core/tokenizer.dart';

Future<void> main(List<String> a) async {
  final dir = a[0];
  final engine = LennartEngine();
  for (final id in ['lennart', 'lennart-2', 'lennart-3', 'lennart-3-1']) {
    final sw = Stopwatch()..start();
    await engine.load(id, '$dir/$id.lmod', '$dir/$id.tok.json');
    final loadMs = sw.elapsedMilliseconds;
    for (final q in ['Hej! Vem är du?', 'Vad är nätfiske?']) {
      final buf = StringBuffer();
      GenDone? done;
      await for (final e in engine.generate([ChatTurn(true, q)], const GenSettings(temperature: 0, maxTokens: 70, topK: 0))) {
        if (e is GenToken) buf.write(e.text);
        if (e is GenDone) done = e;
        if (e is GenError) buf.write('FEL: ${e.message}');
      }
      stdout.writeln('[$id, inläst på $loadMs ms] F: $q\n  S: ${buf.toString().trim()}\n  (${done?.tokens} tokens, ${done?.tokensPerSecond.toStringAsFixed(1)} tok/s)');
    }
  }
  // stopp mitt i
  final s = engine.generate([ChatTurn(true, 'Berätta om Sverige.')], const GenSettings(temperature: 0.7, maxTokens: 300, topK: 40));
  var n = 0;
  await for (final e in s) {
    if (e is GenToken && ++n == 5) engine.stop();
    if (e is GenDone) stdout.writeln('Stopp efter 5 bitar: ${e.tokens} tokens genererades');
  }
  exit(0);
}
