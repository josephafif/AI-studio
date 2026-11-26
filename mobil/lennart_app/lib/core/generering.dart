// Genereringen bakom tänkenivåerna Snabb, Medel, Djup och Djup+, med ekodekodning.
//
// Ren Dart utan dart:ffi, dart:io och isolater: samma kod körs i appens modellisolat (mot motorn via FFI)
// och i webbversionen (mot motorn som WebAssembly), så att Lennart tänker likadant överallt.
import 'dart:math' as math;
import 'dart:typed_data';

import 'tokenizer.dart';

/// Det genereringen behöver av motorn.
abstract class Motor {
  /// Antal tokens i cachen.
  int get pos;

  /// Modellens kontextlängd.
  int get context;

  /// Antal framåtpass hittills (varje pass läser alla vikter en gång).
  int get passes;

  void reset();

  /// Spolar tillbaka cachen till [p].
  void rewind(int p);

  /// Senaste logits, direkt i motorns minne (kan läsas och ändras).
  Float32List get logits;

  /// Matar in tokens efter det som redan finns i cachen.
  void eval(List<int> tokens);

  /// Matar in tokens i ett pass och returnerar logits för varje position.
  List<Float32List> evalAll(List<int> tokens);
}

/// Svarar på samtalet i [m] och skickar händelser med [send]: token, draft, draftEnd, segment, chosen, done.
void generera(Motor model, BpeTokenizer tok, Map m, void Function(Map) send, bool Function() stoppad) {
  final ctx = model.context;
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
  final banned = tok.banned;
  final genStart = sw.elapsedMicroseconds;
  final passesStart = model.passes;
  final rng = math.Random();
  final echo = _EchoStats();
  // Ekodekodning: frågan och tidigare utkast används som förslag (se forskning/ekodekodning/).
  final sources = <List<int>>[prompt];
  var total = 0, written = 0;
  double? chosenScore;

  if (m['plus'] == true) {
    // Djup+: svaret byggs mening för mening. För varje mening skrivs upp till 5 kandidater från samma
    // början; den som bäst stämmer med de andra (konsensus) och som modellen är säker på väljs, och
    // nästa mening fortsätter därifrån. Tre likadana kandidater räcker – då är modellen överens med sig själv.
    final budgetDrafts = drafts, perSentence = 5, maxSentences = 12;
    final answer = <int>[];
    var answerLp = 0.0, ended = false;
    var cur = Float32List.fromList(saved);
    for (var seg = 0; seg < maxSentences && !stoppad(); seg++) {
      final base = model.pos;
      final cands = <_Draft>[], ids = <int>[];
      final rest = written >= budgetDrafts; // budgeten slut: resten av svaret skrivs i ett utkast
      final k = rest ? 1 : math.min(perSentence, budgetDrafts - written);
      for (var c = 0; c < k && !stoppad(); c++) {
        model.rewind(base);
        model.logits.setAll(0, cur);
        final t = c == 0 ? math.min(temperature, 0.35) : math.max(temperature, 0.5);
        final i = written, sg = seg;
        final d = _Draft.write(
          model,
          tok,
          rng,
          prompt,
          sources,
          limit - answer.length,
          t,
          topK,
          banned,
          stoppad,
          echo,
          prefix: answer,
          sentence: !rest,
          onPiece: (p) => send({'type': 'draft', 'i': i, 'n': budgetDrafts, 'seg': sg, 'text': p}),
        );
        written++;
        total += d.tokens.length;
        cands.add(d);
        ids.add(i);
        sources.add([...prompt, ...answer, ...d.tokens]);
        send({'type': 'draftEnd', 'i': i, 'score': d.sentenceMean, 'pruned': false});
        final texts = [for (final x in cands) x.text.trim()];
        if (texts.length >= 3 && texts.where((t) => t == texts.last).length >= 3) break;
      }
      if (cands.isEmpty) break;
      final cons = _consensus([for (final x in cands) x.text]);
      var bi = 0;
      var bs = double.negativeInfinity;
      for (var j = 0; j < cands.length; j++) {
        final x = cands[j];
        final sc =
            x.sentenceMean + 1.0 * cons[j] - 2.0 * _repetition([...answer, ...x.tokens]) - (x.tokens.length < 3 && !x.ended ? 0.5 : 0.0);
        if (sc > bs) {
          bs = sc;
          bi = j;
        }
      }
      final best = cands[bi];
      send({'type': 'segment', 'seg': seg, 'i': ids[bi], 'text': best.text});
      model.rewind(base);
      if (best.tokens.isNotEmpty) {
        model.eval(best.tokens); // den valda meningen läses in i ett enda pass
        cur = Float32List.fromList(model.logits);
        answer.addAll(best.tokens);
        answerLp += best._lpSum;
      }
      if (best.ended) {
        ended = true;
        break;
      }
      if (rest || answer.length >= limit || model.pos >= ctx - 2) break;
    }
    final whole = _Draft()
      ..tokens.addAll(answer)
      ..ended = ended;
    whole._lpSum = answerLp;
    chosenScore = whole.score;
  } else if (drafts <= 1) {
    final d = _Draft.write(
      model,
      tok,
      rng,
      prompt,
      sources,
      limit,
      temperature,
      topK,
      banned,
      stoppad,
      echo,
      onPiece: (p) => send({'type': 'token', 'text': p}),
    );
    total = d.tokens.length;
    written = 1;
    chosenScore = d.score;
  } else {
    _Draft? best;
    var bestIndex = 0;
    for (var i = 0; i < drafts && !stoppad(); i++) {
      if (i > 0) {
        model.rewind(p0);
        model.logits.setAll(0, saved);
      }
      // Första utkastet är försiktigt (låg temperatur), resten mer varierade.
      final t = i == 0 ? (temperature < 0.35 ? temperature : 0.35) : (temperature < 0.5 ? 0.5 : temperature);
      final d = _Draft.write(
        model,
        tok,
        rng,
        prompt,
        sources,
        limit,
        t,
        topK,
        banned,
        stoppad,
        echo,
        pruneBelow: best?.score,
        onPiece: (p) => send({'type': 'draft', 'i': i, 'n': drafts, 'text': p}),
      );
      total += d.tokens.length;
      written++;
      sources.add([...prompt, ...d.tokens]);
      send({'type': 'draftEnd', 'i': i, 'score': d.pruned ? -99.0 : d.score, 'pruned': d.pruned});
      if (!d.pruned && (best == null || d.score > best.score)) {
        best = d;
        bestIndex = i;
      }
    }
    if (best != null) {
      chosenScore = best.score;
      send({'type': 'chosen', 'i': bestIndex, 'text': best.text});
    }
  }
  final secs = (sw.elapsedMicroseconds - genStart) / 1e6;
  send({
    'type': 'done',
    'tokens': total,
    'seconds': secs,
    'prompt': prompt.length,
    'drafts': written,
    'passes': model.passes - passesStart,
    'echoAccepted': echo.accepted,
    'score': chosenScore,
  });
}

