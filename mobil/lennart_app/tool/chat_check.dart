// Skriver token-id:n för ett samtal enligt tokenizerns samtalsmall: dart run tool/chat_check.dart <tok.json> <samtal.json>
// samtal.json: [[true, "fråga"], [false, "svar"], ...]
import 'dart:convert';
import 'dart:io';
import '../lib/core/tokenizer.dart';

void main(List<String> a) {
  final tok = BpeTokenizer.fromJson(File(a[0]).readAsStringSync());
  final turns = [for (final t in jsonDecode(File(a[1]).readAsStringSync()) as List) ChatTurn(t[0] as bool, t[1] as String)];
  print(jsonEncode({'ids': tok.encodeChat(turns), 'banned': tok.banned.toList()..sort()}));
}
