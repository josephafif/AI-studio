// Kör: dart run tool/tok_check.dart <tok.json> <texter.json>  → skriver token-id:n som JSON
import 'dart:convert';
import 'dart:io';
import '../lib/core/tokenizer.dart';

void main(List<String> a) {
  final tok = BpeTokenizer.fromJson(File(a[0]).readAsStringSync());
  final texts = (jsonDecode(File(a[1]).readAsStringSync()) as List).cast<String>();
  final out = <Object>[];
  for (final t in texts) {
    final ids = tok.encode(t);
    final dec = StreamDecoder(tok);
    final streamed = ids.map(dec.add).join();
    out.add({'ids': ids, 'roundtrip': tok.decode(ids) == t, 'stream': streamed == tok.decode(ids)});
  }
  print(jsonEncode(out));
}
