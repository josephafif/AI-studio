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
  final int passes; // framåtpass för svaret (färre än tokens när ekodekodningen träffar)
  final double? score; // modellens egen säkerhet för svaret (se _Draft.score)
  GenDone(this.tokens, this.seconds, this.promptTokens, this.drafts, {this.passes = 0, this.score});

  /// Lennart är osäker: i mätningar (forskning/tankeskalning) var bara ~11–21 % av svaren under
  /// den här gränsen rätt, mot ~70 % över den.
  bool get uncertain => score != null && score! < -0.5;
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
          out.add(GenDone(m['tokens'] as int, (m['seconds'] as num).toDouble(), m['prompt'] as int, m['drafts'] as int,
              passes: (m['passes'] as int?) ?? 0, score: (m['score'] as num?)?.toDouble()));
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
  final banned = {tok.padId, tok.userId, tok.assistantId};
  final genStart = sw.elapsedMicroseconds;
  final passesStart = model.passes;
  final rng = math.Random();
  final echo = _EchoStats();
  // Ekodekodning: frågan och tidigare utkast används som förslag (se forskning/ekodekodning/).
  final sources = <List<int>>[prompt];
  var total = 0, written = 0;
  double? chosenScore;

  if (drafts <= 1) {
    final d = _Draft.write(model, tok, rng, prompt, sources, limit, temperature, topK, banned, stop, echo,
        onPiece: (p) => toUi.send({'type': 'token', 'text': p}));
    total = d.tokens.length;
    written = 1;
    chosenScore = d.score;
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
      final d = _Draft.write(model, tok, rng, prompt, sources, limit, t, topK, banned, stop, echo,
          pruneBelow: best?.score,
          onPiece: (p) => toUi.send({'type': 'draft', 'i': i, 'n': drafts, 'text': p}));
      total += d.tokens.length;
      written++;
      sources.add([...prompt, ...d.tokens]);
      toUi.send({'type': 'draftEnd', 'i': i, 'score': d.pruned ? -99.0 : d.score, 'pruned': d.pruned});
      if (!d.pruned && (best == null || d.score > best.score)) {
        best = d;
        bestIndex = i;
      }
    }
    if (best != null) {
      chosenScore = best.score;
      toUi.send({'type': 'chosen', 'i': bestIndex, 'text': best.text});
    }
  }
  final secs = (sw.elapsedMicroseconds - genStart) / 1e6;
  toUi.send({
    'type': 'done', 'tokens': total, 'seconds': secs, 'prompt': prompt.length, 'drafts': written,
    'passes': model.passes - passesStart, 'echoAccepted': echo.accepted, 'score': chosenScore,
  });
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
  static const _maxProposal = 4; // upp till 4 tokens kostar ungefär som 1 (vikterna läses en gång)

  static double _lse(Float32List row) {
    var mx = double.negativeInfinity;
    for (var i = 0; i < row.length; i++) {
      if (row[i] > mx) mx = row[i];
    }
    var sum = 0.0;
    for (var i = 0; i < row.length; i++) {
      sum += math.exp(row[i] - mx);
    }
    return mx + math.log(sum);
  }

  /// Skriver ett utkast med ekodekodning: där texten redan förekommit (i frågan eller ett tidigare
  /// utkast) föreslås fortsättningen därifrån och kontrolleras i ett pass. Ett förslag godtas med
  /// sannolikheten p(förslag); vid avslag dras en ny token ur p utan förslaget. Det ger exakt samma
  /// fördelning som vanlig sampling, men färre pass när utkasten upprepar varandra.
  static _Draft write(NativeModel model, BpeTokenizer tok, math.Random rng, List<int> prompt, List<List<int>> sources,
      int limit, double temperature, int topK, Set<int> banned, Pointer<Int32> stop, _EchoStats echo,
      {double? pruneBelow, required void Function(String) onPiece}) {
    final d = _Draft();
    final decoder = StreamDecoder(tok);
    final ctx = model.info.context;
    final p0 = model.pos;
    var cur = Float32List.fromList(model.logits);
    List<int> recent() => d.tokens.length > 64 ? d.tokens.sublist(d.tokens.length - 64) : d.tokens;

    // Lägger till en token. Returnerar true om utkastet ska avslutas (sållat).
    bool emit(int x, Float32List row) {
      d.tokens.add(x);
      d._lpSum += row[x] - _lse(row); // logsannolikhet enligt modellens egen, ostraffade fördelning
      final piece = decoder.add(x);
      if (piece.isNotEmpty) {
        d._text.write(piece);
        onPiece(piece);
      }
      // Sålla: ett utkast som efter en bit är klart sämre än det bästa hittills avbryts.
      if (pruneBelow != null && d.tokens.length >= 24 && d.meanLogprob - 2.0 * d.repetition < pruneBelow - 0.6) {
        d.pruned = true;
        return true;
      }
      return false;
    }

    outer:
    while (d.tokens.length < limit && stop.value == 0) {
      final dist = _Dist.of(cur, temperature, topK, recent(), banned);
      var prop = _lookup(sources, [...prompt, ...d.tokens], _maxProposal);
      final room = math.min(limit - d.tokens.length, ctx - model.pos - 1);
      if (prop.length > room) prop = room > 0 ? prop.sublist(0, room) : const [];
      int x;
      if (prop.isNotEmpty) {
        echo.proposed++;
        final x1 = prop[0];
        if (rng.nextDouble() < dist.prob(x1)) {
          echo.accepted++;
          if (x1 == tok.endId) {
            d.ended = true;
            break;
          }
          if (emit(x1, cur)) break;
          final rows = model.evalAll(prop); // rad j = fördelningen efter prop[j]
          for (var j = 1; j <= prop.length; j++) {
            final row = rows[j - 1];
            if (d.tokens.length >= limit || stop.value != 0) break outer;
            final pj = _Dist.of(row, temperature, topK, recent(), banned);
            if (j < prop.length && rng.nextDouble() < pj.prob(prop[j])) {
              echo.accepted++;
              if (prop[j] == tok.endId) {
                d.ended = true;
                break outer;
              }
              if (emit(prop[j], row)) break outer;
              continue;
            }
            // Avslag, eller alla förslag godtagna: dra nästa token ur pj (utan det avvisade förslaget).
            final y = pj.sample(rng, without: j < prop.length ? prop[j] : null);
            model.rewind(p0 + d.tokens.length);
            if (y == tok.endId) {
              d.ended = true;
              break outer;
            }
            if (emit(y, row) || model.pos >= ctx) break outer;
            model.eval([y]);
            cur = Float32List.fromList(model.logits);
            continue outer;
          }
          continue outer;
        }
        x = dist.sample(rng, without: x1);
      } else {
        x = dist.sample(rng);
      }
      if (x == tok.endId) {
        d.ended = true;
        break;
      }
      if (emit(x, cur) || model.pos >= ctx) break;
      model.eval([x]);
      cur = Float32List.fromList(model.logits);
    }
    return d;
  }
}

