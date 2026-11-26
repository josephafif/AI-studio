// Sparade samtal (JSON i appens egen lagring).
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ett utkast som Lennart skrev medan den tänkte.
class Draft {
  String text;
  double? score;
  bool pruned;
  Draft(this.text, {this.score, this.pruned = false});
  Map<String, dynamic> toJson() => {'t': text, if (score != null) 's': score, if (pruned) 'p': true};
  factory Draft.fromJson(Map<String, dynamic> j) =>
      Draft(j['t'] as String, score: (j['s'] as num?)?.toDouble(), pruned: j['p'] == true);
}

class Message {
  final bool fromUser;
  String text;
  String? meta;
  bool error;
  final List<Draft> drafts;
  int? chosen;
  double? thoughtSeconds;
  bool uncertain;
  bool reveal = false; // skriv fram texten med en animation (inte sparat)
  Message(this.fromUser, this.text,
      {this.meta, this.error = false, List<Draft>? drafts, this.chosen, this.thoughtSeconds, this.uncertain = false})
      : drafts = drafts ?? [];
  Map<String, dynamic> toJson() => {
        'u': fromUser,
        't': text,
        if (meta != null) 'm': meta,
        if (error) 'e': true,
        if (drafts.isNotEmpty) 'd': [for (final d in drafts) d.toJson()],
        if (chosen != null) 'c': chosen,
        if (thoughtSeconds != null) 'th': thoughtSeconds,
        if (uncertain) 'o': true,
      };
  factory Message.fromJson(Map<String, dynamic> j) => Message(j['u'] as bool, j['t'] as String,
      meta: j['m'] as String?,
      error: j['e'] == true,
      drafts: [for (final d in (j['d'] as List?) ?? []) Draft.fromJson(d as Map<String, dynamic>)],
      chosen: j['c'] as int?,
      thoughtSeconds: (j['th'] as num?)?.toDouble(),
      uncertain: j['o'] == true);
}

class Conversation {
  final String id;
  String title;
  String modelId;
  DateTime updated;
  final List<Message> messages;
  Conversation(this.id, this.title, this.modelId, this.updated, this.messages);

  factory Conversation.empty(String modelId) =>
      Conversation(DateTime.now().microsecondsSinceEpoch.toString(), 'Nytt samtal', modelId, DateTime.now(), []);

  Map<String, dynamic> toJson() => {
        'id': id, 'title': title, 'model': modelId, 'updated': updated.toIso8601String(),
        'messages': [for (final m in messages) m.toJson()],
      };
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
      j['id'] as String, j['title'] as String, j['model'] as String, DateTime.parse(j['updated'] as String),
      [for (final m in j['messages'] as List) Message.fromJson(m as Map<String, dynamic>)]);
}

class ChatStore {
  File? _file;
  final List<Conversation> items = [];

  Future<void> open() async {
    final file = _file = File('${(await getApplicationSupportDirectory()).path}/samtal.json');
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        items.addAll([for (final c in list) Conversation.fromJson(c as Map<String, dynamic>)]);
        items.sort((a, b) => b.updated.compareTo(a.updated));
      } catch (_) {/* trasig fil – börja om */}
    }
  }

  Future<void> save(Conversation c) async {
    if (c.messages.isEmpty) return;
    c.updated = DateTime.now();
    if (c.title == 'Nytt samtal') {
      final first = c.messages.first.text.trim().replaceAll('\n', ' ');
      c.title = first.length > 48 ? '${first.substring(0, 48)}…' : first;
    }
    items.removeWhere((x) => x.id == c.id);
    items.insert(0, c);
    await _write();
  }

  Future<void> delete(Conversation c) async {
    items.removeWhere((x) => x.id == c.id);
    await _write();
  }

  Future<void> _write() async => _file?.writeAsString(jsonEncode([for (final c in items) c.toJson()]));
}
