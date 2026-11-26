// Verktygssinnet: känner igen frågor på vanlig svenska som ett verktyg svarar bättre på än språkmodellen
// (klockan, uträkningar, datum, enheter, listor …) och gör om dem till verktygsanrop.
//
// Lennart 3.x är inte tränad på verktygsprotokollet och kan inte själv avgöra när ett verktyg behövs.
// Tills Lennart 4 har lärt sig det gör appen bedömningen åt honom. Anropet, resultatet och svaret visas i
// samtalet på samma sätt som när modellen själv anropar ett verktyg.
//
// Tolken är medvetet försiktig: hellre att Lennart svarar själv än att ett verktyg körs på en fråga som
// inte gällde det. Ingen dart:io, så samma kod kompileras till JavaScript för webbversionen.
import 'berakning.dart';

class Avsikt {
  final String namn;
  final Map<String, dynamic> argument;

  /// Det Lennart säger innan verktyget körs.
  final String fore;
  const Avsikt(this.namn, this.argument, this.fore);
  @override
  String toString() => '$namn $argument';
}

/// Verktygens namn som de visas i samtalet.
const visningsnamn = {
  'klocka': 'Klocka',
  'dagar_till': 'Dagar kvar',
  'kalender': 'Kalender',
  'helgdagar': 'Röda dagar',
  'raknare': 'Räknare',
  'omvandla': 'Enheter',
  'slumpa': 'Slump',
  'losenord': 'Lösenord',
  'att_gora': 'Listor',
  'textinfo': 'Textinfo',
  'anteckna': 'Anteckning',
  'lista_mapp': 'Filer',
  'las_fil': 'Läste filen',
  'sok_i_filer': 'Sökning',
  'skriv_fil': 'Skrev filen',
};

const _taltOrd = {
  'en': 1, 'ett': 1, 'två': 2, 'tre': 3, 'fyra': 4, 'fem': 5, 'sex': 6, 'sju': 7, 'åtta': 8, 'nio': 9, //
  'tio': 10, 'elva': 11, 'tolv': 12, 'femton': 15, 'tjugo': 20, 'trettio': 30, 'hundra': 100, 'tusen': 1000,
};
const _tal = r'(-?\d+(?:[.,]\d+)?|en|ett|två|tre|fyra|fem|sex|sju|åtta|nio|tio|elva|tolv|femton|tjugo|trettio|hundra|tusen)';
const _listor = r'(att[- ]?göra[- ]?listan|todo-listan|inköpslistan|handlingslistan|listan)';

double? _talVarde(String t) => _taltOrd[t]?.toDouble() ?? double.tryParse(t.replaceAll(',', '.'));
String _lista(String? namn) => namn != null && RegExp(r'inköp|handling').hasMatch(namn) ? 'inkop' : 'att-gora';
String _stor(String t) => t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';

RegExp _re(String p) => RegExp(p, caseSensitive: false, dotAll: true);