/// Ett utkast: tokens, text och modellens egen bedömning av det.
class _Draft {
  final List<int> tokens = [];
  final StringBuffer _text = StringBuffer();
  double _lpSum = 0, _endLp = 0;
  bool ended = false, pruned = false;

  String get text => _text.toString();
  double get meanLogprob => tokens.isEmpty ? -10 : _lpSum / tokens.length;

  /// Medel-logsannolikhet inklusive avslutet – så att även "svaret är klart" kan jämföras med en mening.
  double get sentenceMean {
    final n = tokens.length + (ended ? 1 : 0);
    return n == 0 ? -10 : (_lpSum + (ended ? _endLp : 0)) / n;
  }

  void _end(Float32List row, int endId) {
    ended = true;
    _endLp = row[endId] - _lse(row);
  }

  /// Andel upprepade tre-tokenföljder – små modeller fastnar gärna i slingor. Nyckeln är exakt även i
  /// JavaScript (under 2^53) för ordförråd upp till 65 536.
  double get repetition {
    if (tokens.length < 6) return 0;
    final seen = <int>{};
    var dup = 0;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (!seen.add((tokens[i] * 65536 + tokens[i + 1]) * 65536 + tokens[i + 2])) dup++;
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
  static _Draft write(
    Motor model,
    BpeTokenizer tok,
    math.Random rng,
    List<int> prompt,
    List<List<int>> sources,
    int limit,
    double temperature,
    int topK,
    Set<int> banned,
    bool Function() stoppad,
    _EchoStats echo, {
    double? pruneBelow,
    List<int> prefix = const [],
    bool sentence = false,
    required void Function(String) onPiece,
  }) {
    final d = _Draft();
    final decoder = StreamDecoder(tok);
    final ctx = model.context;
    final p0 = model.pos;
    var cur = Float32List.fromList(model.logits);
    List<int> recent() {
      final all = prefix.isEmpty ? d.tokens : [...prefix, ...d.tokens];
      return all.length > 64 ? all.sublist(all.length - 64) : all;
    }

    // Lägger till en token. Returnerar true om utkastet ska avslutas (sållat).
    bool emit(int x, Float32List row) {
      d.tokens.add(x);
      d._lpSum += row[x] - _lse(row); // logsannolikhet enligt modellens egen, ostraffade fördelning
      final piece = decoder.add(x);
      if (piece.isNotEmpty) {
        d._text.write(piece);
        onPiece(piece);
      }
      // Djup+: meningen är slut vid punkt, utrop eller fråga – men inte efter förkortningar (D.C., t.ex., bl.a.).
      if (sentence && d.tokens.length >= 3 && _sentenceEnd(d._text.toString())) return true;
      // Sålla: ett utkast som efter en bit är klart sämre än det bästa hittills avbryts.
      if (pruneBelow != null && d.tokens.length >= 24 && d.meanLogprob - 2.0 * d.repetition < pruneBelow - 0.6) {
        d.pruned = true;
        return true;
      }
      return false;
    }

    outer:
    while (d.tokens.length < limit && !stoppad()) {
      final dist = _Dist.of(cur, temperature, topK, recent(), banned);
      var prop = _lookup(sources, [...prompt, ...prefix, ...d.tokens], _maxProposal);
      final room = math.min(limit - d.tokens.length, ctx - model.pos - 1);
      if (prop.length > room) prop = room > 0 ? prop.sublist(0, room) : const [];
      int x;
      if (prop.isNotEmpty) {
        echo.proposed++;
        final x1 = prop[0];
        if (rng.nextDouble() < dist.prob(x1)) {
          echo.accepted++;
          if (x1 == tok.endId) {
            d._end(cur, tok.endId);
            break;
          }
          if (emit(x1, cur)) break;
          final rows = model.evalAll(prop); // rad j = fördelningen efter prop[j]
          for (var j = 1; j <= prop.length; j++) {
            final row = rows[j - 1];
            if (d.tokens.length >= limit || stoppad()) break outer;
            final pj = _Dist.of(row, temperature, topK, recent(), banned);
            if (j < prop.length && rng.nextDouble() < pj.prob(prop[j])) {
              echo.accepted++;
              if (prop[j] == tok.endId) {
                d._end(row, tok.endId);
                break outer;
              }
              if (emit(prop[j], row)) break outer;
              continue;
            }
            // Avslag, eller alla förslag godtagna: dra nästa token ur pj (utan det avvisade förslaget).
            final y = pj.sample(rng, without: j < prop.length ? prop[j] : null);
            model.rewind(p0 + d.tokens.length);
            if (y == tok.endId) {
              d._end(row, tok.endId);
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
        d._end(cur, tok.endId);
        break;
      }
      if (emit(x, cur) || model.pos >= ctx) break;
      model.eval([x]);
      cur = Float32List.fromList(model.logits);
    }
    return d;
  }
}

/// Hur mycket varje text liknar de andra (medel-Jaccard över ord) – "majoritetsrösten" för fritext.
List<double> _consensus(List<String> texts) {
  final re = RegExp(r'[\wåäöÅÄÖéü]+');
  final sets = [
    for (final t in texts)
      {
        for (final m in re.allMatches(t.toLowerCase()))
          if (m[0]!.length > 2) m[0]!,
      },
  ];
  return [
    for (var i = 0; i < sets.length; i++)
      sets.length < 2
          ? 0.0
          : [
                  for (var j = 0; j < sets.length; j++)
                    if (j != i) sets[i].union(sets[j]).isEmpty ? 0.0 : sets[i].intersection(sets[j]).length / sets[i].union(sets[j]).length,
                ].fold<double>(0, (a, b) => a + b) /
                (sets.length - 1),
  ];
}

/// Slutar texten en mening? "!" och "?" alltid; "." bara om sista ordet inte är en förkortning.
bool _sentenceEnd(String text) {
  final t = text.trimRight();
  if (t.endsWith('!') || t.endsWith('?')) return true;
  if (!t.endsWith('.')) return false;
  final words = t.split(RegExp(r'\s+'));
  final last = words.last.substring(0, words.last.length - 1);
  if (last.length <= 1 || last.contains('.')) return false; // "D.", "t.ex.", "bl.a."
  const abbr = {'ca', 'osv', 'resp', 'jfr', 'nr', 'st', 'kl', 'dvs', 'mfl', 'etc', 'tex'};
  return !abbr.contains(last.toLowerCase());
}

double _repetition(List<int> t) {
  if (t.length < 6) return 0;
  final seen = <int>{};
  var dup = 0;
  for (var i = 0; i + 2 < t.length; i++) {
    if (!seen.add((t[i] * 65536 + t[i + 1]) * 65536 + t[i + 2])) dup++;
  }
  return dup / (t.length - 2);
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
