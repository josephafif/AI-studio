// Verktyg som Lennart kan använda när han arbetar agentiskt.
//
// Säkerhetsprinciper:
//  * Allt som rör filer sker bara inom en arbetsmapp som användaren själv har valt.
//  * Verktyg som ändrar något (skriver filer) kräver alltid användarens godkännande.
//  * Inga verktyg kör program eller går ut på nätet – sådant kräver egna, granskade verktyg.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'berakning.dart';

export 'berakning.dart' show VerktygsFel;

/// Det ett verktyg får tillgång till.
class AgentMiljo {
  final Directory? arbetsmapp;
  final DateTime Function() nu;

  /// Slumpkälla för tärning, lösenord m.m. Kryptografiskt säker utom i tester.
  final math.Random slump;
  AgentMiljo({this.arbetsmapp, DateTime Function()? nu, math.Random? slump})
    : nu = nu ?? DateTime.now,
      slump = slump ?? math.Random.secure();
}

abstract class Verktyg {
  String get namn;
  String get beskrivning;

  /// Argumentens namn → beskrivning.
  Map<String, String> get parametrar;

  /// Ändrar verktyget något utanför samtalet? Då måste användaren godkänna varje anrop.
  bool get andrar => false;

  /// Ändrar just det här anropet något? För verktyg där bara vissa åtgärder ändrar (t.ex. listor).
  bool andrarMed(Map<String, dynamic> arg) => andrar;

  /// Behöver verktyget en arbetsmapp?
  bool get behoverMapp => false;

  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo);
}

/// Alla inbyggda verktyg.
List<Verktyg> standardVerktyg() => [
  Klocka(),
  Kalender(),
  DagarTill(),
  Helgdagar(),
  Raknare(),
  Omvandla(),
  Slumpa(),
  Losenord(),
  Textinfo(),
  AttGora(),
  Anteckna(),
  ListaMapp(),
  LasFil(),
  SokIFiler(),
  SkrivFil(),
];

String _str(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v == null || (v is String && v.trim().isEmpty)) throw VerktygsFel('Argumentet "$k" saknas');
  return v.toString();
}

// ───────────────────────────────────────────────────────── klocka och kalender
class Klocka extends Verktyg {
  @override
  String get namn => 'klocka';
  @override
  String get beskrivning => 'Ger dagens datum, veckodag och klockslag.';
  @override
  Map<String, String> get parametrar => {};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async => klockText(miljo.nu());
}

class Kalender extends Verktyg {
  @override
  String get namn => 'kalender';
  @override
  String get beskrivning => 'Veckodag, veckonummer och dagnummer för ett datum, eller för ett datum ett antal dagar framåt eller bakåt.';
  @override
  Map<String, String> get parametrar => {
    'datum': 'idag, ÅÅÅÅ-MM-DD, "24 december" eller en högtid',
    'plus_dagar': 'valfritt antal dagar framåt (negativt bakåt)',
  };
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final plus = arg['plus_dagar'];
    final n = plus == null ? 0 : (plus is num ? plus.toInt() : int.tryParse(plus.toString()));
    if (n == null || n.abs() > 100000) throw VerktygsFel('"plus_dagar" måste vara ett heltal');
    return kalender((arg['datum'] ?? 'idag').toString(), n, miljo.nu());
  }
}

class Helgdagar extends Verktyg {
  @override
  String get namn => 'helgdagar';
  @override
  String get beskrivning => 'Sveriges röda dagar och aftnar ett visst år, och nästa röda dag.';
  @override
  Map<String, String> get parametrar => {'ar': 'valfritt årtal, annars i år'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final a = arg['ar'];
    final ar = a == null ? null : (a is num ? a.toInt() : int.tryParse(a.toString()));
    if (a != null && ar == null) throw VerktygsFel('"ar" måste vara ett årtal');
    return helgdagar(ar, miljo.nu());
  }
}

