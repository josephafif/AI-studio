// Modellerna som följer med appen (assets/models/manifest.json) och uppackningen vid första start.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color, HSLColor;
import 'package:file_selector/file_selector.dart';
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
  final Directory dir; // egna (importerade) modeller, i appens lagring
  final Directory? bundled; // dator: förinstallerade modeller i mappen "modeller" bredvid Lennart.exe
  Catalog._(this._builtin, this.models, this.dir, [this.bundled]);

  /// Bara för förhandsvisning och tester: en katalog med givna modeller och inga filer.
  Catalog.preview(List<ModelInfo> models) : this._(models, [...models], Directory.systemTemp);

  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Mappen med förinstallerade modeller på datorn: <programmapp>/modeller (eller LENNART_MODELLER).
  static Directory desktopModelsDir() {
    final env = Platform.environment['LENNART_MODELLER'];
    if (env != null && env.isNotEmpty) return Directory(env);
    return Directory('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}modeller');
  }

  /// Läser alla modellbeskrivningar i [d]: en fil per modell (<id>.modell.json) och/eller manifest.json.
  /// Så kan extra modeller läggas till genom att packa upp dem i samma mapp.
  static Future<List<ModelInfo>> scanModels(Directory d) async {
    final out = <String, ModelInfo>{};
    if (!await d.exists()) return [];
    await for (final f in d.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!(name.endsWith('.modell.json') || name == 'manifest.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString());
        final list = j is Map && j['models'] is List ? j['models'] as List : [j];
        for (final m in list) {
          final info = ModelInfo.fromJson(m as Map<String, dynamic>);
          if (await File('${d.path}/${info.id}.lmod').exists()) out[info.id] = info;
        }
      } catch (_) {/* trasig fil – hoppa över */}
    }
    return out.values.toList();
  }

  File get _userManifest => File('${dir.path}/egna-modeller.json');

  static Future<Catalog> open() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/models');
    await dir.create(recursive: true);
    if (isDesktop) {
      // Datorn: modellerna ligger färdiga bredvid programmet och läses direkt därifrån (ingen uppackning).
      final bundled = desktopModelsDir();
      final cat = Catalog._(await scanModels(bundled), [], dir, bundled);
      await cat._refresh();
      return cat;
    }
    final manifest = jsonDecode(await rootBundle.loadString('assets/models/manifest.json')) as Map<String, dynamic>;
    final builtin = [for (final m in manifest['models'] as List) ModelInfo.fromJson(m as Map<String, dynamic>)];
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

  ModelInfo get latest {
    if (models.isEmpty) throw StateError('Hittade inga modeller. Ligger mappen "modeller" bredvid Lennart.exe?');
    return models.last;
  }

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

  /// Väljer ett modellpaket. Telefonen: systemets filväljare (filen kopieras till appens cache).
  /// Datorn: Windows filväljare – filen ligger kvar där den är.
  static Future<String?> pickFile() async {
    if (isDesktop) {
      final f = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Lennart-modell', extensions: ['lennart']),
      ]);
      return f?.path;
    }
    return _channel.invokeMethod<String>('pickFile');
  }

  Directory _dirFor(ModelInfo m) => m.builtin && bundled != null ? bundled! : dir;
  String modelPath(ModelInfo m) => '${_dirFor(m).path}/${m.id}.lmod';
  String tokenizerPath(ModelInfo m) => '${_dirFor(m).path}/${m.id}.tok.json';

  /// Filer som ska finnas på disken, med storleken i appens tillgångar.
  List<(String asset, String dest)> _files() => [
        for (final m in _builtin) ...[
          ('assets/models/${m.id}.lmod', modelPath(m)),
          ('assets/models/${m.id}.tok.json', tokenizerPath(m)),
        ]
      ];

  Future<bool> needsSetup() async {
    if (bundled != null) return false;
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
