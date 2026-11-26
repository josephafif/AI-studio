// Verktyg som Lennart kan använda när han arbetar agentiskt.
//
// Säkerhetsprinciper:
//  * Allt som rör filer sker bara inom en arbetsmapp som användaren själv har valt.
//  * Verktyg som ändrar något (skriver filer) kräver alltid användarens godkännande.
//  * Inga verktyg kör program eller går ut på nätet – sådant kräver egna, granskade verktyg.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Det ett verktyg får tillgång till.
class AgentMiljo {
  final Directory? arbetsmapp;
  final DateTime Function() nu;
  AgentMiljo({this.arbetsmapp, DateTime Function()? nu}) : nu = nu ?? DateTime.now;
}

class VerktygsFel implements Exception {
  final String meddelande;
  VerktygsFel(this.meddelande);
  @override
  String toString() => meddelande;
}

abstract class Verktyg {
  String get namn;
  String get beskrivning;

  /// Argumentens namn → beskrivning.
  Map<String, String> get parametrar;

  /// Ändrar verktyget något utanför samtalet? Då måste användaren godkänna varje anrop.
  bool get andrar => false;

  /// Behöver verktyget en arbetsmapp?
  bool get behoverMapp => false;

  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo);
}

/// Alla inbyggda verktyg.
List<Verktyg> standardVerktyg() => [Klocka(), Raknare(), ListaMapp(), LasFil(), SokIFiler(), SkrivFil()];

String _str(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v == null || (v is String && v.trim().isEmpty)) throw VerktygsFel('Argumentet "$k" saknas');
  return v.toString();
}

// ───────────────────────────────────────────────────────── klocka
class Klocka extends Verktyg {
  static const _dagar = ['måndag', 'tisdag', 'onsdag', 'torsdag', 'fredag', 'lördag', 'söndag'];
  static const _manader = [
    'januari',
    'februari',
    'mars',
    'april',
    'maj',
    'juni',
    'juli',
    'augusti',
    'september',
    'oktober',
    'november',
    'december',
  ];
  @override
  String get namn => 'klocka';
  @override
  String get beskrivning => 'Ger dagens datum, veckodag och klockslag.';
  @override
  Map<String, String> get parametrar => {};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final d = miljo.nu();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_dagar[d.weekday - 1]} ${d.day} ${_manader[d.month - 1]} ${d.year}, klockan ${two(d.hour)}.${two(d.minute)}';
  }
}

// ───────────────────────────────────────────────────────── räknare
/// Räknar ut ett uttryck med + − × ÷, ^, parenteser, procent och funktionerna sqrt, abs, round.
/// Egen tolkare – kör aldrig kod.
class Raknare extends Verktyg {
  @override
  String get namn => 'raknare';
  @override
  String get beskrivning => 'Räknar ut ett matematiskt uttryck, t.ex. "(12+8)*3/4" eller "sqrt(2)".';
  @override
  Map<String, String> get parametrar => {'uttryck': 'uttrycket som ska räknas ut'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final v = _Tolk(_str(arg, 'uttryck')).las();
    if (v.isNaN || v.isInfinite) throw VerktygsFel('Uttrycket har inget ändligt värde');
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    return double.parse(v.toStringAsPrecision(12)).toString().replaceAll('.', ',');
  }
}

class _Tolk {
  final String s;
  int i = 0;
  _Tolk(String text) : s = text.replaceAll('×', '*').replaceAll('÷', '/').replaceAll('−', '-').replaceAll(',', '.').replaceAll(' ', '');

  double las() {
    if (s.length > 200) throw VerktygsFel('Uttrycket är för långt');
    final v = _summa();
    if (i != s.length) throw VerktygsFel('Förstår inte "${s.substring(i)}"');
    return v;
  }

