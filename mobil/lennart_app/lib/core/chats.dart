// Sparade samtal (JSON i appens egen lagring).
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Message {
  final bool fromUser;
  String text;
  String? meta;
  bool error;
  Message(this.fromUser, this.text, {this.meta, this.error = false});
  Map<String, dynamic> toJson() => {'u': fromUser, 't': text, if (meta != null) 'm': meta, if (error) 'e': true};
  factory Message.fromJson(Map<String, dynamic> j) =>
      Message(j['u'] as bool, j['t'] as String, meta: j['m'] as String?, error: j['e'] == true);
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
  late final File _file;
  final List<Conversation> items = [];

  Future<void> open() async {
    _file = File('${(await getApplicationSupportDirectory()).path}/samtal.json');
    if (await _file.exists()) {
      try {
        final list = jsonDecode(await _file.readAsString()) as List;
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

  Future<void> _write() => _file.writeAsString(jsonEncode([for (final c in items) c.toJson()]));
}
