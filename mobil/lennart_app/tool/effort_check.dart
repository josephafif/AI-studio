// Jämför effortnivåerna på en modell: dart run tool/effort_check.dart <mapp> <modell-id>
import 'dart:io';

import '../lib/core/engine.dart';
import '../lib/core/tokenizer.dart';

Future<void> main(List<String> a) async {
  final dir = a[0], id = a[1];
  final engine = LennartEngine();
  await engine.load(id, '$dir/$id.lmod', '$dir/$id.tok.json');
  final questions = a.length > 2
      ? a.sublist(2)
      : [
          'Vad är nätfiske?',
          'Berätta om Astrid Lindgren.',
          'Hur skapar jag ett starkt lösenord?',
          'Vad ska jag laga till middag?',
        ];
  for (final q in questions) {
    stdout.writeln('\n=== $q');
    for (final effort in Effort.values) {
      final drafts = <int, StringBuffer>{};
      final scores = <int, String>{};
      final answer = StringBuffer();
      GenDone? done;
      await for (final e in engine.generate([ChatTurn(true, q)], GenSettings(temperature: 0.7, maxTokens: 120, topK: 40, effort: effort))) {
        switch (e) {
          case GenToken(:final text):
            answer.write(text);
          case GenDraft(:final index, :final text):
            (drafts[index] ??= StringBuffer()).write(text);
          case GenDraftEnd(:final index, :final score, :final pruned):
            scores[index] = pruned ? 'sållad' : score.toStringAsFixed(2);
          case GenChosen(:final text, :final index):
            answer.write(text);
            scores[index] = '${scores[index]} ← vald';
          case GenDone():
            done = e;
          case GenError(:final message):
            answer.write('FEL: $message');
        }
      }
      stdout.writeln('--- ${effort.label}: ${done?.tokens} tokens, ${done?.passes} pass, ${done?.drafts} utkast, ${done?.seconds.toStringAsFixed(1)} s');
      for (final i in drafts.keys) {
        final t = drafts[i].toString().replaceAll('\n', ' ');
        stdout.writeln('   [$i ${scores[i]}] ${t.length > 160 ? '${t.substring(0, 160)}…' : t}');
      }
      stdout.writeln('   SVAR: ${answer.toString().trim()}');
    }
  }
  exit(0);
}
