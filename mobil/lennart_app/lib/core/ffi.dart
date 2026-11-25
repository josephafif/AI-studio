// FFI-bindningar till inferensmotorn (mobil/engine/lmengine.c, byggd som liblmengine.so).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Int32);
typedef _LoadD = Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _InfoC = Void Function(Pointer<Void>, Pointer<Int32>);
typedef _InfoD = void Function(Pointer<Void>, Pointer<Int32>);
typedef _VoidC = Void Function(Pointer<Void>);
typedef _VoidD = void Function(Pointer<Void>);
typedef _IntC = Int32 Function(Pointer<Void>);
typedef _IntD = int Function(Pointer<Void>);
typedef _EvalC = Int32 Function(Pointer<Void>, Pointer<Int32>, Int32);
typedef _EvalD = int Function(Pointer<Void>, Pointer<Int32>, int);
typedef _RewindC = Int32 Function(Pointer<Void>, Int32);
typedef _RewindD = int Function(Pointer<Void>, int);
typedef _LogprobC = Float Function(Pointer<Void>, Int32);
typedef _LogprobD = double Function(Pointer<Void>, int);
typedef _LogitsC = Pointer<Float> Function(Pointer<Void>);
typedef _EvalAllC = Int32 Function(Pointer<Void>, Pointer<Int32>, Int32, Pointer<Float>);
typedef _EvalAllD = int Function(Pointer<Void>, Pointer<Int32>, int, Pointer<Float>);
typedef _SampleC = Int32 Function(Pointer<Void>, Float, Int32, Pointer<Int32>, Int32, Pointer<Uint64>);
typedef _SampleD = int Function(Pointer<Void>, double, int, Pointer<Int32>, int, Pointer<Uint64>);

class EngineInfo {
  final int vocab, dModel, layers, heads, context;
  final bool int8;
  const EngineInfo(this.vocab, this.dModel, this.layers, this.heads, this.context, this.int8);
}

/// En inläst modell. Används bara i modellisolaten.
class NativeModel {
  static DynamicLibrary? _lib;
  static DynamicLibrary get lib =>
      _lib ??= Platform.isAndroid ? DynamicLibrary.open('liblmengine.so') : DynamicLibrary.open('liblmengine.so');

  static final _load = lib.lookupFunction<_LoadC, _LoadD>('lm_load');
  static final _info = lib.lookupFunction<_InfoC, _InfoD>('lm_info');
  static final _reset = lib.lookupFunction<_VoidC, _VoidD>('lm_reset');
  static final _free = lib.lookupFunction<_VoidC, _VoidD>('lm_free');
  static final _pos = lib.lookupFunction<_IntC, _IntD>('lm_pos');
  static final _eval = lib.lookupFunction<_EvalC, _EvalD>('lm_eval');
  static final _sample = lib.lookupFunction<_SampleC, _SampleD>('lm_sample');
  static final _rewind = lib.lookupFunction<_RewindC, _RewindD>('lm_rewind');
  static final _logprob = lib.lookupFunction<_LogprobC, _LogprobD>('lm_logprob');
  static final _logits = lib.lookupFunction<_LogitsC, _LogitsC>('lm_logits');
  static final _evalAll = lib.lookupFunction<_EvalAllC, _EvalAllD>('lm_eval_all');

  final Pointer<Void> _h;
  late final EngineInfo info;
  final Pointer<Uint64> _rng = calloc<Uint64>();
  Pointer<Int32> _buf = calloc<Int32>(1);
  int _bufLen = 1;
  Pointer<Float> _rows = nullptr;
  int _rowsLen = 0;

  /// Antal framåtpass (varje pass läser alla vikter en gång).
  int passes = 0;

  NativeModel._(this._h) {
    final out = calloc<Int32>(8);
    _info(_h, out);
    info = EngineInfo(out[0], out[1], out[2], out[3], out[4], out[5] == 1);
    calloc.free(out);
    _rng.value = DateTime.now().microsecondsSinceEpoch | 1;
  }

  static NativeModel load(String path, int threads) {
    final p = path.toNativeUtf8();
    final err = calloc<Uint8>(256).cast<Utf8>();
    try {
      final h = _load(p, threads, err, 256);
      if (h == nullptr) throw StateError('Modellen kunde inte läsas: ${err.toDartString()}');
      return NativeModel._(h);
    } finally {
      calloc.free(p);
      calloc.free(err);
    }
  }

  int get pos => _pos(_h);
  void reset() => _reset(_h);

  /// Spolar tillbaka cachen till [p] (för att skriva ett nytt utkast från samma prompt).
  void rewind(int p) {
    if (_rewind(_h, p) != 0) throw StateError('Kan inte spola tillbaka till $p');
  }

  /// Senaste logits, direkt i motorns minne (kan läsas och ändras).
  Float32List get logits => _logits(_h).asTypedList(info.vocab);

  /// log P(token) enligt nuvarande logits.
  double logprob(int token) => _logprob(_h, token);

  void _fill(List<int> tokens) {
    if (tokens.length > _bufLen) {
      calloc.free(_buf);
      _buf = calloc<Int32>(tokens.length);
      _bufLen = tokens.length;
    }
    for (var i = 0; i < tokens.length; i++) {
      _buf[i] = tokens[i];
    }
  }

  /// Matar in tokens efter det som redan finns i cachen.
  void eval(List<int> tokens) {
    if (tokens.isEmpty) return;
    _fill(tokens);
    final rc = _eval(_h, _buf, tokens.length);
    if (rc != 0) throw StateError('Motorn kunde inte räkna (kod $rc)');
    passes++;
  }

  /// Matar in tokens i ett pass och returnerar logits för varje position:
  /// rad i är fördelningen för tokenen efter tokens[i].
  List<Float32List> evalAll(List<int> tokens) {
    final n = tokens.length, v = info.vocab;
    _fill(tokens);
    if (n * v > _rowsLen) {
      if (_rows != nullptr) calloc.free(_rows);
      _rows = calloc<Float>(n * v);
      _rowsLen = n * v;
    }
    final rc = _evalAll(_h, _buf, n, _rows);
    if (rc != 0) throw StateError('Motorn kunde inte räkna (kod $rc)');
    passes++;
    final all = _rows.asTypedList(n * v);
    return [for (var i = 0; i < n; i++) Float32List.fromList(all.sublist(i * v, (i + 1) * v))];
  }

  int sample(double temperature, int topK, List<int> banned) {
    final b = calloc<Int32>(banned.length);
    for (var i = 0; i < banned.length; i++) {
      b[i] = banned[i];
    }
    final t = _sample(_h, temperature, topK, b, banned.length, _rng);
    calloc.free(b);
    return t;
  }

  void dispose() {
    _free(_h);
    calloc.free(_rng);
    calloc.free(_buf);
    if (_rows != nullptr) calloc.free(_rows);
  }
}
