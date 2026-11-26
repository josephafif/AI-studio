// Rena beräkningar bakom agentens verktyg: räknare, datum och helgdagar, enheter, slump, lösenord och
// textinfo. Inga filer, inget nät och inga beroenden till dart:io eller Flutter. Därför kan samma kod
// köras i appen och kompileras till JavaScript för webbversionen (webb/app/).
import 'dart:math' as math;

class VerktygsFel implements Exception {
  final String meddelande;
  VerktygsFel(this.meddelande);
  @override
  String toString() => meddelande;
}

const veckodagar = ['måndag', 'tisdag', 'onsdag', 'torsdag', 'fredag', 'lördag', 'söndag'];
const manader = ['januari', 'februari', 'mars', 'april', 'maj', 'juni', 'juli', 'augusti', 'september', 'oktober', 'november', 'december'];

String _two(int n) => n.toString().padLeft(2, '0');
String datumText(DateTime d) => '${veckodagar[d.weekday - 1]} ${d.day} ${manader[d.month - 1]} ${d.year}';
String klockText(DateTime d) => '${datumText(d)}, klockan ${_two(d.hour)}.${_two(d.minute)}';

/// Antal hela dagar från [a] till [b]. Räknas i UTC så att sommartid inte tar bort en dag.
int dagarMellan(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// Ett tal med svenskt decimalkomma och mellanslag mellan tusental, högst [siffror] värdesiffror.
String talText(double v, {int siffror = 12}) {
  if (v.isNaN || v.isInfinite) throw VerktygsFel('Talet har inget ändligt värde');
  if (v == v.roundToDouble() && v.abs() < 1e15) return _tusental(v.round().toString());
  final s = double.parse(v.toStringAsPrecision(siffror)).toString();
  if (s.contains('e')) return s.replaceAll('.', ',');
  final delar = s.split('.');
  return delar.length == 1 ? _tusental(delar[0]) : '${_tusental(delar[0])},${delar[1]}';
}

String _tusental(String heltal) {
  final neg = heltal.startsWith('-');
  final s = neg ? heltal.substring(1) : heltal;
  if (s.length < 5) return heltal; // 1234 skrivs ihop, 12 345 med mellanslag
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '${neg ? '-' : ''}$b';
}

// ───────────────────────────────────────────────────────── räknare
/// Räknar ut ett uttryck med + − × ÷, ^, parenteser, procent och funktionerna sqrt, abs, round.
/// Egen tolkare – kör aldrig kod.
String rakna(String uttryck) {
  final v = _Tolk(uttryck).las();
  if (v.isNaN || v.isInfinite) throw VerktygsFel('Uttrycket har inget ändligt värde');
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
  return double.parse(v.toStringAsPrecision(12)).toString().replaceAll('.', ',');
}

class _Tolk {
  final String s;
  int i = 0;
  _Tolk(String text)
    : s = text.replaceAll('×', '*').replaceAll('÷', '/').replaceAll('−', '-').replaceAll(',', '.').replaceAll(RegExp(r'\s'), '');

  double las() {
    if (s.length > 200) throw VerktygsFel('Uttrycket är för långt');
    if (s.isEmpty) throw VerktygsFel('Skriv ett uttryck, t.ex. 12*7');
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

// ───────────────────────────────────────────────────────── datum och högtider
/// Påskdagen (gregoriansk kalender, den anonyma algoritmen).
DateTime paskdagen(int ar) {
  final a = ar % 19, b = ar ~/ 100, c = ar % 100, d = b ~/ 4, e = b % 4;
  final f = (b + 8) ~/ 25, g = (b - f + 1) ~/ 3, h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final manad = (h + l - 7 * m + 114) ~/ 31, dag = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime(ar, manad, dag);
}

DateTime _plus(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Första dagen med veckodagen [vd] från och med [fran].
DateTime _forstaFran(DateTime fran, int vd) => _plus(fran, (vd - fran.weekday + 7) % 7);
DateTime _midsommardagen(int y) => _forstaFran(DateTime(y, 6, 20), DateTime.saturday);
DateTime _allaHelgonsDag(int y) => _forstaFran(DateTime(y, 10, 31), DateTime.saturday);

/// Högtider och temadagar som går att fråga efter. Nyckel → (visningsnamn, datum ett visst år).
final Map<String, (String, DateTime Function(int))> _hogtider = () {
  final m = <String, (String, DateTime Function(int))>{};
  void lagg(List<String> namn, String visas, DateTime Function(int) f) {
    for (final n in namn) {
      m[n] = (visas, f);
    }
  }

  lagg(['jul', 'julafton', 'julen'], 'julafton', (y) => DateTime(y, 12, 24));
  lagg(['juldagen', 'juldag'], 'juldagen', (y) => DateTime(y, 12, 25));
  lagg(['annandag jul', 'annandagen'], 'annandag jul', (y) => DateTime(y, 12, 26));
  lagg(['nyår', 'nyar', 'nyåret', 'nyårsdagen', 'nyårsdag'], 'nyårsdagen', (y) => DateTime(y, 1, 1));
  lagg(['nyårsafton', 'nyårsaftonen'], 'nyårsafton', (y) => DateTime(y, 12, 31));
  lagg(['trettondedag jul', 'trettondagen', 'trettondag jul', 'trettondedagen'], 'trettondedag jul', (y) => DateTime(y, 1, 6));
  lagg(['påsk', 'påsken', 'påskdagen', 'påskdag'], 'påskdagen', paskdagen);
  lagg(['påskafton'], 'påskafton', (y) => _plus(paskdagen(y), -1));
  lagg(['långfredag', 'långfredagen'], 'långfredagen', (y) => _plus(paskdagen(y), -2));
  lagg(['annandag påsk'], 'annandag påsk', (y) => _plus(paskdagen(y), 1));
  lagg(['fettisdagen', 'fettisdag', 'semmeldagen'], 'fettisdagen', (y) => _plus(paskdagen(y), -47));
  lagg(['första maj', 'förste maj'], 'första maj', (y) => DateTime(y, 5, 1));
  lagg(['valborg', 'valborgsmässoafton', 'sista april'], 'valborgsmässoafton', (y) => DateTime(y, 4, 30));
  lagg(
    ['kristi himmelsfärd', 'kristi himmelsfärdsdag', 'kristi himmelsfärds dag', 'kristi himmelfärd', 'himmelsfärdsdagen'],
    'Kristi himmelsfärds dag',
    (y) => _plus(paskdagen(y), 39),
  );
  lagg(['pingst', 'pingsten', 'pingstdagen'], 'pingstdagen', (y) => _plus(paskdagen(y), 49));
  lagg(['nationaldagen', 'nationaldag', 'sveriges nationaldag'], 'Sveriges nationaldag', (y) => DateTime(y, 6, 6));
  lagg(['midsommar', 'midsommarafton'], 'midsommarafton', (y) => _plus(_midsommardagen(y), -1));
  lagg(['midsommardagen', 'midsommardag'], 'midsommardagen', _midsommardagen);
  lagg(['alla helgons dag', 'allhelgona', 'alla helgon'], 'alla helgons dag', _allaHelgonsDag);
  lagg(['lucia', 'luciadagen'], 'lucia', (y) => DateTime(y, 12, 13));
  lagg(['alla hjärtans dag'], 'alla hjärtans dag', (y) => DateTime(y, 2, 14));
  lagg(['halloween'], 'halloween', (y) => DateTime(y, 10, 31));
  lagg(['mors dag'], 'mors dag', (y) => _forstaFran(DateTime(y, 5, 25), DateTime.sunday));
  lagg(['fars dag'], 'fars dag', (y) => _plus(_forstaFran(DateTime(y, 11, 1), DateTime.sunday), 7));
  lagg(['kanelbullens dag'], 'kanelbullens dag', (y) => DateTime(y, 10, 4));
  lagg(['våffeldagen'], 'våffeldagen', (y) => DateTime(y, 3, 25));
  return m;
}();

const _manadsord = {
  'januari': 1, 'jan': 1, 'februari': 2, 'feb': 2, 'mars': 3, 'mar': 3, 'april': 4, 'apr': 4, 'maj': 5, //
  'juni': 6, 'jun': 6, 'juli': 7, 'jul': 7, 'augusti': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
  'oktober': 10, 'okt': 10, 'november': 11, 'nov': 11, 'december': 12, 'dec': 12,
};

/// Ett datum ur vanlig svenska: "2027-03-28", "28 mars", "28/3 2027", "i morgon", "jul", "påsk 2027".
/// Returnerar null om texten inte ser ut som ett datum alls, och kastar [VerktygsFel] om datumet inte
/// finns (t.ex. 30 februari). Utan årtal väljs nästa gång dagen infaller ([framat]) eller i år.
(DateTime, String?)? tolkaDag(String text, DateTime nu, {bool framat = true}) {
  var s = text.toLowerCase().trim().replaceAll(RegExp(r'[?!.]+$'), '').replaceAll(RegExp(r'\s+'), ' ');
  s = s.replaceFirst(RegExp(r'^(?:den|till|på|om) '), '');
  final idag = DateTime(nu.year, nu.month, nu.day);
  switch (s) {
    case 'idag' || 'i dag' || 'nu' || 'dagens datum':
      return (idag, null);
    case 'imorgon' || 'i morgon':
      return (_plus(idag, 1), null);
    case 'i övermorgon' || 'övermorgon':
      return (_plus(idag, 2), null);
    case 'igår' || 'i går':
      return (_plus(idag, -1), null);
    case 'i förrgår' || 'förrgår':
      return (_plus(idag, -2), null);
  }
  int? ar;
  final medAr = RegExp(r'^(.*?)(?:,? (?:år )?)(\d{4})$').firstMatch(s);
  if (medAr != null && medAr[1]!.isNotEmpty) {
    s = medAr[1]!.trim();
    ar = int.parse(medAr[2]!);
  }
  DateTime valj(DateTime Function(int) f) {
    if (ar != null) return f(ar);
    final iAr = f(idag.year);
    return framat && iAr.isBefore(idag) ? f(idag.year + 1) : iAr;
  }

  DateTime exakt(int y, int m, int d) {
    final x = DateTime(y, m, d);
    if (m < 1 || m > 12 || x.month != m || x.day != d) throw VerktygsFel('Det datumet finns inte');
    return x;
  }

  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (iso != null) return (exakt(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!)), null);
  final hog = _hogtider[s];
  if (hog != null) return (valj(hog.$2), hog.$1);
  final dm = RegExp(r'^(\d{1,2})(?::[ae])? ([a-zåäö]+)$').firstMatch(s);
  if (dm != null && _manadsord.containsKey(dm[2])) {
    final d = int.parse(dm[1]!), m = _manadsord[dm[2]]!;
    exakt(ar ?? 2024, m, d); // 2024 är skottår, så 29 februari godtas här och prövas mot rätt år nedan
    final x = valj((y) => DateTime(y, m, d));
    return (exakt(x.year, m, d), null);
  }
  final snedstreck = RegExp(r'^(\d{1,2})/(\d{1,2})(?:[/-](\d{2}|\d{4}))?$').firstMatch(s);
  if (snedstreck != null) {
    final d = int.parse(snedstreck[1]!), m = int.parse(snedstreck[2]!);
    if (snedstreck[3] != null) ar = int.parse(snedstreck[3]!) + (snedstreck[3]!.length == 2 ? 2000 : 0);
    exakt(ar ?? 2024, m, d);
    final x = valj((y) => DateTime(y, m, d));
    return (exakt(x.year, m, d), null);
  }
  return null;
}

const _datumHjalp = 'Skriv ett datum som 2027-03-28 eller 28 mars, eller en högtid som jul, påsk eller midsommar';

/// "28 dagar kvar till julafton (torsdag 24 december 2026)".
String dagarTill(String datum, DateTime nu) {
  final t = tolkaDag(datum, nu);
  if (t == null) throw VerktygsFel(_datumHjalp);
  final (mal, namn) = t;
  final dagar = dagarMellan(nu, mal);
  final vad = namn == null ? datumText(mal) : '$namn (${datumText(mal)})';
  if (dagar == 0) return 'Det är $vad i dag!';
  if (dagar > 0) return '$dagar ${dagar == 1 ? 'dag' : 'dagar'} kvar till $vad';
  return '$vad var för ${-dagar} ${dagar == -1 ? 'dag' : 'dagar'} sedan';
}

/// ISO-veckonummer (vecka 1 är veckan med årets första torsdag).
int isoVecka(DateTime d) {
  final dag = DateTime.utc(d.year, d.month, d.day);
  final torsdag = dag.add(Duration(days: 4 - dag.weekday));
  return torsdag.difference(DateTime.utc(torsdag.year, 1, 1)).inDays ~/ 7 + 1;
}

/// Veckodag, vecka och dagnummer för ett datum, eventuellt [plusDagar] framåt (eller bakåt).
String kalender(String datum, int plusDagar, DateTime nu) {
  final t = tolkaDag(datum.trim().isEmpty ? 'idag' : datum, nu, framat: false);
  if (t == null) throw VerktygsFel(_datumHjalp);
  final (bas, namn) = t;
  final d = _plus(bas, plusDagar);
  final dagNr = dagarMellan(DateTime(d.year, 1, 1), d) + 1;
  final arsDagar = dagarMellan(DateTime(d.year, 1, 1), DateTime(d.year + 1, 1, 1));
  final fakta = '${datumText(d)}, vecka ${isoVecka(d)} (dag $dagNr av $arsDagar)';
  if (plusDagar > 0) return 'Om $plusDagar ${plusDagar == 1 ? 'dag' : 'dagar'} är det $fakta';
  if (plusDagar < 0) return 'För ${-plusDagar} ${plusDagar == -1 ? 'dag' : 'dagar'} sedan var det $fakta';
  final idag = dagarMellan(nu, d) == 0;
  if (namn != null) return '${namn[0].toUpperCase()}${namn.substring(1)} infaller $fakta';
  return idag ? 'I dag är det $fakta' : '${fakta[0].toUpperCase()}${fakta.substring(1)}';
}

/// Sveriges helgdagar (röda dagar) och de vanliga aftnarna ett visst år, sorterade.
List<(DateTime, String, bool)> helgdagarFor(int ar) {
  final p = paskdagen(ar);
  final ms = _midsommardagen(ar);
  return [
    (DateTime(ar, 1, 1), 'nyårsdagen', true),
    (DateTime(ar, 1, 6), 'trettondedag jul', true),
    (_plus(p, -2), 'långfredagen', true),
    (_plus(p, -1), 'påskafton', false),
    (p, 'påskdagen', true),
    (_plus(p, 1), 'annandag påsk', true),
    (DateTime(ar, 5, 1), 'första maj', true),
    (_plus(p, 39), 'Kristi himmelsfärds dag', true),
    (_plus(p, 49), 'pingstdagen', true),
    (DateTime(ar, 6, 6), 'Sveriges nationaldag', true),
    (_plus(ms, -1), 'midsommarafton', false),
    (ms, 'midsommardagen', true),
    (_allaHelgonsDag(ar), 'alla helgons dag', true),
    (DateTime(ar, 12, 24), 'julafton', false),
    (DateTime(ar, 12, 25), 'juldagen', true),
    (DateTime(ar, 12, 26), 'annandag jul', true),
    (DateTime(ar, 12, 31), 'nyårsafton', false),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
}

String helgdagar(int? ar, DateTime nu) {
  final y = ar ?? nu.year;
  if (y < 1600 || y > 3000) throw VerktygsFel('Välj ett år mellan 1600 och 3000');
  final b = StringBuffer('Röda dagar $y (aftnar inom parentes):\n');
  for (final (d, namn, rod) in helgdagarFor(y)) {
    b.writeln('${veckodagar[d.weekday - 1]} ${d.day} ${manader[d.month - 1]} – ${rod ? namn : '($namn)'}');
  }
  if (ar == null || ar == nu.year) {
    final kommande = [...helgdagarFor(nu.year), ...helgdagarFor(nu.year + 1)].where((h) => h.$3 && dagarMellan(nu, h.$1) >= 0);
    final (d, namn, _) = kommande.first;
    final n = dagarMellan(nu, d);
    b.write(
      'Nästa röda dag: $namn, ${datumText(d)} (${n == 0
          ? 'i dag'
          : n == 1
          ? 'i morgon'
          : 'om $n dagar'})',
    );
  }
  return b.toString().trim();
}

// ───────────────────────────────────────────────────────── enheter
class _Enhet {
  final String typ, visas;
  final double faktor; // till grundenheten (m, kg, l, m², m/s, s, byte, J)
  const _Enhet(this.typ, this.visas, this.faktor);
}

final Map<String, _Enhet> _enheter = () {
  final m = <String, _Enhet>{};
  void e(String typ, String visas, double f, List<String> namn) {
    for (final n in [visas.toLowerCase(), ...namn]) {
      m[n] = _Enhet(typ, visas, f);
    }
  }

  e('längd', 'mm', 0.001, ['millimeter']);
  e('längd', 'cm', 0.01, ['centimeter']);
  e('längd', 'dm', 0.1, ['decimeter']);
  e('längd', 'm', 1, ['meter', 'metrar']);
  e('längd', 'km', 1000, ['kilometer']);
  e('längd', 'mil', 10000, ['svenska mil', 'svensk mil']);
  e('längd', 'engelska mil', 1609.344, ['engelsk mil', 'miles', 'mile', 'mi']);
  e('längd', 'sjömil', 1852, ['nautiska mil', 'nautisk mil', 'nm']);
  e('längd', 'tum', 0.0254, ['inch', 'inches', 'in', '"']);
  e('längd', 'fot', 0.3048, ['feet', 'foot', 'ft']);
  e('längd', 'yard', 0.9144, ['yards', 'yd']);
  e('vikt', 'mg', 1e-6, ['milligram']);
  e('vikt', 'g', 0.001, ['gram']);
  e('vikt', 'hg', 0.1, ['hekto', 'hektogram']);
  e('vikt', 'kg', 1, ['kilo', 'kilogram']);
  e('vikt', 'ton', 1000, []);
  e('vikt', 'pund', 0.45359237, ['lb', 'lbs', 'pounds']);
  e('vikt', 'uns', 0.028349523125, ['oz', 'ounce', 'ounces']);
  e('vikt', 'stone', 6.35029318, ['st']);
  e('volym', 'ml', 0.001, ['milliliter', 'krm', 'kryddmått']);
  e('volym', 'cl', 0.01, ['centiliter']);
  e('volym', 'dl', 0.1, ['deciliter']);
  e('volym', 'l', 1, ['liter']);
  e('volym', 'm³', 1000, ['m3', 'kubikmeter', 'kubik']);
  e('volym', 'tsk', 0.005, ['tesked', 'teskedar']);
  e('volym', 'msk', 0.015, ['matsked', 'matskedar']);
  e('volym', 'koppar (USA)', 0.2365882365, ['kopp', 'koppar', 'cup', 'cups']);
  e('volym', 'gallon (USA)', 3.785411784, ['gallon', 'gallons', 'gal']);
  e('volym', 'fl oz (USA)', 0.0295735295625, ['fl oz', 'floz']);
  e('area', 'm²', 1, ['m2', 'kvm', 'kvadratmeter']);
  e('area', 'km²', 1e6, ['km2', 'kvadratkilometer']);
  e('area', 'hektar', 1e4, ['ha']);
  e('area', 'ar', 100, []);
  e('area', 'tunnland', 4936.4, []);
  e('area', 'acre', 4046.8564224, ['acres']);
  e('area', 'kvadratfot', 0.09290304, ['sq ft', 'ft2']);
  e('hastighet', 'km/h', 1 / 3.6, ['kmh', 'km/t', 'kilometer i timmen', 'kilometer per timme']);
  e('hastighet', 'm/s', 1, ['meter per sekund']);
  e('hastighet', 'knop', 1852 / 3600, ['knots']);
  e('hastighet', 'mph', 0.44704, ['miles per hour']);
  e('tid', 'sekunder', 1, ['sekund', 's', 'sek']);
  e('tid', 'minuter', 60, ['minut', 'min']);
  e('tid', 'timmar', 3600, ['timme', 'tim', 'h']);
  e('tid', 'dygn', 86400, ['dag', 'dagar']);
  e('tid', 'veckor', 604800, ['vecka']);
  e('data', 'byte', 1, ['bytes', 'b']);
  e('data', 'bit', 0.125, ['bitar', 'bits']);
  e('data', 'kB', 1e3, ['kilobyte']);
  e('data', 'MB', 1e6, ['megabyte']);
  e('data', 'GB', 1e9, ['gigabyte']);
  e('data', 'TB', 1e12, ['terabyte']);
  e('data', 'KiB', 1024, []);
  e('data', 'MiB', 1048576, []);
  e('data', 'GiB', 1073741824, []);
  e('data', 'Mbit', 125000, ['megabit']);
  e('data', 'Gbit', 125000000, ['gigabit']);
  e('energi', 'J', 1, ['joule']);
  e('energi', 'kJ', 1000, ['kilojoule']);
  e('energi', 'kcal', 4184, ['kalorier', 'kilokalorier']);
  e('energi', 'kWh', 3.6e6, ['kilowattimmar', 'kilowattimme']);
  for (final n in ['°c', 'c', 'celsius', 'grader', 'grader celsius']) {
    m[n] = const _Enhet('temperatur', '°C', 0);
  }
  for (final n in ['°f', 'f', 'fahrenheit', 'grader fahrenheit']) {
    m[n] = const _Enhet('temperatur', '°F', 0);
  }
  for (final n in ['k', 'kelvin']) {
    m[n] = const _Enhet('temperatur', 'K', 0);
  }
  return m;
}();

/// Finns enheten? Används av avsiktstolken.
bool arEnhet(String namn) => _enheter.containsKey(namn.toLowerCase().trim());

/// "3 mil = 30 km".
String omvandla(double varde, String fran, String till) {
  final a = _enheter[fran.toLowerCase().trim()], b = _enheter[till.toLowerCase().trim()];
  if (a == null) throw VerktygsFel('Känner inte till enheten "$fran"');
  if (b == null) throw VerktygsFel('Känner inte till enheten "$till"');
  if (a.typ != b.typ) throw VerktygsFel('Det går inte att räkna om ${a.typ} till ${b.typ}');
  double ut;
  if (a.typ == 'temperatur') {
    final kelvin = switch (a.visas) {
      '°C' => varde + 273.15,
      '°F' => (varde - 32) * 5 / 9 + 273.15,
      _ => varde,
    };
    if (kelvin < -1e-9) throw VerktygsFel('Det är kallare än absoluta nollpunkten');
    ut = switch (b.visas) {
      '°C' => kelvin - 273.15,
      '°F' => (kelvin - 273.15) * 9 / 5 + 32,
      _ => kelvin,
    };
  } else {
    ut = varde * a.faktor / b.faktor;
  }
  final avrundat = double.parse(ut.toStringAsPrecision(6));
  return '${talText(varde)} ${a.visas} = ${talText(avrundat)} ${b.visas}';
}

// ───────────────────────────────────────────────────────── slump och lösenord
String slumpa(Map<String, dynamic> arg, math.Random r) {
  final typ = (arg['typ'] ?? 'tarning').toString();
  int heltal(String k, int standard) {
    final v = arg[k];
    if (v == null || v.toString().trim().isEmpty) return standard;
    final n = v is num ? v.toInt() : int.tryParse(v.toString().trim());
    if (n == null) throw VerktygsFel('"$k" måste vara ett heltal');
    return n;
  }

  switch (typ) {
    case 'tarning':
      final antal = heltal('antal', 1), sidor = heltal('sidor', 6);
      if (antal < 1 || antal > 20) throw VerktygsFel('Jag slår mellan 1 och 20 tärningar');
      if (sidor < 2 || sidor > 1000) throw VerktygsFel('En tärning har mellan 2 och 1000 sidor');
      final slag = [for (var i = 0; i < antal; i++) r.nextInt(sidor) + 1];
      if (antal == 1) return '${sidor == 6 ? 'Tärningen' : 'T$sidor-tärningen'} visar ${slag.first}';
      return '$antal ${sidor == 6 ? 'tärningar' : 'T$sidor'}: ${slag.join(' + ')} = ${slag.reduce((a, b) => a + b)}';
    case 'mynt':
      return r.nextBool() ? 'Krona' : 'Klave';
    case 'tal':
      var fran = heltal('fran', 1), till = heltal('till', 100);
      if (fran > till) (fran, till) = (till, fran);
      if (till - fran > 1000000000) throw VerktygsFel('Intervallet är för stort');
      return '${fran + r.nextInt(till - fran + 1)}';
    case 'valj':
      final alt = arg['alternativ'];
      final lista = (alt is List ? alt.map((e) => e.toString()) : (alt ?? '').toString().split(RegExp(r',|\n')))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (lista.length < 2) throw VerktygsFel('Ge mig minst två alternativ att välja mellan');
      return lista[r.nextInt(lista.length)];
  }
  throw VerktygsFel('Okänd typ "$typ" – välj tarning, mynt, tal eller valj');
}

const _losenTecken = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%&*+-=?@_';

/// Ett slumpat lösenord. [r] ska vara [math.Random.secure] utom i tester.
String losenord(int langd, math.Random r) {
  if (langd < 8 || langd > 64) throw VerktygsFel('Välj en längd mellan 8 och 64 tecken');
  final klasser = [RegExp(r'[a-z]'), RegExp(r'[A-Z]'), RegExp(r'[0-9]'), RegExp(r'[^a-zA-Z0-9]')];
  while (true) {
    final p = String.fromCharCodes([for (var i = 0; i < langd; i++) _losenTecken.codeUnitAt(r.nextInt(_losenTecken.length))]);
    if (klasser.every((k) => k.hasMatch(p))) {
      final bitar = (langd * math.log(_losenTecken.length) / math.ln2).floor();
      return '$p\n($langd tecken, ungefär $bitar bitar slump${langd < 14 ? ' – 16 tecken eller fler är säkrare' : ''})';
    }
  }
}

// ───────────────────────────────────────────────────────── textinfo
String textinfo(String text) {
  final t = text.trim();
  if (t.isEmpty) throw VerktygsFel('Ge mig en text att räkna på');
  final ord = RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’\-]*", unicode: true).allMatches(t).length;
  final tecken = t.runes.length;
  final utanMellanslag = t.replaceAll(RegExp(r'\s'), '').runes.length;
  final meningar = math.max(1, RegExp(r'[.!?]+(\s|$)').allMatches(t).length);
  final sekunder = (ord / 200 * 60).round(); // ungefär 200 ord i minuten
  final las = sekunder < 60 ? '${math.max(1, sekunder)} sekunder' : '${(sekunder / 60).toStringAsFixed(1).replaceAll('.', ',')} minuter';
  return '$ord ord, $tecken tecken ($utanMellanslag utan mellanslag), $meningar ${meningar == 1 ? 'mening' : 'meningar'}. '
      'Tar ungefär $las att läsa.';
}