  bool _ta(String c) {
    if (i < s.length && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  double _summa() {
    var v = _produkt();
    while (true) {
      if (_ta('+')) {
        v += _produkt();
      } else if (_ta('-')) {
        v -= _produkt();
      } else {
        return v;
      }
    }
  }

  double _produkt() {
    var v = _potens();
    while (true) {
      if (_ta('*')) {
        v *= _potens();
      } else if (_ta('/')) {
        final d = _potens();
        if (d == 0) throw VerktygsFel('Division med noll');
        v /= d;
      } else {
        return v;
      }
    }
  }

  double _potens() {
    final b = _unar();
    if (_ta('^')) return math.pow(b, _potens()).toDouble(); // högerassociativ
    return b;
  }

  double _unar() {
    if (_ta('-')) return -_unar();
    if (_ta('+')) return _unar();
    var v = _atom();
    if (_ta('%')) v /= 100;
    return v;
  }

  double _atom() {
    if (_ta('(')) {
      final v = _summa();
      if (!_ta(')')) throw VerktygsFel('En parentes stängs inte');
      return v;
    }
    for (final f in ['sqrt', 'abs', 'round']) {
      if (s.startsWith('$f(', i)) {
        i += f.length + 1;
        final v = _summa();
        if (!_ta(')')) throw VerktygsFel('En parentes stängs inte');
        return switch (f) {
          'sqrt' => v < 0 ? throw VerktygsFel('Roten ur ett negativt tal') : math.sqrt(v),
          'abs' => v.abs(),
          _ => v.roundToDouble(),
        };
      }
    }
    if (s.startsWith('pi', i)) {
      i += 2;
      return math.pi;
    }
    final m = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(s, i);
    if (m == null) throw VerktygsFel(i < s.length ? 'Förstår inte "${s.substring(i)}"' : 'Uttrycket tar slut för tidigt');
    i = m.end;
    return double.parse(m[0]!);
  }
}

// ───────────────────────────────────────────────────────── filer i arbetsmappen
/// Gör en sökväg i arbetsmappen säker: relativ, inga "..", och den färdiga sökvägen ligger inuti mappen.
File _inuti(AgentMiljo m, String relativ) => File(_sakerSokvag(m, relativ));
Directory _mappInuti(AgentMiljo m, String relativ) => Directory(_sakerSokvag(m, relativ));

String _sakerSokvag(AgentMiljo m, String relativ) {
  final rot = m.arbetsmapp;
  if (rot == null) throw VerktygsFel('Ingen arbetsmapp är vald – välj en under Inställningar → Agent');
  final r = relativ.replaceAll('\\', '/').trim();
  if (r.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(r) || r.split('/').contains('..')) {
    throw VerktygsFel('Bara sökvägar inuti arbetsmappen är tillåtna');
  }
  final base = rot.absolute.path;
  final full = r.isEmpty || r == '.' ? base : '$base${Platform.pathSeparator}${r.replaceAll('/', Platform.pathSeparator)}';
  // Skydd mot symboliska länkar ut ur mappen: jämför de verkliga sökvägarna när filen finns.
  final type = FileSystemEntity.typeSync(full);
  if (type != FileSystemEntityType.notFound) {
    final real = type == FileSystemEntityType.directory
        ? Directory(full).resolveSymbolicLinksSync()
        : File(full).resolveSymbolicLinksSync();
    final realBase = rot.resolveSymbolicLinksSync();
    if (!(real == realBase || real.startsWith('$realBase${Platform.pathSeparator}'))) {
      throw VerktygsFel('Sökvägen pekar ut ur arbetsmappen');
    }
  }
  return full;
}

String _relativ(AgentMiljo m, FileSystemEntity e) {
  final base = m.arbetsmapp!.absolute.path;
  var p = e.absolute.path;
  if (p.startsWith(base)) p = p.substring(base.length);
  return p.replaceAll('\\', '/').replaceFirst(RegExp(r'^/'), '');
}

class ListaMapp extends Verktyg {
  @override
  String get namn => 'lista_mapp';
  @override
  String get beskrivning => 'Visar filer och mappar i arbetsmappen (eller en undermapp).';
  @override
  Map<String, String> get parametrar => {'mapp': 'undermapp, tomt för arbetsmappen'};
  @override
  bool get behoverMapp => true;
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final d = _mappInuti(miljo, (arg['mapp'] ?? '').toString());
    if (!await d.exists()) throw VerktygsFel('Mappen finns inte');
    final rader = <String>[];
    await for (final e in d.list()) {
      final namn = e.uri.pathSegments.where((x) => x.isNotEmpty).last;
      if (namn.startsWith('.')) continue;
      rader.add(e is Directory ? '$namn/' : '$namn (${_storlek((e as File).lengthSync())})');
      if (rader.length >= 200) break;
    }
    rader.sort();
    return rader.isEmpty ? '(tom mapp)' : rader.join('\n');
  }
}

String _storlek(int b) => b < 1024
    ? '$b B'
    : b < 1024 * 1024
    ? '${(b / 1024).toStringAsFixed(1)} kB'
    : '${(b / 1048576).toStringAsFixed(1)} MB';

class LasFil extends Verktyg {
  static const maxByte = 20000;
  @override
  String get namn => 'las_fil';
  @override
  String get beskrivning => 'Läser en textfil i arbetsmappen (högst 20 kB).';
  @override
  Map<String, String> get parametrar => {'fil': 'sökväg i arbetsmappen'};
  @override
  bool get behoverMapp => true;
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final f = _inuti(miljo, _str(arg, 'fil'));
    if (!await f.exists()) throw VerktygsFel('Filen finns inte');
    final bytes = await f.openRead(0, maxByte).fold<List<int>>([], (a, b) => a..addAll(b));
    if (bytes.contains(0)) throw VerktygsFel('Filen verkar inte vara en textfil');
    final text = utf8.decode(bytes, allowMalformed: true);
    return await f.length() > maxByte ? '$text\n… (filen är längre – bara början visas)' : text;
  }
}

