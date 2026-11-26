import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lennart_app/core/catalog.dart';

void main() {
  test('modeller utan Lennarts extra fält (t.ex. LFM2.5) går att läsa', () {
    final lfm = ModelInfo.fromJson({
      'id': 'lfm2-5-350m',
      'name': 'LFM2.5 350M',
      'params': 354483968,
      'context': 2048,
      'vocab': 65536,
      'quant': 'int8-g64',
      'temperature': 0.3,
      'max_tokens': 300,
      'top_k': 40,
      'badge': 'LFM',
    }, builtin: false);
    expect(lfm.steps, 0);
    expect(lfm.badge, 'LFM');
    expect(lfm.temperature, 0.3);
    final minimal = ModelInfo.fromJson({'id': 'x'});
    expect(minimal.name, 'x');
    expect(minimal.maxTokens, 200);
    expect(minimal.badge, '1');
  });

  test('scanModels hoppar över trasiga beskrivningar och läser resten', () async {
    final d = Directory.systemTemp.createTempSync('lennart_katalog');
    File('${d.path}/lfm2-5-350m.modell.json').writeAsStringSync(jsonEncode({'id': 'lfm2-5-350m', 'name': 'LFM2.5 350M', 'params': 354483968}));
    File('${d.path}/lfm2-5-350m.lmod').writeAsStringSync('x');
    File('${d.path}/trasig.modell.json').writeAsStringSync('{inte json');
    File('${d.path}/utan-id.modell.json').writeAsStringSync(jsonEncode({'name': 'Utan id'}));
    final m = await Catalog.scanModels(d);
    expect(m.map((e) => e.id), ['lfm2-5-350m']);
    d.deleteSync(recursive: true);
  });
}
