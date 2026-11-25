// Modellerna som följer med appen (assets/models/manifest.json) och uppackningen vid första start.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color, HSLColor;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package.dart';

class ModelInfo {
  final String id, name, description, quant;
  final int params, steps, context, vocab, maxTokens, topK;
  final double temperature;
  final double hue;
  final bool builtin;
  final Map<String, dynamic> json;

  ModelInfo.fromJson(Map<String, dynamic> j, {this.builtin = true})
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
        temperature = (j['temperature'] as num).toDouble(),
        hue = ((j['hue'] as num?) ?? 152).toDouble(),
        json = j;

  Color get color => HSLColor.fromAHSL(1, hue % 360, 0.85, 0.62).toColor();

  String get paramsLabel => params >= 1e6 ? '${(params / 1e6).round()} M' : '${(params / 1e3).round()} k';
}

class Catalog {
  static const _channel = MethodChannel('lennart/assets');
  final List<ModelInfo> models;
  final List<ModelInfo> _builtin;
  final Directory dir;
  Catalog._(this._builtin, this.models, this.dir);

  /// Bara för förhandsvisning och tester: en katalog med givna modeller och inga filer.
  Catalog.preview(List<ModelInfo> models) : this._(models, [...models], Directory.systemTemp);

  File get _userManifest => File('${dir.path}/egna-modeller.json');

  static Future<Catalog> open() async {
    final manifest = jsonDecode(await rootBundle.loadString('assets/models/manifest.json')) as Map<String, dynamic>;
    final builtin = [for (final m in manifest['models'] as List) ModelInfo.fromJson(m as Map<String, dynamic>)];
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/models');
    await dir.create(recursive: true);
    final cat = Catalog._(builtin, [], dir);
    await cat._refresh();
    return cat;
  }

  /// Medföljande modeller plus de som importerats från .lennart-filer, minst till störst.
  Future<void> _refresh() async {
    final user = <ModelInfo>[];
    if (await _userManifest.exists()) {
      for (final m in jsonDecode(await _userManifest.readAsString()) as List) {
        final info = ModelInfo.fromJson(m as Map<String, dynamic>, builtin: false);
        if (await File(modelPath(info)).exists()) user.add(info);
      }
    }
    final ids = user.map((m) => m.id).toSet();
    models
      ..clear()
      ..addAll([..._builtin.where((m) => !ids.contains(m.id)), ...user])
      ..sort((a, b) => a.params != b.params ? a.params.compareTo(b.params) : a.steps.compareTo(b.steps));
  }

  ModelInfo get latest => models.last;

  /// Installerar ett modellpaket (.lennart) och returnerar modellen.
  Future<ModelInfo> importPackage(String path) async {
    final res = await installPackage(path, dir.path);
    final list = await _userManifest.exists() ? jsonDecode(await _userManifest.readAsString()) as List : [];
    list.removeWhere((m) => (m as Map)['id'] == res.entry['id']);
    list.add(res.entry);
    await _userManifest.writeAsString(jsonEncode(list));
    await _refresh();
    return models.firstWhere((m) => m.id == res.entry['id']);
  }

  /// Väljer en fil med telefonens filväljare (kopieras till appens cache). null om användaren avbryter.
  static Future<String?> pickFile() => _channel.invokeMethod<String>('pickFile');

  String modelPath(ModelInfo m) => '${dir.path}/${m.id}.lmod';
  String tokenizerPath(ModelInfo m) => '${dir.path}/${m.id}.tok.json';

  /// Filer som ska finnas på disken, med storleken i appens tillgångar.
  List<(String asset, String dest)> _files() => [
        for (final m in _builtin) ...[
          ('assets/models/${m.id}.lmod', modelPath(m)),
          ('assets/models/${m.id}.tok.json', tokenizerPath(m)),
        ]
      ];

  Future<bool> needsSetup() async {
    final marker = File('${dir.path}/.klar-${_builtin.map((m) => '${m.id}-${m.steps}').join('_')}');
    return !await marker.exists();
  }

  /// Packar upp modellerna. [progress] får (modellnamn, andel klar 0–1).
  Future<void> setup(void Function(String label, double done) progress) async {
    final files = _files();
    for (var i = 0; i < files.length; i++) {
      final (asset, dest) = files[i];
      final model = _builtin[i ~/ 2];
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
    await File('${dir.path}/.klar-${_builtin.map((m) => '${m.id}-${m.steps}').join('_')}').writeAsString('ok');
  }
}
