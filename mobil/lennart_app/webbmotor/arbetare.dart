// Webbversionens motor. Körs i en Web Worker och kompileras till JavaScript med dart2js
// (se webb/app/bygg.py). Samma tokenizer, generering och verktygssinne som appen, mot motorn som
// WebAssembly. JS-delen (webb/app/arbetare-start.js) läser in modellen och ger tillgång till motorn
// via `self.lm`; den här filen tar hand om resten av kommandona från sidan.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lennart_app/agent/avsikt.dart';
import 'package:lennart_app/agent/webbverktyg.dart';
import 'package:lennart_app/core/generering.dart';
import 'package:lennart_app/core/tokenizer.dart';

/// Motorn i WebAssembly, som JS-delen exponerar.
extension type _Lm(JSObject _) implements JSObject {
  external int pos();
  external int context();
  external void reset();
  external int rewind(int p);
  external int vocab();
  external JSFloat32Array logits();
  external int eval(JSInt32Array tokens);
  external JSFloat32Array evalAll(JSInt32Array tokens);
}

@JS('lm')
external _Lm get _lm;

@JS('postMessage')
external void _post(JSAny? message);

class _WasmMotor implements Motor {
  @override
  int passes = 0;
  @override
  int get pos => _lm.pos();
  @override
  int get context => _lm.context();
  @override
  void reset() => _lm.reset();
  @override
  void rewind(int p) {
    if (_lm.rewind(p) != 0) throw StateError('Kan inte spola tillbaka till $p');
  }

  @override
  Float32List get logits => _lm.logits().toDart;

  @override
  void eval(List<int> tokens) {
    if (tokens.isEmpty) return;
    final rc = _lm.eval(Int32List.fromList(tokens).toJS);
    if (rc != 0) throw StateError('Motorn kunde inte räkna (kod $rc)');
    passes++;
  }

  @override
  List<Float32List> evalAll(List<int> tokens) {
    final all = _lm.evalAll(Int32List.fromList(tokens).toJS).toDart;
    if (all.isEmpty) throw StateError('Motorn kunde inte räkna');
    passes++;
    final v = _lm.vocab();
    return [for (var i = 0; i < tokens.length; i++) Float32List.sublistView(all, i * v, (i + 1) * v)];
  }
}

BpeTokenizer? _tok;
final _motor = _WasmMotor();
final _slump = math.Random.secure();

void _skicka(Map<String, Object?> m) => _post(m.jsify());

void _kommando(JSAny msg) {
  final m = (msg.dartify() as Map).cast<String, Object?>();
  final id = m['id'];
  try {
    switch (m['cmd']) {
      case 'tokenizer':
        _tok = BpeTokenizer.fromJson(m['text'] as String);
        _skicka({'type': 'tokenizerKlar', 'id': id});
      case 'generate':
        final tok = _tok ?? (throw StateError('Ingen modell är inläst'));
        generera(_motor, tok, m, (e) => _skicka(e.cast<String, Object?>()), () => false);
      case 'tolka':
        final av = tolkaFraga(m['text'] as String);
        _skicka({
          'type': 'avsikt',
          'id': id,
          if (av != null) ...{'namn': av.namn, 'argument': av.argument, 'fore': av.fore, 'andrar': webbVerktygAndrar(av.namn, av.argument)},
        });
      case 'verktyg':
        final namn = m['namn'] as String;
        final arg = ((m['argument'] as Map?) ?? {}).cast<String, dynamic>();
        final filer = ((m['filer'] as Map?) ?? {}).map((k, v) => MapEntry(k.toString(), v.toString()));
        final nekad = m['nekad'] == true;
        final r = nekad ? const WebbResultat('Användaren nekade anropet', fel: true) : korWebbVerktyg(namn, arg, filer, DateTime.now(), _slump);
        _skicka({
          'type': 'resultat',
          'id': id,
          'resultat': r.resultat,
          'fel': r.fel,
          'andrade': r.andrade,
          'svar': svarFran(namn, arg, r.resultat, fel: r.fel && !nekad, nekad: nekad),
          'visas': visningsnamn[namn] ?? namn,
        });
    }
  } catch (e) {
    _skicka({'type': m['cmd'] == 'generate' ? 'genError' : 'fel', 'id': id, 'message': '$e'});
  }
}

void main() {
  globalContext['lennartKommando'] = _kommando.toJS;
  globalContext['lennartVisningsnamn'] = visningsnamn.jsify();
}
