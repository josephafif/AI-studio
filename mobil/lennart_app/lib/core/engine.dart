// Kör modellen i en egen isolat så att gränssnittet aldrig fryser medan Lennart tänker.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'ffi.dart';
import 'tokenizer.dart';

class GenSettings {
  final double temperature;
  final int maxTokens;
  final int topK;
  const GenSettings({this.temperature = 0.7, this.maxTokens = 200, this.topK = 40});
  GenSettings copyWith({double? temperature, int? maxTokens, int? topK}) => GenSettings(
      temperature: temperature ?? this.temperature, maxTokens: maxTokens ?? this.maxTokens, topK: topK ?? this.topK);
}

sealed class GenEvent {}

class GenToken extends GenEvent {
  final String text;
  GenToken(this.text);
}

class GenDone extends GenEvent {
  final int tokens;
  final double seconds;
  final int promptTokens;
  GenDone(this.tokens, this.seconds, this.promptTokens);
  double get tokensPerSecond => seconds > 0 ? tokens / seconds : 0;
}

class GenError extends GenEvent {
  final String message;
  GenError(this.message);
}

/// Styr modellisolaten. En modell är inläst åt gången.
class LennartEngine {
  SendPort? _cmd;
  final _events = StreamController<Map>.broadcast();
  final Pointer<Int32> _stop = calloc<Int32>();
  String? loadedId;
  int context = 0;

  Future<void> _ensure() async {
    if (_cmd != null) return;
    final rp = ReceivePort();
    await Isolate.spawn(_main, rp.sendPort, debugName: 'lennart-motor');
    final ready = Completer<SendPort>();
    rp.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is Map) {
        _events.add(msg);
      }
    });
    _cmd = await ready.future;
  }

  Future<void> load(String id, String modelPath, String tokenizerPath) async {
    if (loadedId == id) return;
    await _ensure();
    final reply = _events.stream.firstWhere((m) => m['type'] == 'loaded' || m['type'] == 'loadError');
    final threads = (Platform.numberOfProcessors - 1).clamp(1, 8);
    _cmd!.send({'cmd': 'load', 'model': modelPath, 'tok': tokenizerPath, 'threads': threads});
    final m = await reply;
    if (m['type'] == 'loadError') throw StateError(m['message'] as String);
    loadedId = id;
    context = m['context'] as int;
  }

  /// Strömmar svaret på samtalet. Avbryt med [stop].
  Stream<GenEvent> generate(List<ChatTurn> turns, GenSettings s) async* {
    await _ensure();
    _stop.value = 0;
    final out = StreamController<GenEvent>();
    late StreamSubscription sub;
    sub = _events.stream.listen((m) {
      switch (m['type']) {
        case 'token':
          out.add(GenToken(m['text'] as String));
        case 'done':
          out.add(GenDone(m['tokens'] as int, (m['seconds'] as num).toDouble(), m['prompt'] as int));
          sub.cancel();
          out.close();
        case 'genError':
          out.add(GenError(m['message'] as String));
          sub.cancel();
          out.close();
      }
    });
    _cmd!.send({
      'cmd': 'generate',
      'turns': [for (final t in turns) [t.fromUser, t.text]],
      'temperature': s.temperature,
      'maxTokens': s.maxTokens,
      'topK': s.topK,
      'stop': _stop.address,
    });
    yield* out.stream;
  }

  void stop() => _stop.value = 1;
}

// ───────────────────────────────────────────── i modellisolaten
void _main(SendPort toUi) {
  final rp = ReceivePort();
  toUi.send(rp.sendPort);
  NativeModel? model;
  BpeTokenizer? tok;
  rp.listen((msg) {
    final m = msg as Map;
    if (m['cmd'] == 'load') {
      try {
        model?.dispose();
        model = null;
        tok = BpeTokenizer.fromJson(File(m['tok'] as String).readAsStringSync());
        model = NativeModel.load(m['model'] as String, m['threads'] as int);
        toUi.send({'type': 'loaded', 'context': model!.info.context});
      } catch (e) {
        toUi.send({'type': 'loadError', 'message': '$e'});
      }
    } else if (m['cmd'] == 'generate') {
      try {
        _generate(model!, tok!, m, toUi);
      } catch (e) {
        toUi.send({'type': 'genError', 'message': '$e'});
      }
    }
  });
}

void _generate(NativeModel model, BpeTokenizer tok, Map m, SendPort toUi) {
  final stop = Pointer<Int32>.fromAddress(m['stop'] as int);
  final ctx = model.info.context;
  final maxTokens = m['maxTokens'] as int;
  var turns = [for (final t in m['turns'] as List) ChatTurn(t[0] as bool, t[1] as String)];
  // Behåll så mycket av samtalet som ryms och lämna plats för svaret.
  final budget = (ctx - (maxTokens < ctx ~/ 2 ? maxTokens : ctx ~/ 2)).clamp(8, ctx);
  var prompt = tok.encodeChat(turns);
  while (prompt.length > budget && turns.length > 1) {
    turns = turns.sublist(1);
    while (turns.length > 1 && !turns.first.fromUser) {
      turns = turns.sublist(1);
    }
    prompt = tok.encodeChat(turns);
  }
  if (prompt.length > budget) prompt = prompt.sublist(prompt.length - budget);
  final sw = Stopwatch()..start();
  model.reset();
  model.eval(prompt);
  final history = List<int>.of(prompt);
  final banned = [tok.padId, tok.userId, tok.assistantId];
  final decoder = StreamDecoder(tok);
  var n = 0;
  final genStart = sw.elapsedMicroseconds;
  while (n < maxTokens && stop.value == 0) {
    final next = model.sample(m['temperature'] as double, m['topK'] as int, banned);
    if (next == tok.endId) break;
    n++;
    history.add(next);
    final piece = decoder.add(next);
    if (piece.isNotEmpty) toUi.send({'type': 'token', 'text': piece});
    if (model.pos >= ctx) {
      // Kontexten är full: börja om med den senare halvan.
      final keep = history.sublist(history.length - ctx ~/ 2);
      model.reset();
      model.eval(keep);
    } else {
      model.eval([next]);
    }
  }
  final secs = (sw.elapsedMicroseconds - genStart) / 1e6;
  toUi.send({'type': 'done', 'tokens': n, 'seconds': secs, 'prompt': prompt.length});
}
