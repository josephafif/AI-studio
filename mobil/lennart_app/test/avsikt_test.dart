import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lennart_app/agent/avsikt.dart';
import 'package:lennart_app/agent/berakning.dart';
import 'package:lennart_app/agent/verktyg.dart';

final nu = DateTime(2026, 11, 26, 9, 5); // torsdag

void main() {
  Avsikt? t(String f) => tolkaFraga(f, nu: nu);

  group('verktygssinnet känner igen', () {
    final fall = <String, (String, Map<String, dynamic>)>{
      'Vad är klockan?': ('klocka', {}),
      'Hej Lennart, vad är klockan nu?': ('klocka', {}),
      'Vilken dag är det idag?': ('klocka', {}),
      'kan du säga vad klockan är': ('klocka', {}),
      'Vilken vecka är det?': ('kalender', {'datum': 'idag'}),
      'vilket datum är det om 100 dagar': ('kalender', {'datum': 'idag', 'plus_dagar': 100}),
      'vilken veckodag var det för två veckor sedan': ('kalender', {'datum': 'idag', 'plus_dagar': -14}),
      'När är påsk 2027?': ('kalender', {'datum': 'påsk 2027'}),
      'vilken veckodag är julafton 2027': ('kalender', {'datum': 'julafton 2027'}),
      'När är det midsommar?': ('kalender', {'datum': 'midsommar'}),
      'Hur många dagar är det kvar till jul?': ('dagar_till', {'datum': 'jul'}),
      'hur länge är det till midsommar': ('dagar_till', {'datum': 'midsommar'}),
      'hur många dagar är det till 24 december': ('dagar_till', {'datum': '24 december'}),
      'Vilka röda dagar är det 2027?': ('helgdagar', {'ar': 2027}),
      'när är nästa röda dag': ('helgdagar', {}),
      'Vad är 12 gånger 7?': ('raknare', {'uttryck': '12*7'}),
      'räkna ut 15 % av 2300': ('raknare', {'uttryck': '15%*2300'}),
      'hur mycket är 1299 kr minus 20 procent': ('raknare', {'uttryck': '1299*(1-20%)'}),
      'vad är roten ur 2': ('raknare', {'uttryck': 'sqrt(2)'}),
      'vad blir 2 upphöjt till 10': ('raknare', {'uttryck': '2^10'}),
      'moms på 800 kr': ('raknare', {'uttryck': '800*0,25'}),
      '(12+8)*3/4': ('raknare', {'uttryck': '(12+8)*3/4'}),
      'vad är 12 000 * 3': ('raknare', {'uttryck': '12000*3'}),
      'vad är 1/0': ('raknare', {'uttryck': '1/0'}),
      'Hur många km är 3 mil?': ('omvandla', {'varde': 3, 'fran': 'mil', 'till': 'km'}),
      '70 grader fahrenheit i celsius': ('omvandla', {'varde': 70, 'fran': 'grader fahrenheit', 'till': 'celsius'}),
      'vad är 100 km/h i m/s': ('omvandla', {'varde': 100, 'fran': 'km/h', 'till': 'm/s'}),
      'omvandla 5 fot till cm': ('omvandla', {'varde': 5, 'fran': 'fot', 'till': 'cm'}),
      'hur många dl är 2 koppar': ('omvandla', {'varde': 2, 'fran': 'koppar', 'till': 'dl'}),
      'Slå två tärningar': ('slumpa', {'typ': 'tarning', 'antal': 2}),
      'slå en t20': ('slumpa', {'typ': 'tarning', 'antal': 1, 'sidor': 20}),
      'singla slant': ('slumpa', {'typ': 'mynt'}),
      'slumpa ett tal mellan 1 och 100': ('slumpa', {'typ': 'tal', 'fran': 1, 'till': 100}),
      'välj åt mig: pizza eller tacos': (
        'slumpa',
        {
          'typ': 'valj',
          'alternativ': ['pizza', 'tacos'],
        },
      ),
      'Skapa ett starkt lösenord': ('losenord', {'langd': 20}),
      'ge mig ett lösenord på 32 tecken': ('losenord', {'langd': 32}),
      'Lägg till mjölk, bröd och ägg på inköpslistan': (
        'att_gora',
        {'atgard': 'lagg_till', 'text': 'mjölk, bröd och ägg', 'lista': 'inkop'},
      ),
      'skriv upp Ring banken på att-göra-listan': ('att_gora', {'atgard': 'lagg_till', 'text': 'Ring banken', 'lista': 'att-gora'}),
      'vad står på inköpslistan?': ('att_gora', {'atgard': 'visa', 'lista': 'inkop'}),
      'vad har jag att göra': ('att_gora', {'atgard': 'visa', 'lista': 'att-gora'}),
      'bocka av mjölk på inköpslistan': ('att_gora', {'atgard': 'klar', 'text': 'mjölk', 'lista': 'inkop'}),
      'Anteckna att jag ska ringa banken': ('anteckna', {'text': 'Jag ska ringa banken'}),
      'kom ihåg att mötet är på fredag': ('anteckna', {'text': 'Mötet är på fredag'}),
      'vad har jag antecknat om banken?': ('sok_i_filer', {'text': 'banken'}),
      'visa mina anteckningar': ('las_fil', {'fil': 'anteckningar.md'}),
      'Hur många ord är det i den här texten: Hej på dig. Hur mår du?': ('textinfo', {'text': 'Hej på dig. Hur mår du?'}),
    };
    for (final MapEntry(key: fraga, value: (namn, arg)) in fall.entries) {
      test(fraga, () {
        final a = t(fraga);
        expect(a, isNotNull, reason: fraga);
        expect(a!.namn, namn);
        expect(a.argument, arg);
        expect(a.fore, isNotEmpty);
      });
    }
  });

  group('verktygssinnet låter Lennart svara själv på', () {
    for (final fraga in [
      'Vad är en tärning?',
      'Berätta om klockans historia',
      'Hur fungerar procent?',
      'Vad är klockan i Tokyo?',
      'Hur många dagar har februari?',
      'Hur skapar jag ett starkt lösenord?',
      'Vad är 2FA?',
      'Skriv en dikt om julen',
      'Vad är 5?',
      'Ring 070-123 45 67',
      'Hej!',
      'Vad är Sverige?',
      'Hur lång tid tar det till Göteborg?',
      'Välj ett bra namn på min katt',
      'Kan du hjälpa mig med en anteckning om nätfiske?',
      'När är mötet?',
      'Anteckningarna från igår var bra',
      'Vad betyder röd dag?',
      '1914-1918',
      'Hur många mil är det till Göteborg?',
      'Vad är 3 äpplen i en korg?',
      '/klocka',
    ]) {
      test(fraga, () => expect(t(fraga), isNull, reason: fraga));
    }
  });

  group('beräkningarna', () {
    test('kalender', () {
      expect(kalender('idag', 0, nu), 'I dag är det torsdag 26 november 2026, vecka 48 (dag 330 av 365)');
      expect(kalender('idag', 100, nu), 'Om 100 dagar är det lördag 6 mars 2027, vecka 9 (dag 65 av 365)');
      expect(kalender('idag', -14, nu), 'För 14 dagar sedan var det torsdag 12 november 2026, vecka 46 (dag 316 av 365)');
      expect(kalender('påsk 2027', 0, nu), 'Påskdagen infaller söndag 28 mars 2027, vecka 12 (dag 87 av 365)');
      expect(kalender('julafton 2027', 0, nu), 'Julafton infaller fredag 24 december 2027, vecka 51 (dag 358 av 365)');
      expect(isoVecka(DateTime(2027, 1, 1)), 53);
      expect(() => kalender('30 februari', 0, nu), throwsA(isA<VerktygsFel>()));
    });
    test('dagar till högtider', () {
      expect(dagarTill('lucia', nu), '17 dagar kvar till lucia (söndag 13 december 2026)');
      expect(dagarTill('påsk', nu), '122 dagar kvar till påskdagen (söndag 28 mars 2027)');
      expect(dagarTill('24 december', nu), '28 dagar kvar till torsdag 24 december 2026');
      expect(dagarTill('i morgon', nu), '1 dag kvar till fredag 27 november 2026');
      expect(dagarTill('fettisdagen', nu), '75 dagar kvar till fettisdagen (tisdag 9 februari 2027)');
      expect(dagarTill('mors dag 2027', nu), contains('söndag 30 maj 2027'));
      expect(dagarTill('fars dag 2026', nu), 'fars dag (söndag 8 november 2026) var för 18 dagar sedan');
    });
    test('röda dagar', () {
      final h = helgdagarFor(2027);
      expect(h.firstWhere((x) => x.$2 == 'påskdagen').$1, DateTime(2027, 3, 28));
      expect(h.firstWhere((x) => x.$2 == 'midsommardagen').$1, DateTime(2027, 6, 26));
      expect(h.firstWhere((x) => x.$2 == 'alla helgons dag').$1, DateTime(2027, 11, 6));
      expect(h.firstWhere((x) => x.$2 == 'Kristi himmelsfärds dag').$1, DateTime(2027, 5, 6));
      expect(helgdagar(null, nu), endsWith('Nästa röda dag: juldagen, fredag 25 december 2026 (om 29 dagar)'));
      expect(helgdagar(2027, nu), isNot(contains('Nästa')));
    });
    test('enheter', () {
      expect(omvandla(3, 'mil', 'km'), '3 mil = 30 km');
      expect(omvandla(70, 'grader fahrenheit', 'celsius'), '70 °F = 21,1111 °C');
      expect(omvandla(5, 'fot', 'cm'), '5 fot = 152,4 cm');
      expect(omvandla(100, 'km/h', 'm/s'), '100 km/h = 27,7778 m/s');
      expect(omvandla(1, 'kg', 'pund'), '1 kg = 2,20462 pund');
      expect(omvandla(2, 'koppar', 'dl'), '2 koppar (USA) = 4,73176 dl');
      expect(omvandla(25000, 'm', 'km'), '25 000 m = 25 km');
      expect(() => omvandla(3, 'kg', 'km'), throwsA(isA<VerktygsFel>()));
      expect(() => omvandla(-300, 'celsius', 'kelvin'), throwsA(isA<VerktygsFel>()));
    });
    test('slump och lösenord', () {
      final r = math.Random(7);
      for (var i = 0; i < 50; i++) {
        expect(int.parse(slumpa({'typ': 'tal', 'fran': 1, 'till': 6}, r)), inInclusiveRange(1, 6));
      }
      expect(['Krona', 'Klave'], contains(slumpa({'typ': 'mynt'}, r)));
      expect(
        ['pizza', 'tacos'],
        contains(
          slumpa({
            'typ': 'valj',
            'alternativ': ['pizza', 'tacos'],
          }, r),
        ),
      );
      expect(slumpa({'typ': 'tarning', 'antal': 2}, r), matches(RegExp(r'^2 tärningar: [1-6] \+ [1-6] = \d+$')));
      final p = losenord(20, math.Random(1)).split('\n');
      expect(p.first.length, 20);
      expect(p.first, matches(RegExp(r'[a-z]')));
      expect(p.first, matches(RegExp(r'[A-Z]')));
      expect(p.first, matches(RegExp(r'[0-9]')));
      expect(p[1], '(20 tecken, ungefär 121 bitar slump)');
      expect(() => losenord(4, r), throwsA(isA<VerktygsFel>()));
    });
    test('textinfo', () {
      expect(textinfo('Hej på dig. Hur mår du?'), '6 ord, 23 tecken (18 utan mellanslag), 2 meningar. Tar ungefär 2 sekunder att läsa.');
    });
  });

  group('svaren bygger på resultatet', () {
    test('mallar', () {
      expect(svarFran('raknare', {'uttryck': '12*7'}, '84'), '12 × 7 = 84.');
      expect(svarFran('raknare', {'uttryck': '1299*(1-20%)'}, '1039,2'), '1299 × (1 − 20%) = 1039,2.');
      expect(svarFran('klocka', {}, 'torsdag 26 november 2026, klockan 09.05'), 'Klockan är 09.05, och det är torsdag 26 november 2026.');
      expect(
        svarFran('dagar_till', {'datum': 'jul'}, '28 dagar kvar till julafton (torsdag 24 december 2026)'),
        'Det är 28 dagar kvar till julafton (torsdag 24 december 2026).',
      );
      expect(svarFran('omvandla', {}, '3 mil = 30 km'), '3 mil är 30 km.');
      expect(svarFran('slumpa', {'typ': 'mynt'}, 'Klave'), 'Klave!');
      expect(
        svarFran('att_gora', {'atgard': 'lagg_till'}, 'Lade till 3 saker på inköpslistan: mjölk, bröd, ägg'),
        'Klart, nu står mjölk, bröd och ägg på inköpslistan.',
      );
      expect(
        svarFran('att_gora', {'atgard': 'lagg_till'}, 'Lade till "Ring banken" på att-göra-listan'),
        'Klart, "Ring banken" står nu på att-göra-listan.',
      );
      expect(svarFran('raknare', {'uttryck': '1/0'}, 'Division med noll', fel: true), 'Det gick inte: Division med noll.');
      expect(svarFran('anteckna', {}, 'x', nekad: true), 'Okej, jag lät bli.');
    });
  });

  group('listverktyget', () {
    late Directory mapp;
    setUp(() => mapp = Directory.systemTemp.createTempSync('lennart_lista'));
    tearDown(() => mapp.deleteSync(recursive: true));
    test('lägga till, visa, bocka av och rensa', () async {
      final m = AgentMiljo(arbetsmapp: mapp, nu: () => nu);
      final v = AttGora();
      Future<String> kor(Map<String, dynamic> a) => v.kor(a, m);
      expect(await kor({'atgard': 'visa', 'lista': 'inkop'}), 'Listan är tom (inköpslistan)');
      expect(
        await kor({'atgard': 'lagg_till', 'text': 'mjölk, bröd och ägg', 'lista': 'inkop'}),
        'Lade till 3 saker på inköpslistan: mjölk, bröd, ägg',
      );
      expect(await kor({'atgard': 'klar', 'text': 'bröd', 'lista': 'inkop'}), 'Bockade av "bröd". 2 kvar på inköpslistan');
      expect(await kor({'atgard': 'visa', 'lista': 'inkop'}), '1. [ ] mjölk\n2. [x] bröd\n3. [ ] ägg');
      expect(await kor({'atgard': 'rensa', 'lista': 'inkop'}), 'Tog bort 1 avbockade från inköpslistan');
      expect(File('${mapp.path}/inkopslista.md').readAsStringSync(), '- [ ] mjölk\n- [ ] ägg\n');
      expect(
        await kor({'atgard': 'lagg_till', 'text': 'Ring banken och boka tid', 'lista': 'att-gora'}),
        'Lade till "Ring banken och boka tid" på att-göra-listan',
      );
      expect(v.andrarMed({'atgard': 'visa'}), isFalse);
      expect(v.andrarMed({'atgard': 'lagg_till'}), isTrue);
      expect(() => kor({'atgard': 'klar', 'text': 'cykel', 'lista': 'inkop'}), throwsA(isA<VerktygsFel>()));
    });
  });
}