class SokIFiler extends Verktyg {
  @override
  String get namn => 'sok_i_filer';
  @override
  String get beskrivning => 'Söker efter en text i arbetsmappens textfiler och visar träffarna med radnummer.';
  @override
  Map<String, String> get parametrar => {'text': 'det som ska hittas'};
  @override
  bool get behoverMapp => true;
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final q = _str(arg, 'text').toLowerCase();
    final rot = _mappInuti(miljo, '');
    final traffar = <String>[];
    var filer = 0;
    await for (final e in rot.list(recursive: true, followLinks: false)) {
      if (e is! File || filer > 2000 || traffar.length >= 30) continue;
      if (_relativ(miljo, e).split('/').any((p) => p.startsWith('.'))) continue;
      if (await e.length() > 2000000) continue;
      filer++;
      List<String> rader;
      try {
        rader = utf8.decode(await e.readAsBytes(), allowMalformed: true).split('\n');
      } catch (_) {
        continue;
      }
      for (var n = 0; n < rader.length && traffar.length < 30; n++) {
        if (rader[n].toLowerCase().contains(q)) {
          final rad = rader[n].trim();
          traffar.add('${_relativ(miljo, e)}:${n + 1}: ${rad.length > 160 ? '${rad.substring(0, 160)}…' : rad}');
        }
      }
    }
    return traffar.isEmpty ? 'Inga träffar på "$q" ($filer filer genomsökta)' : traffar.join('\n');
  }
}

class SkrivFil extends Verktyg {
  @override
  String get namn => 'skriv_fil';
  @override
  String get beskrivning => 'Skriver en textfil i arbetsmappen. Kräver alltid ditt godkännande.';
  @override
  Map<String, String> get parametrar => {'fil': 'sökväg i arbetsmappen', 'innehall': 'filens nya innehåll'};
  @override
  bool get andrar => true;
  @override
  bool get behoverMapp => true;
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final f = _inuti(miljo, _str(arg, 'fil'));
    final innehall = (arg['innehall'] ?? '').toString();
    if (innehall.length > 200000) throw VerktygsFel('Innehållet är för stort');
    await f.parent.create(recursive: true);
    final fanns = await f.exists();
    await f.writeAsString(innehall);
    return '${fanns ? 'Skrev över' : 'Skapade'} ${_relativ(miljo, f)} (${_storlek(innehall.length)})';
  }
}
