// Byte-nivå BPE-tokenizer, samma algoritm som i AI Control Center och Lennart 3-träningen.
// Läser <id>.tok.json från tools/exportera_mobil.py.
import 'dart:convert';
import 'dart:typed_data';

class ChatTurn {
  final bool fromUser;
  final String text;
  const ChatTurn(this.fromUser, this.text);
}

class BpeTokenizer {
  final RegExp _pattern;
  final List<int> _byteToId;
  final Map<int, int> _rank = {}; // (a << 20 | b) -> rang
  final List<int> _result = [];
  final List<Uint8List> _tokens;
  final bool _escape;
  final Map<String, List<int>> _cache = {};
  late final int padId, userId, assistantId, endId;

  BpeTokenizer._(this._pattern, this._byteToId, this._tokens, this._escape);

  factory BpeTokenizer.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    final tokens = [for (final t in j['tokens'] as List) base64Decode(t as String)];
    final tok = BpeTokenizer._(RegExp(j['pattern'] as String, unicode: true),
        (j['byte_to_id'] as List).cast<int>(), tokens, j['escape_specials'] == true);
    final merges = j['merges'] as List;
    for (var i = 0; i < merges.length; i++) {
      final m = (merges[i] as List).cast<int>();
      tok._rank[(m[0] << 20) | m[1]] = i;
      tok._result.add(m[2]);
    }
    final s = j['special'] as Map<String, dynamic>;
    tok.padId = s['pad'] as int;
    tok.userId = s['user'] as int;
    tok.assistantId = s['assistant'] as int;
    tok.endId = s['end'] as int;
    return tok;
  }

  List<int> _bpe(String word) {
    var ids = [for (final b in utf8.encode(word)) _byteToId[b]];
    while (ids.length > 1) {
      var bestRank = -1, bestA = 0, bestB = 0;
      for (var i = 0; i < ids.length - 1; i++) {
        final r = _rank[(ids[i] << 20) | ids[i + 1]];
        if (r != null && (bestRank < 0 || r < bestRank)) {
          bestRank = r;
          bestA = ids[i];
          bestB = ids[i + 1];
        }
      }
      if (bestRank < 0) break;
      final merged = _result[bestRank];
      final out = <int>[];
      var i = 0;
      while (i < ids.length) {
        if (i < ids.length - 1 && ids[i] == bestA && ids[i + 1] == bestB) {
          out.add(merged);
          i += 2;
        } else {
          out.add(ids[i]);
          i += 1;
        }
      }
      ids = out;
    }
    return ids;
  }

  List<int> encode(String text) {
    if (_escape) text = text.replaceAll('<|', '< |');
    final out = <int>[];
    for (final m in _pattern.allMatches(text)) {
      final word = m.group(0)!;
      final ids = _cache[word] ??= _bpe(word);
      out.addAll(ids);
    }
    return out;
  }

  /// <|user|>fråga<|assistant|>svar<|end|> … och till sist <|assistant|> för nästa svar.
  List<int> encodeChat(List<ChatTurn> turns) {
    final out = <int>[];
    for (final t in turns) {
      if (t.fromUser) {
        out
          ..add(userId)
          ..addAll(encode(t.text.trim()));
      } else {
        out
          ..add(assistantId)
          ..addAll(encode(t.text.trim()))
          ..add(endId);
      }
    }
    out.add(assistantId);
    return out;
  }

  Uint8List bytesOf(int id) => id >= 0 && id < _tokens.length ? _tokens[id] : Uint8List(0);

  String decode(List<int> ids) =>
      utf8.decode([for (final i in ids) ...bytesOf(i)], allowMalformed: true);
}

/// Avkodar token för token och väntar när ett tecken är delat över flera tokens.
class StreamDecoder {
  final BpeTokenizer tok;
  final List<int> _pending = [];
  StreamDecoder(this.tok);

  String add(int id) {
    _pending.addAll(tok.bytesOf(id));
    var end = _pending.length;
    // Gå bakåt över en ofullständig UTF-8-sekvens i slutet.
    var i = _pending.length - 1, back = 0;
    while (i >= 0 && back < 4 && (_pending[i] & 0xC0) == 0x80) {
      i--;
      back++;
    }
    if (i >= 0) {
      final b = _pending[i];
      final need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
      if (need > 1 && _pending.length - i < need) end = i;
    }
    if (end == 0) return '';
    final text = utf8.decode(_pending.sublist(0, end), allowMalformed: true);
    _pending.removeRange(0, end);
    return text;
  }
}
