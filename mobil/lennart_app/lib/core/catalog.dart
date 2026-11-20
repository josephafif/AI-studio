// Modellerna som följer med appen (assets/models/manifest.json) och uppackningen vid första start.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ModelInfo {
  final String id, name, description, quant;
  final int params, steps, context, vocab, maxTokens, topK;
  final double temperature;
  final int index;

  ModelInfo.fromJson(Map<String, dynamic> j, this.index)
      : id = j['id'] as String,
        name = j['name'] as String,
        description = (j['description'] as String?) ?? '',
        quant = j['quant'] as String,
        params = j['params'] as int,
        steps = j['steps'] as int,
        context = j['context'] as int,
        vocab = j['vocab'] as int,
        maxTokens = j['max_tokens'] as int,
        topK = j['top_k'] as int,
        temperature = (j['temperature'] as num).toDouble();

  String get paramsLabel => params >= 1e6 ? '${(params / 1e6).round()} M' : '${(params / 1e3).round()} k';
}

class Catalog {
  static const _channel = MethodChannel('lennart/assets');
  final List<ModelInfo> models;
  final Directory dir;
  Catalog._(this.models, this.dir);

  static Future<Catalog> open() async {
    final manifest = jsonDecode(await rootBundle.loadString('assets/models/manifest.json')) as Map<String, dynamic>;
    final list = manifest['models'] as List;
    final models = [for (var i = 0; i < list.length; i++) ModelInfo.fromJson(list[i] as Map<String, dynamic>, i)];
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/models');
    await dir.create(recursive: true);
    return Catalog._(models, dir);
  }

  String modelPath(ModelInfo m) => '${dir.path}/${m.id}.lmod';
  String tokenizerPath(ModelInfo m) => '${dir.path}/${m.id}.tok.json';

  /// Filer som ska finnas på disken, med storleken i appens tillgångar.
  List<(String asset, String dest)> _files() => [
        for (final m in models) ...[
          ('assets/models/${m.id}.lmod', modelPath(m)),
          ('assets/models/${m.id}.tok.json', tokenizerPath(m)),
        ]
      ];

  Future<bool> needsSetup() async {
    final marker = File('${dir.path}/.klar-${models.map((m) => '${m.id}-${m.steps}').join('_')}');
    return !await marker.exists();
  }

  /// Packar upp modellerna. [progress] får (modellnamn, andel klar 0–1).
  Future<void> setup(void Function(String label, double done) progress) async {
    final files = _files();
    for (var i = 0; i < files.length; i++) {
      final (asset, dest) = files[i];
      final model = models[i ~/ 2];
      progress(model.name, i / files.length);
      try {
        await _channel.invokeMethod('extract', {'asset': asset, 'dest': dest});
      } on MissingPluginException {
        // Utan Android-delen (t.ex. förhandsvisning på datorn): läs tillgången direkt.
        final data = await rootBundle.load(asset);
        await File(dest).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
    }
    progress('Klart', 1);
    await File('${dir.path}/.klar-${models.map((m) => '${m.id}-${m.steps}').join('_')}').writeAsString('ok');
  }
}
