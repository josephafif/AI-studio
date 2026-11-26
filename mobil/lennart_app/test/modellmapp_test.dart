// Kontrollerar en modellmapp för datorversionen med appens egen kod och motor:
//   LENNART_MODELLER=<mapp> LD_LIBRARY_PATH=<mapp med liblmengine.so> flutter test test/modellmapp_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lennart_app/core/catalog.dart';
import 'package:lennart_app/core/engine.dart';
import 'package:lennart_app/core/tokenizer.dart';

void main() {
  final dir = Platform.environment['LENNART_MODELLER'];
  test('alla modeller i mappen läses in och svarar', () async {
    final models = await Catalog.scanModels(Directory(dir!));
    models.sort((a, b) => a.params != b.params ? a.params.compareTo(b.params) : a.steps.compareTo(b.steps));
    // ignore: avoid_print
    print('${models.length} modeller: ${models.map((m) => m.name).join(', ')}');
    expect(models, isNotEmpty);
    final engine = LennartEngine();
    for (final m in models) {
      await engine.load(m.id, '$dir/${m.id}.lmod', '$dir/${m.id}.tok.json');
      final b = StringBuffer();
      await for (final e in engine.generate([ChatTurn(true, 'Hej! Vem är du?')],
          const GenSettings(temperature: 0, maxTokens: 30, effort: Effort.snabb))) {
        if (e is GenToken) b.write(e.text);
      }
      // ignore: avoid_print
      print('[${m.name}] ${b.toString().trim()}');
      expect(b.toString().trim(), isNotEmpty);
    }
  }, skip: dir == null, timeout: const Timeout(Duration(minutes: 10)));
}