// ───────────────────────────────────────────────────────── räknare
/// Räknar ut ett uttryck med + − × ÷, ^, parenteser, procent och funktionerna sqrt, abs, round.
/// Egen tolkare – kör aldrig kod.
class Raknare extends Verktyg {
  @override
  String get namn => 'raknare';
  @override
  String get beskrivning => 'Räknar ut ett matematiskt uttryck, t.ex. "(12+8)*3/4", "15%*2300" eller "sqrt(2)".';
  @override
  Map<String, String> get parametrar => {'uttryck': 'uttrycket som ska räknas ut'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async => rakna(_str(arg, 'uttryck'));
}

class Omvandla extends Verktyg {
  @override
  String get namn => 'omvandla';
  @override
  String get beskrivning => 'Räknar om mellan enheter: längd, vikt, volym, area, hastighet, tid, data, energi och temperatur.';
  @override
  Map<String, String> get parametrar => {
    'varde': 'talet',
    'fran': 'enheten det står i, t.ex. mil',
    'till': 'enheten det ska bli, t.ex. km',
  };
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final v = arg['varde'];
    final tal = v is num ? v.toDouble() : double.tryParse((v ?? '').toString().replaceAll(',', '.'));
    if (tal == null) throw VerktygsFel('"varde" måste vara ett tal');
    return omvandla(tal, _str(arg, 'fran'), _str(arg, 'till'));
  }
}

// ───────────────────────────────────────────────────────── slump, lösenord, text
class Slumpa extends Verktyg {
  @override
  String get namn => 'slumpa';
  @override
  String get beskrivning => 'Slår tärning, singlar slant, drar ett tal eller väljer mellan alternativ.';
  @override
  Map<String, String> get parametrar => {
    'typ': 'tarning, mynt, tal eller valj',
    'antal': 'antal tärningar',
    'sidor': 'sidor per tärning',
    'fran': 'lägsta tal',
    'till': 'högsta tal',
    'alternativ': 'lista att välja ur',
  };
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async => slumpa(arg, miljo.slump);
}

class Losenord extends Verktyg {
  @override
  String get namn => 'losenord';
  @override
  String get beskrivning => 'Skapar ett starkt, slumpat lösenord direkt i appen. Det skickas ingenstans.';
  @override
  Map<String, String> get parametrar => {'langd': 'antal tecken, 8–64 (standard 20)'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final l = arg['langd'];
    final langd = l == null ? 20 : (l is num ? l.toInt() : int.tryParse(l.toString()));
    if (langd == null) throw VerktygsFel('"langd" måste vara ett heltal');
    return losenord(langd, miljo.slump);
  }
}

class Textinfo extends Verktyg {
  @override
  String get namn => 'textinfo';
  @override
  String get beskrivning => 'Räknar ord, tecken och meningar i en text och uppskattar lästiden.';
  @override
  Map<String, String> get parametrar => {'text': 'texten'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async => textinfo(_str(arg, 'text'));
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

// ───────────────────────────────────────────────────────── anteckningar
/// Lägger till en rad i anteckningar.md i arbetsmappen, med datum och tid.
class Anteckna extends Verktyg {
  static const fil = 'anteckningar.md';
  @override
  String get namn => 'anteckna';
  @override
  String get beskrivning => 'Sparar en anteckning (med datum) i anteckningar.md.';
  @override
  Map<String, String> get parametrar => {'text': 'det som ska antecknas'};
  @override
  bool get andrar => true;
  @override
  bool get behoverMapp => true;
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final text = _str(arg, 'text').replaceAll('\n', ' ').trim();
    if (text.length > 2000) throw VerktygsFel('Anteckningen är för lång');
    final f = _inuti(miljo, fil);
    final d = miljo.nu();
    String two(int n) => n.toString().padLeft(2, '0');
    final rad = '- ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}.${two(d.minute)} – $text\n';
    await f.parent.create(recursive: true);
    await f.writeAsString(rad, mode: FileMode.append);
    final antal = (await f.readAsLines()).where((l) => l.startsWith('- ')).length;
    return 'Sparade anteckningen ($antal i $fil)';
  }
}

// ───────────────────────────────────────────────────────── dagar till
/// Räknar dagar till ett datum eller en högtid.
class DagarTill extends Verktyg {
  @override
  String get namn => 'dagar_till';
  @override
  String get beskrivning => 'Räknar dagar till (eller sedan) ett datum eller en högtid som jul, påsk, midsommar eller lucia.';
  @override
  Map<String, String> get parametrar => {'datum': 'ÅÅÅÅ-MM-DD, "24 december" eller en högtid'};
  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async => dagarTill(_str(arg, 'datum'), miljo.nu());
}

// ───────────────────────────────────────────────────────── listor
/// Att-göra-listan och inköpslistan, som markdown-checklistor i arbetsmappen.
class AttGora extends Verktyg {
  static const filer = {'att-gora': 'att-gora.md', 'inkop': 'inkopslista.md'};
  static const namnPa = {'att-gora': 'att-göra-listan', 'inkop': 'inköpslistan'};
  @override
  String get namn => 'att_gora';
  @override
  String get beskrivning => 'Att-göra-lista och inköpslista: lägga till, visa, bocka av och rensa.';
  @override
  Map<String, String> get parametrar => {
    'atgard': 'lagg_till, visa, klar eller rensa',
    'text': 'det som ska läggas till eller bockas av (nummer eller text)',
    'lista': 'att-gora eller inkop',
  };
  @override
  bool get andrar => true;
  @override
  bool andrarMed(Map<String, dynamic> arg) => arg['atgard'] != 'visa';
  @override
  bool get behoverMapp => true;

