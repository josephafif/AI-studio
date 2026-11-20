// dart run tool/package_check.dart <paket.lennart> <tom mapp>
import 'dart:io';
import '../lib/core/package.dart';
import '../lib/core/engine.dart';
import '../lib/core/tokenizer.dart';

Future<void> main(List<String> a) async {
  final sw = Stopwatch()..start();
  final r = await installPackage(a[0], a[1]);
  final id = r.entry['id'];
  stdout.writeln('Installerad: ${r.entry['name']} ($id) på ${sw.elapsedMilliseconds} ms');
  final e = LennartEngine();
  await e.load(id, '${a[1]}/$id.lmod', '${a[1]}/$id.tok.json');
  final b = StringBuffer();
  await for (final ev in e.generate([const ChatTurn(true, 'Vad är en brandvägg?')], const GenSettings(temperature: 0, maxTokens: 60, topK: 0))) {
    if (ev is GenToken) b.write(ev.text);
  }
  stdout.writeln('Svar: ${b.toString().trim()}');
  try {
    await installPackage('${a[1]}/$id.tok.json', a[1]);
  } on FormatException catch (x) {
    stdout.writeln('Fel fil avvisas: ${x.message}');
  }
  exit(0);
}