class _EchoStats {
  int proposed = 0, accepted = 0;
}

/// Föreslår upp till k tokens: hitta senaste förekomsten av textens sista 3, 2 eller 1 token i någon
/// källa och returnera det som kom efter.
List<int> _lookup(List<List<int>> sources, List<int> seq, int k) {
  for (var n = 3; n >= 1; n--) {
    if (seq.length < n) continue;
    List<int>? best;
    for (final src in sources) {
      for (var i = src.length - n - 1; i >= 0; i--) {
        var ok = true;
        for (var t = 0; t < n; t++) {
          if (src[i + t] != seq[seq.length - n + t]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          final c = src.sublist(i + n, math.min(src.length, i + n + k));
          if (best == null || c.length > best.length) best = c;
          break;
        }
      }
    }
    if (best != null && best.isNotEmpty) return best;
  }
  return const [];
}

/// Samplingsfördelningen för en position, exakt som tidigare i motorn: upprepningsstraff,
/// förbjudna tokens, top-k och temperatur. Sparar bara kandidaterna.
class _Dist {
  final List<int> ids;
  final List<double> p;
  _Dist(this.ids, this.p);

  double prob(int t) {
    final i = ids.indexOf(t);
    return i < 0 ? 0 : p[i];
  }

  int sample(math.Random r, {int? without}) {
    var total = 1.0;
    if (without != null) total -= prob(without);
    if (total <= 1e-12) return ids.first;
    var u = r.nextDouble() * total;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] == without) continue;
      u -= p[i];
      if (u <= 0) return ids[i];
    }
    for (var i = ids.length - 1; i >= 0; i--) {
      if (ids[i] != without) return ids[i];
    }
    return ids.first;
  }

  static _Dist of(Float32List row, double temperature, int topK, List<int> recent, Set<int> banned) {
    final pen = <int, double>{};
    for (final t in recent) {
      if (pen.containsKey(t)) continue;
      final v = row[t];
      pen[t] = v > 0 ? v / _Draft._penalty : v * _Draft._penalty;
    }
    double val(int i) => banned.contains(i) ? double.negativeInfinity : (pen[i] ?? row[i]);
    final n = row.length;
    if (temperature <= 1e-6) {
      var best = -1;
      var bv = double.negativeInfinity;
      for (var i = 0; i < n; i++) {
        final v = val(i);
        if (v > bv) {
          bv = v;
          best = i;
        }
      }
      return _Dist([best], [1]);
    }
    final ids = <int>[];
    final vals = <double>[];
    if (topK > 0 && topK < n) {
      var minI = -1;
      var minV = double.negativeInfinity;
      for (var i = 0; i < n; i++) {
        final v = val(i);
        if (v == double.negativeInfinity) continue;
        if (ids.length < topK) {
          ids.add(i);
          vals.add(v);
          if (ids.length == topK) {
            minI = 0;
            for (var j = 1; j < topK; j++) {
              if (vals[j] < vals[minI]) minI = j;
            }
            minV = vals[minI];
          }
        } else if (v > minV) {
          ids[minI] = i;
          vals[minI] = v;
          minI = 0;
          for (var j = 1; j < topK; j++) {
            if (vals[j] < vals[minI]) minI = j;
          }
          minV = vals[minI];
        }
      }
    } else {
      for (var i = 0; i < n; i++) {
        final v = val(i);
        if (v == double.negativeInfinity) continue;
        ids.add(i);
        vals.add(v);
      }
    }
    var mx = double.negativeInfinity;
    for (final v in vals) {
      if (v > mx) mx = v;
    }
    final p = [for (final v in vals) math.exp((v - mx) / temperature)];
    final sum = p.fold<double>(0, (a, b) => a + b);
    for (var i = 0; i < p.length; i++) {
      p[i] /= sum;
    }
    return _Dist(ids, p);
  }
}
