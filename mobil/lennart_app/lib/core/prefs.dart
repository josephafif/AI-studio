// Små inställningar som sparas mellan starterna (effortnivå och senast använda modell).
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'engine.dart';

class Prefs {
  static File? _file;
  static Map<String, dynamic> _data = {};

  static Future<void> load() async {
    try {
      _file = File('${(await getApplicationSupportDirectory()).path}/installningar.json');
      if (await _file!.exists()) _data = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      _data = {};
    }
  }

  static void _save() {
    try {
      _file?.writeAsStringSync(jsonEncode(_data));
    } catch (_) {}
  }

  static Effort get effort => Effort.values.firstWhere((e) => e.name == _data['effort'], orElse: () => Effort.medel);
  static set effort(Effort e) {
    _data['effort'] = e.name;
    _save();
  }

  /// Agentläge: Lennart får använda verktyg (förhandsvisning – kräver en modell tränad på verktyg).
  static bool get agent => _data['agent'] != false; // på som standard
  static set agent(bool v) {
    _data['agent'] = v;
    _save();
  }

  /// Mappen som agentens filverktyg får arbeta i.
  static String? get arbetsmapp => _data['arbetsmapp'] as String?;
  static set arbetsmapp(String? v) {
    _data['arbetsmapp'] = v;
    _save();
  }

  static String? get modelId => _data['model'] as String?;
  static set modelId(String? id) {
    _data['model'] = id;
    _save();
  }
}
