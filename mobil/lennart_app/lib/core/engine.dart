// Kör modellen i en egen isolat så att gränssnittet aldrig fryser medan Lennart tänker.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi.dart';
import 'tokenizer.dart';

/// Hur mycket Lennart får "tänka" innan svaret visas.
///
/// En liten språkmodell kan inte resonera i flera steg, men den kan skriva flera utkast och
/// bedöma dem själv: varje utkast poängsätts efter hur säker modellen är på sina egna ord
/// (medel-logsannolikhet), hur mycket det upprepar sig och om det avslutades naturligt.
/// Utkast som tidigt ser sämre ut än det bästa hittills avbryts för att spara tid.
enum Effort {
  snabb('Snabb', 'Svarar direkt med första utkastet', 1),
  medel('Medel', 'Skriver 3 utkast och väljer det bästa', 3),
  djup('Djup', 'Skriver upp till 6 utkast, sållar bort svaga tidigt', 6);

  final String label, description;
  final int drafts;
  const Effort(this.label, this.description, this.drafts);
}

class GenSettings {
  final double temperature;
  final int maxTokens;
  final int topK;
  final Effort effort;
  const GenSettings({this.temperature = 0.7, this.maxTokens = 200, this.topK = 40, this.effort = Effort.medel});
  GenSettings copyWith({double? temperature, int? maxTokens, int? topK, Effort? effort}) => GenSettings(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      topK: topK ?? this.topK,
      effort: effort ?? this.effort);
}

sealed class GenEvent {}

/// En bit av det slutliga svaret (bara på nivån Snabb strömmas svaret direkt).
class GenToken extends GenEvent {
  final String text;
  GenToken(this.text);
}

/// En bit av ett utkast medan Lennart tänker.
class GenDraft extends GenEvent {
  final int index, total;
  final String text;
  GenDraft(this.index, this.total, this.text);
}

/// Ett utkast är klart (eller avbrutet för att det såg sämre ut än det bästa).
class GenDraftEnd extends GenEvent {
  final int index;
  final double score;
  final bool pruned;
  GenDraftEnd(this.index, this.score, this.pruned);
}

/// Det utkast som valdes som svar.
class GenChosen extends GenEvent {
  final int index;
  final String text;
  GenChosen(this.index, this.text);
}

class GenDone extends GenEvent {
  final int tokens;
  final double seconds;
  final int promptTokens;
  final int drafts;
  GenDone(this.tokens, this.seconds, this.promptTokens, this.drafts);
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
        case 'draft':
          out.add(GenDraft(m['i'] as int, m['n'] as int, m['text'] as String));
        case 'draftEnd':
          out.add(GenDraftEnd(m['i'] as int, (m['score'] as num).toDouble(), m['pruned'] as bool));
        case 'chosen':
          out.add(GenChosen(m['i'] as int, m['text'] as String));
        case 'done':
          out.add(GenDone(m['tokens'] as int, (m['seconds'] as num).toDouble(), m['prompt'] as int, m['drafts'] as int));
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
      'drafts': s.effort.drafts,
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
  final temperature = m['temperature'] as double;
  final topK = m['topK'] as int;
  final drafts = (m['drafts'] as int?) ?? 1;
  var turns = [for (final t in m['turns'] as List) ChatTurn(t[0] as bool, t[1] as String)];
  // Behåll så mycket av samtalet som ryms och lämna plats för svaret.
  final budget = (ctx - (maxTokens < ctx ~/ 2 ? maxTokens : ctx ~/ 2)).clamp(8, ctx - 1);
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
  final p0 = model.pos;
  final saved = Float32List.fromList(model.logits);
  final limit = maxTokens.clamp(1, ctx - p0);
  final banned = [tok.padId, tok.userId, tok.assistantId];
  final genStart = sw.elapsedMicroseconds;
  var total = 0, written = 0;