  @override
  Future<String> kor(Map<String, dynamic> arg, AgentMiljo miljo) async {
    final lista = filer.containsKey(arg['lista']) ? arg['lista'] as String : 'att-gora';
    final f = _inuti(miljo, filer[lista]!);
    final listnamn = namnPa[lista]!;
    final rader = await f.exists() ? (await f.readAsLines()).where((l) => l.trim().isNotEmpty).toList() : <String>[];
    final punkter = [
      for (final r in rader)
        if (RegExp(r'^- \[[ xX]\] ').hasMatch(r)) r,
    ];
    Future<void> spara(List<String> ny) async {
      await f.parent.create(recursive: true);
      await f.writeAsString(ny.isEmpty ? '' : '${ny.join('\n')}\n');
    }

    String text(String rad) => rad.substring(6).trim();
    bool klar(String rad) => rad[3] != ' ';
    switch ((arg['atgard'] ?? 'visa').toString()) {
      case 'lagg_till':
        final t = _str(arg, 'text').trim();
        final saker = (lista == 'inkop' ? t.split(RegExp(r'\s*,\s*|\s+och\s+|\n')) : t.split(RegExp(r'\s*;\s*|\n')))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (saker.isEmpty) throw VerktygsFel('Inget att lägga till');
        if (punkter.length + saker.length > 500) throw VerktygsFel('Listan är full');
        await spara([...punkter, for (final x in saker) '- [ ] ${x.length > 300 ? x.substring(0, 300) : x}']);
        return saker.length == 1
            ? 'Lade till "${saker.first}" på $listnamn'
            : 'Lade till ${saker.length} saker på $listnamn: ${saker.join(', ')}';
      case 'visa':
        if (punkter.isEmpty) return 'Listan är tom ($listnamn)';
        return [for (var i = 0; i < punkter.length; i++) '${i + 1}. [${klar(punkter[i]) ? 'x' : ' '}] ${text(punkter[i])}'].join('\n');
      case 'klar':
        final q = _str(arg, 'text').trim().toLowerCase();
        final nr = int.tryParse(q);
        var i = nr != null ? nr - 1 : punkter.indexWhere((p) => !klar(p) && text(p).toLowerCase() == q);
        if (nr == null && i < 0) i = punkter.indexWhere((p) => !klar(p) && text(p).toLowerCase().contains(q));
        if (i < 0 || i >= punkter.length) throw VerktygsFel('Hittade inget på $listnamn som matchar "$q"');
        final ny = [...punkter];
        ny[i] = '- [x] ${text(punkter[i])}';
        await spara(ny);
        final kvar = ny.where((p) => !klar(p)).length;
        return 'Bockade av "${text(punkter[i])}". $kvar kvar på $listnamn';
      case 'rensa':
        final kvar = punkter.where((p) => !klar(p)).toList();
        await spara(kvar);
        return 'Tog bort ${punkter.length - kvar.length} avbockade från $listnamn';
    }
    throw VerktygsFel('Okänd åtgärd – välj lagg_till, visa, klar eller rensa');
  }
}
