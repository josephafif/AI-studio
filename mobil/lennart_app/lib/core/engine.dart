// Kör modellen i en egen isolat så att gränssnittet aldrig fryser medan Lennart tänker.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'ffi.dart';
import 'generering.dart';
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
  djup('Djup', 'Skriver upp till 6 utkast, sållar bort svaga tidigt', 6),
  djupPlus('Djup+', 'Bygger svaret mening för mening ur upp till 20 utkast', 20);

  /// Djup+ väljer per mening i stället för hela svar.
  bool get sentenceWise => this == Effort.djupPlus;

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
    effort: effort ?? this.effort,
  );
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
  final int segment; // mening (bara Djup+), annars -1
  final String text;
  GenDraft(this.index, this.total, this.text, {this.segment = -1});
}

/// Djup+: en mening är vald (utkast [index]) och läggs till i svaret.
class GenSegment extends GenEvent {
  final int segment, index;
  final String text;
  GenSegment(this.segment, this.index, this.text);
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
  final double? score; // modellens egen säkerhet för svaret (se _Draft.score i generering.dart)
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
    loadedId = null; // den förra modellen släpps i isolaten innan den nya läses in
    _cmd!.send({'cmd': 'load', 'model': modelPath, 'tok': tokenizerPath, 'threads': threads});
    final m = await reply;
    if (m['type'] == 'loadError') throw StateError((m['message'] as String).replaceFirst('Bad state: ', ''));
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
          out.add(GenDraft(m['i'] as int, m['n'] as int, m['text'] as String, segment: (m['seg'] as int?) ?? -1));
        case 'segment':
          out.add(GenSegment(m['seg'] as int, m['i'] as int, m['text'] as String));
        case 'draftEnd':
          out.add(GenDraftEnd(m['i'] as int, (m['score'] as num).toDouble(), m['pruned'] as bool));
        case 'chosen':
          out.add(GenChosen(m['i'] as int, m['text'] as String));
        case 'done':
          out.add(
            GenDone(
              m['tokens'] as int,
              (m['seconds'] as num).toDouble(),
              m['prompt'] as int,
              m['drafts'] as int,
              passes: (m['passes'] as int?) ?? 0,
              score: (m['score'] as num?)?.toDouble(),
            ),
          );
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
      'turns': [
        for (final t in turns) [t.fromUser, t.text],
      ],
      'temperature': s.temperature,
      'maxTokens': s.maxTokens,
      'topK': s.topK,
      'drafts': s.effort.drafts,
      'plus': s.effort.sentenceWise,
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
        final stop = Pointer<Int32>.fromAddress(m['stop'] as int);
        if (model == null || tok == null) {
          toUi.send({'type': 'genError', 'message': 'Ingen modell är inläst. Välj en modell som fungerar, eller uppdatera appen om modellen är nyare än den.'});
          return;
        }
        generera(model!, tok!, m, toUi.send, () => stop.value != 0);
      } catch (e) {
        toUi.send({'type': 'genError', 'message': '$e'});
      }
    }
  });
}