  if (drafts <= 1) {
    final d = _Draft.write(model, tok, limit, temperature, topK, banned, stop, onPiece: (p) => toUi.send({'type': 'token', 'text': p}));
    total = d.tokens.length;
    written = 1;
  } else {
    _Draft? best;
    var bestIndex = 0;
    for (var i = 0; i < drafts && stop.value == 0; i++) {
      if (i > 0) {
        model.rewind(p0);
        model.logits.setAll(0, saved);
      }
      // Första utkastet är försiktigt (låg temperatur), resten mer varierade.
      final t = i == 0 ? (temperature < 0.35 ? temperature : 0.35) : (temperature < 0.5 ? 0.5 : temperature);
      final d = _Draft.write(model, tok, limit, t, topK, banned, stop,
          pruneBelow: best?.score,
          onPiece: (p) => toUi.send({'type': 'draft', 'i': i, 'n': drafts, 'text': p}));
      total += d.tokens.length;
      written++;
      toUi.send({'type': 'draftEnd', 'i': i, 'score': d.pruned ? -99.0 : d.score, 'pruned': d.pruned});
      if (!d.pruned && (best == null || d.score > best.score)) {
        best = d;
        bestIndex = i;
      }
    }
    if (best != null) toUi.send({'type': 'chosen', 'i': bestIndex, 'text': best.text});
  }
  final secs = (sw.elapsedMicroseconds - genStart) / 1e6;
  toUi.send({'type': 'done', 'tokens': total, 'seconds': secs, 'prompt': prompt.length, 'drafts': written});
}

/// Ett utkast: tokens, text och modellens egen bedömning av det.
class _Draft {
  final List<int> tokens = [];
  final StringBuffer _text = StringBuffer();
  double _lpSum = 0;
  bool ended = false, pruned = false;

  String get text => _text.toString();
  double get meanLogprob => tokens.isEmpty ? -10 : _lpSum / tokens.length;

  /// Andel upprepade tre-tokenföljder – små modeller fastnar gärna i slingor.
  double get repetition {
    if (tokens.length < 6) return 0;
    final seen = <int>{};
    var dup = 0;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (!seen.add(tokens[i] * 1000003 * 1000003 + tokens[i + 1] * 1000003 + tokens[i + 2])) dup++;
    }
    return dup / (tokens.length - 2);
  }

  double get score {
    var s = meanLogprob - 2.0 * repetition;
    s += ended ? 0.15 : -0.25; // ett avslutat svar är bättre än ett avhugget
    if (tokens.length < 3) s -= 1.0; // nästan tomt svar
    s += 0.08 * (tokens.length / 30).clamp(0.0, 1.0); // korta, intetsägande svar ska inte vinna bara för att de är säkra
    return s;
  }

  static const _penalty = 1.12; // mild straff för ord som redan använts i svaret

  static _Draft write(NativeModel model, BpeTokenizer tok, int limit, double temperature, int topK, List<int> banned,
      Pointer<Int32> stop,
      {double? pruneBelow, required void Function(String) onPiece}) {
    final d = _Draft();
    final decoder = StreamDecoder(tok);
    final ctx = model.info.context;
    while (d.tokens.length < limit && stop.value == 0) {
      final lg = model.logits;
      // Logsannolikheter räknas på modellens egna, ostraffade fördelning.
      var mx = double.negativeInfinity;
      for (var i = 0; i < lg.length; i++) {
        if (lg[i] > mx) mx = lg[i];
      }
      var sum = 0.0;
      for (var i = 0; i < lg.length; i++) {
        sum += math.exp(lg[i] - mx);
      }
      final lse = mx + math.log(sum);
      final raw = <int, double>{};
      final recent = d.tokens.length > 64 ? d.tokens.sublist(d.tokens.length - 64) : d.tokens;
      for (final t in recent) {
        if (raw.containsKey(t)) continue;
        raw[t] = lg[t];
        lg[t] = lg[t] > 0 ? lg[t] / _penalty : lg[t] * _penalty;
      }
      final next = model.sample(temperature, topK, banned);
      if (next == tok.endId) {
        d.ended = true;
        break;
      }
      d.tokens.add(next);
      d._lpSum += (raw[next] ?? lg[next]) - lse;
      final piece = decoder.add(next);
      if (piece.isNotEmpty) {
        d._text.write(piece);
        onPiece(piece);
      }
      // Sålla: ett utkast som efter en bit är klart sämre än det bästa hittills avbryts.
      if (pruneBelow != null && d.tokens.length >= 24 && d.meanLogprob - 2.0 * d.repetition < pruneBelow - 0.6) {
        d.pruned = true;
        break;
      }
      if (model.pos >= ctx) break;
      model.eval([next]);
    }
    return d;
  }
}