/// Tolkar en fråga. Returnerar null när ingen av verktygen passar – då svarar Lennart som vanligt.
Avsikt? tolkaFraga(String fraga, {DateTime? nu}) {
  final tid = nu ?? DateTime.now();
  var n = fraga.trim().replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll('’', "'");
  if (n.isEmpty || n.startsWith('/')) return null;
  n = n.replaceFirst(_re(r'^(?:(?:hej|hallå|tjena|hejsan|lennart)\s*[,!]?\s+)+'), '');
  n = n.replaceFirst(_re(r'^(?:kan du snälla|kan du|skulle du kunna|snälla|vill du|hjälp mig att|hjälp mig)\s+'), '');

  // Text att räkna på: allt efter kolonet, oförändrat.
  var m = _re(r'^(?:hur många|räkna(?: antalet)?|räkna hur många)\s+(?:ord(?:en)?|tecken|tecknen|meningar(?:na)?)\b[^:]*:\s*(.+)$')
      .firstMatch(n);
  if (m != null) return Avsikt('textinfo', {'text': m[1]!.trim()}, 'Jag räknar på texten.');

  n = n.replaceFirst(_re(r'(?:,?\s+(?:tack|snälla))?\s*[?!.]*$'), '').trim();
  if (n.isEmpty) return null;
  final s = n.toLowerCase();

  // Listor (före anteckningar, eftersom "skriv upp … på listan" hör hit).
  m = _re('^(?:lägg till|lägg|skriv upp|sätt upp|för upp)\\s+(.+?)\\s+(?:på|i|till)\\s+(?:min\\s+|mina\\s+)?$_listor\$').firstMatch(n);
  if (m != null)
    return Avsikt('att_gora', {
      'atgard': 'lagg_till',
      'text': m[1]!.trim(),
      'lista': _lista(m[2]!.toLowerCase()),
    }, 'Jag skriver upp det på listan.');
  m = _re('^(?:vad står på|visa|läs upp|vad finns på|vad har jag på)\\s+(?:min\\s+)?$_listor\$').firstMatch(s);
  if (m != null) return Avsikt('att_gora', {'atgard': 'visa', 'lista': _lista(m[1])}, 'Jag öppnar listan.');
  if (_re(r'^(?:vad har jag (?:kvar )?att göra|vad ska jag göra idag|vad ska jag göra i dag)$').hasMatch(s)) {
    return const Avsikt('att_gora', {'atgard': 'visa', 'lista': 'att-gora'}, 'Jag kollar din att-göra-lista.');
  }
  if (_re(r'^vad (?:ska|behöver) jag (?:köpa|handla)$').hasMatch(s)) {
    return const Avsikt('att_gora', {'atgard': 'visa', 'lista': 'inkop'}, 'Jag kollar inköpslistan.');
  }
  m = _re('^(?:bocka av|pricka av|kryssa av)\\s+(.+?)(?:\\s+(?:på|från|i)\\s+(?:min\\s+)?$_listor)?\$').firstMatch(n);
  m ??= _re('^(?:stryk|ta bort)\\s+(.+?)\\s+(?:på|från|i)\\s+(?:min\\s+)?$_listor\$').firstMatch(n);
  if (m != null)
    return Avsikt('att_gora', {'atgard': 'klar', 'text': m[1]!.trim(), 'lista': _lista(m[2]?.toLowerCase())}, 'Jag bockar av det.');
  m = _re('^(?:rensa)\\s+(?:min\\s+)?$_listor\$').firstMatch(s);
  if (m != null) return Avsikt('att_gora', {'atgard': 'rensa', 'lista': _lista(m[1])}, 'Jag rensar bort det avbockade.');

  // Anteckningar.
  m = _re(r'^(?:(?:anteckna|notera|skriv upp)\b(?:\s+att\b|\s*:)?|kom ihåg(?:\s+att\b|\s*:))\s*(.{2,})$').firstMatch(n);
  if (m != null) return Avsikt('anteckna', {'text': _stor(m[1]!.trim())}, 'Jag skriver upp det.');
  m = _re(r'^vad har jag (?:antecknat|skrivit upp|noterat) om (.+)$').firstMatch(n);
  m ??= _re(r'^sök (?:efter |på )?(.+?) i (?:mina )?(?:anteckningar(?:na)?|filerna|filer)$').firstMatch(n);
  m ??= _re(r'^sök i (?:mina )?(?:anteckningar(?:na)?|filerna|filer) (?:efter|på) (.+)$').firstMatch(n);
  if (m != null) return Avsikt('sok_i_filer', {'text': m[1]!.trim()}, 'Jag letar i dina anteckningar.');
  if (_re(
    r'^(?:(?:visa|läs upp|läs)\s+(?:mina\s+|alla\s+)?anteckningar(?:na)?|vad har jag (?:antecknat|skrivit upp|noterat)|vilka anteckningar har jag)$',
  ).hasMatch(s)) {
    return const Avsikt('las_fil', {'fil': 'anteckningar.md'}, 'Jag öppnar dina anteckningar.');
  }
  if (_re(r'^(?:vilka filer (?:finns(?: det)?|har jag)(?: i (?:arbets)?mappen)?|visa (?:filerna|mina filer|arbetsmappen))$').hasMatch(s)) {
    return const Avsikt('lista_mapp', {}, 'Jag tittar i arbetsmappen.');
  }
  m = _re(r'^(?:läs|öppna|visa)\s+(?:filen\s+)?([\w\-./åäöÅÄÖ]+\.(?:txt|md|csv|json|log))$').firstMatch(n);
  if (m != null) return Avsikt('las_fil', {'fil': m[1]!}, 'Jag läser filen.');

  if (s.length > 300) return null;

  // Lösenord.
  m = _re(
    r'^(?:(?:skapa|ge mig|generera|gör|hitta på|föreslå|slumpa(?: fram)?|ta fram)\s+(?:mig\s+)?|jag behöver\s+)(?:ett\s+|en\s+)?(?:nytt\s+|starkt\s+|säkert\s+|slumpat\s+|bra\s+|långt\s+|slumpmässigt\s+)*lösenord(?:\s+(?:på|med)\s+(\d+)\s+tecken)?$',
  ).firstMatch(s);
  if (m != null) return Avsikt('losenord', {'langd': int.tryParse(m[1] ?? '') ?? 20}, 'Jag skapar ett lösenord här i appen.');

  // Slump.
  m = _re('^(?:slå|kasta|rulla)\\s+(?:$_tal\\s+)?(?:tärning(?:ar)?|[td](\\d+)(?:-tärning(?:ar)?)?)\$').firstMatch(s);
  if (m != null) {
    return Avsikt('slumpa', {
      'typ': 'tarning',
      'antal': (_talVarde(m[1] ?? 'en') ?? 1).round(),
      if (m[2] != null) 'sidor': int.parse(m[2]!),
    }, 'Jag slår tärningen.');
  }
  if (_re(r'^(?:singla slant|krona eller klave|klave eller krona|(?:kasta|singla|slå) (?:ett |en )?(?:mynt|slant))$').hasMatch(s)) {
    return const Avsikt('slumpa', {'typ': 'mynt'}, 'Jag singlar slant.');
  }
  m = _re(
    r'^(?:slumpa|ge mig|välj|dra|ta)\s+(?:fram\s+)?(?:ett\s+)?(?:slumpat\s+|slumpmässigt\s+)?tal\s+(?:mellan|från)\s+(-?\d+)\s+(?:och|till)\s+(-?\d+)$',
  ).firstMatch(s);
  if (m != null) return Avsikt('slumpa', {'typ': 'tal', 'fran': int.parse(m[1]!), 'till': int.parse(m[2]!)}, 'Jag drar ett tal.');
  m = _re(r'^(?:välj|bestäm|slumpa)\s+(?:åt mig\s*)?(?:mellan\s+|:\s*)(.+)$').firstMatch(n);
  if (m != null) {
    final alt = m[1]!.split(_re(r'\s*,\s*|\s+eller\s+|\s+och\s+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (alt.length >= 2 && alt.length <= 10 && alt.every((a) => a.length <= 60)) {
      return Avsikt('slumpa', {'typ': 'valj', 'alternativ': alt}, 'Jag låter slumpen avgöra.');
    }
  }

  // Klockan och dagens datum.
  if (_re(
    r'^(?:(?:vad|hur mycket) är klockan(?: nu| just nu)?|(?:säg|berätta|säga) vad klockan är|hur dags är det|vad är det för (?:dag|datum|veckodag)(?: idag| i dag| nu)?|vilken (?:dag|veckodag) är det(?: idag| i dag| nu)?|vilket datum är det(?: idag| i dag| nu)?|vad har vi för (?:datum|dag)(?: idag| i dag)?|vad är dagens datum)$',
  ).hasMatch(s)) {
    return const Avsikt('klocka', {}, 'Jag kollar klockan.');
  }

  // Röda dagar.
  if (_re(r'^(?:vilka|visa|lista|när är|när kommer|nästa)\b.*\b(?:röda? dag(?:ar|en)?|helgdag(?:ar|arna)?)\b').hasMatch(s) ||
      _re(r'^(?:röda dagar|helgdagar)\b').hasMatch(s)) {
    final arM = RegExp(r'\b(1[6-9]\d\d|2\d\d\d)\b').firstMatch(s);
    final ar = arM != null
        ? int.parse(arM[1]!)
        : s.contains('nästa år')
        ? tid.year + 1
        : null;
    return Avsikt('helgdagar', {if (ar != null) 'ar': ar}, 'Jag slår upp de röda dagarna.');
  }

  // Vecka och datum framåt eller bakåt.
  if (_re(
    r'^(?:vilken vecka (?:är det|har vi)(?: nu| idag| i dag)?|vilket veckonummer (?:är det|har vi)(?: nu| idag| i dag)?|vad är det för vecka(?: nu| idag| i dag)?|vad har vi för vecka)$',
  ).hasMatch(s)) {
    return const Avsikt('kalender', {'datum': 'idag'}, 'Jag slår upp det i kalendern.');
  }
  m = _re(
    '^(?:vilket datum|vad är det för datum|vilken dag|vilken veckodag|vad är det för dag|vilken vecka)\\s+(?:är det|blir det|var det|är|blir|var)\\s+(?:om|för)\\s+$_tal\\s+(dag|dagar|vecka|veckor)(\\s+sedan)?\$',
  ).firstMatch(s);
  if (m != null) {
    final antal = (_talVarde(m[1]!) ?? 0).round() * (m[2]!.startsWith('veck') ? 7 : 1);
    return Avsikt('kalender', {'datum': 'idag', 'plus_dagar': m[3] != null ? -antal : antal}, 'Jag räknar i kalendern.');
  }
  bool arDatum(String t) {
    try {
      return tolkaDag(t, tid) != null;
    } on VerktygsFel {
      return true; // ser ut som ett datum men finns inte – verktyget förklarar varför
    }
  }

  // Dagar kvar till (eller sedan) ett datum.
  m = _re(
    r'^(?:hur många dagar|hur många veckor|hur länge|hur lång tid|hur mycket tid)\s+(?:är det\s+|har vi\s+|blir det\s+)?(?:kvar\s+)?(?:till|tills|innan)\s+(?:det är\s+|det blir\s+)?(.+?)(?:\s+kvar)?$',
  ).firstMatch(s);
  m ??= _re(r'^hur (?:många dagar|länge) (?:sedan|sen) (?:var\s+|är det\s+)?(.+)$').firstMatch(s);
  if (m != null && arDatum(m[1]!)) return Avsikt('dagar_till', {'datum': m[1]!}, 'Jag räknar dagarna i kalendern.');

  // Vilken dag eller vecka ett datum infaller.
  m = _re(
    r'^(?:när är det|när är|när infaller|när blir det|när firar vi|vilket datum är|vilket datum infaller|vilket datum blir|vilken (?:vecka|dag|veckodag) (?:är|var|blir|infaller))\s+(.+)$',
  ).firstMatch(s);
  if (m != null) {
    final x = m[1]!.replaceFirst(RegExp(r'^det (?=\S)'), '');
    if (arDatum(x)) return Avsikt('kalender', {'datum': x}, 'Jag slår upp det i kalendern.');
  }

  // Enheter: "3 mil i km", "hur många km är 3 mil".
  final omv = _omvandling(s);
  if (omv != null) return omv;

  // Räknare.
  return _rakning(s);
}

/// "3 mil i km", "vad är 70 °F i celsius", "hur många dl är 2 koppar".
Avsikt? _omvandling(String s) {
  Avsikt? av(String tal, String fran, String till) {
    final v = _talVarde(tal);
    if (v == null || !arEnhet(fran) || !arEnhet(till)) return null;
    try {
      omvandla(v, fran, till); // samma typ av enhet?
    } on VerktygsFel {
      return null;
    }
    return Avsikt('omvandla', {
      'varde': v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt() : v,
      'fran': fran.trim(),
      'till': till.trim(),
    }, 'Jag räknar om enheterna.');
  }

  var m = _re('^hur (?:många|mycket)\\s+(.+?)\\s+(?:är|blir|motsvarar|går det på)\\s+$_tal\\s*(.+)\$').firstMatch(s);
  if (m != null) {
    final a = av(m[2]!, m[3]!, m[1]!);
    if (a != null) return a;
  }
  m = _re('^(?:(?:vad|hur mycket) (?:är|blir)\\s+|omvandla\\s+|konvertera\\s+|räkna om\\s+)?$_tal\\s*(.+)\$').firstMatch(s);
  if (m == null) return null;
  final rest = m[2]!;
  // Prova varje ställe där enheterna kan delas ("100 kilometer i timmen i m/s" har två "i").
  for (final d in RegExp(r'\s+(?:i|till|på|in|uttryckt i|i antal)\s+|\s*=\s*').allMatches(rest)) {
    final a = av(m[1]!, rest.substring(0, d.start), rest.substring(d.end));
    if (a != null) return a;
  }
  return null;
}

/// "vad är 12 gånger 7", "räkna ut 15 % av 2300", "moms på 800 kr".
Avsikt? _rakning(String s) {
  var e = s
      .replaceFirst(_re(r'^(?:vad|hur mycket)\s+(?:är|blir|gör)\s+'), '')
      .replaceFirst(_re(r'^(?:räkna ut|räkna|beräkna|kalkylera)\s+'), '')
      .replaceFirst(RegExp(r'\s*=\s*$'), '')
      .replaceAll('π', 'pi')
      .trim();
  if (RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$|^\d{4}\s*[-–]\s*\d{4}$').hasMatch(e)) return null; // datum eller årtal, inte en uträkning
  const t = r'(\d+(?:[.,]\d+)?)';
  e = e.replaceAllMapped(_re(r'(\d)\s*(?:kr|kronor|:-|sek)(?![a-zåäö])'), (m) => m[1]!);
  e = e.replaceFirstMapped(_re('^(?:momsen|moms) (?:på|för) $t\$'), (m) => '${m[1]}*0,25');
  e = e.replaceFirstMapped(_re('^$t (?:plus|med|inklusive|inkl\\.?) moms\$'), (m) => '${m[1]}*1,25');
  e = e.replaceFirstMapped(_re('^$t (?:exklusive|exkl\\.?|utan|minus) moms\$'), (m) => '${m[1]}/1,25');
  e = e.replaceAllMapped(
    _re('$t (plus|\\+|minus|-) $t ?(?:%|procent)'),
    (m) => '${m[1]}*(1${m[2] == 'plus' || m[2] == '+' ? '+' : '-'}${m[3]}%)',
  );
  e = e
      .replaceAllMapped(_re(r'(\d)\s*(?:%|procent)\s+(?:av|utav)\s+'), (m) => '${m[1]}%*')
      .replaceAll(_re(r'\s*\bprocent\b'), '%')
      .replaceAll(_re(r'\s+(?:gånger|multiplicerat med)\s+'), '*')
      .replaceAllMapped(_re(r'(\d)\s*x\s*(?=\d)'), (m) => '${m[1]}*')
      .replaceAll(_re(r'\s+(?:delat med|delat på|dividerat med|genom)\s+'), '/')
      .replaceAll(_re(r'\s+plus\s+'), '+')
      .replaceAll(_re(r'\s+minus\s+'), '-')
      .replaceAll(_re(r'\s+upphöjt (?:till|med)\s+'), '^')
      .replaceAll(_re(r'\s+i kvadrat\b'), '^2')
      .replaceAll(_re(r'\s+i kubik\b'), '^3')
      .replaceAllMapped(_re(r'(?:kvadratroten|roten) ur\s+(\d+(?:[.,]\d+)?|\([^)]*\))'), (m) => 'sqrt(${m[1]})');
  e = e.replaceAll(RegExp(r'(?<=\d) (?=\d{3}\b)'), ''); // 12 000 → 12000
  if (RegExp(r'\d\s+\d').hasMatch(e)) return null; // t.ex. ett telefonnummer
  final kompakt = e.replaceAll(' ', '');
  if (!RegExp(r'\d').hasMatch(kompakt)) return null;
  if (!RegExp(r'^(?:[0-9.,+\-*/^%()]|sqrt|abs|round|pi)+$').hasMatch(kompakt)) return null;
  if (!RegExp(r'[\d)%i]\s*[+\-*/^]|sqrt|abs|round|%').hasMatch(kompakt)) return null; // bara ett tal
  try {
    rakna(kompakt);
  } on VerktygsFel catch (f) {
    if (!['Division med noll', 'Roten ur ett negativt tal', 'Uttrycket har inget ändligt värde'].contains(f.meddelande)) return null;
  }
  return Avsikt('raknare', {'uttryck': kompakt}, 'Det räknar jag hellre ut än gissar.');
}

/// Ett uttryck som det skrivs i ett svar: "12 × 7".
String visaUttryck(String e) => e
    .replaceAllMapped(RegExp(r'(?<=[\d)%i])([+\-*/])'), (m) => ' ${m[1]} ')
    .replaceAll(' * ', ' × ')
    .replaceAll(' - ', ' − ')
    .replaceAll('.', ',');

/// Lennarts svar när verktyget har körts. Bygger bara på verktygets resultat, så siffrorna blir alltid rätt.
String svarFran(String namn, Map<String, dynamic> arg, String resultat, {bool fel = false, bool nekad = false}) {
  final r = resultat.trim();
  if (nekad) return 'Okej, jag lät bli.';
  if (fel) {
    if (namn == 'las_fil' && arg['fil'] == 'anteckningar.md' && r.contains('finns inte')) {
      return 'Du har inga anteckningar än. Skriv till exempel "anteckna att jag ska ringa banken".';
    }
    return 'Det gick inte: ${r.replaceFirst(RegExp(r'[.!]$'), '')}.';
  }
  String punkt(String t) => RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
  switch (namn) {
    case 'raknare':
      return '${visaUttryck((arg['uttryck'] ?? '').toString())} = $r.';
    case 'klocka':
      final delar = r.split(', klockan ');
      return delar.length == 2 ? 'Klockan är ${delar[1]}, och det är ${delar[0]}.' : punkt(_stor(r));
    case 'dagar_till':
      return r.startsWith('Det är') ? r : punkt(_stor(RegExp(r'^\d').hasMatch(r) ? 'Det är $r' : r));
    case 'omvandla':
      return punkt(r.replaceFirst(' = ', ' är '));
    case 'helgdagar':
      final nasta = RegExp(r'Nästa röda dag: (.+)$').firstMatch(r);
      return nasta != null ? 'Här är de röda dagarna. Nästa är ${nasta[1]}.' : 'Här är de röda dagarna.';
    case 'slumpa':
      return switch (arg['typ']) {
        'mynt' => '$r!',
        'tal' => 'Det blev $r.',
        'valj' => 'Det får bli $r.',
        _ => punkt(r),
      };
    case 'losenord':
      final rader = r.split('\n');
      return 'Här är ett nytt lösenord:\n${rader.first}\n${rader.length > 1 ? '${rader[1].replaceAll(RegExp(r'[()]'), '')}. ' : ''}'
          'Det skapades här och skickas ingenstans, men det sparas i samtalet. Radera samtalet när du har kopierat det.';
    case 'att_gora':
      if (arg['atgard'] == 'visa') {
        final kvar = RegExp(r'\[ \]').allMatches(r).length;
        if (r.startsWith('Listan är tom')) return punkt(r);
        return kvar == 0 ? 'Allt på listan är avbockat. Snyggt!' : 'Du har $kvar ${kvar == 1 ? 'sak' : 'saker'} kvar på listan.';
      }
      final flera = RegExp(r'^Lade till \d+ saker på (\S+): (.+)$').firstMatch(r);
      if (flera != null) {
        final saker = flera[2]!.split(', ');
        return 'Klart, nu står ${saker.sublist(0, saker.length - 1).join(', ')} och ${saker.last} på ${flera[1]}.';
      }
      final en = RegExp(r'^Lade till "(.+)" på (\S+)$').firstMatch(r);
      if (en != null) return 'Klart, "${en[1]}" står nu på ${en[2]}.';
      return punkt(r);
    case 'anteckna':
      final antal = RegExp(r'\((\d+) i').firstMatch(r)?[1];
      return antal == null
          ? 'Klart, jag har antecknat det.'
          : 'Klart, jag har antecknat det. Du har $antal ${antal == '1' ? 'anteckning' : 'anteckningar'} nu.';
    case 'las_fil':
      return arg['fil'] == 'anteckningar.md' ? 'Här är dina anteckningar.' : 'Här är filen.';
    case 'sok_i_filer':
      if (r.startsWith('Inga träffar')) return 'Jag hittade inget om "${arg['text']}".';
      final n = r.split('\n').length;
      return 'Jag hittade $n ${n == 1 ? 'träff' : 'träffar'}.';
    case 'lista_mapp':
      return 'Här är filerna i arbetsmappen.';
    default:
      return punkt(_stor(r));
  }
}
