import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lennart_app/agent/agent.dart';
import 'package:lennart_app/agent/verktyg.dart';
import 'package:lennart_app/core/tokenizer.dart';

void main() {
  late Directory mapp;
  setUp(() {
    mapp = Directory.systemTemp.createTempSync('lennart_agent');
    File('${mapp.path}/anteckningar.txt').writeAsStringSync('Möte på fredag.\nKöp kaffe.\nRing banken om nätfiske.');
    Directory('${mapp.path}/kod').createSync();
    File('${mapp.path}/kod/hej.dart').writeAsStringSync('void main() => print("hej");');
  });
  tearDown(() => mapp.deleteSync(recursive: true));

  AgentMiljo miljo() => AgentMiljo(arbetsmapp: mapp, nu: () => DateTime(2026, 11, 26, 9, 5));

  group('protokoll', () {
    test('hittar ett anrop och texten före', () {
      final a = hittaAnrop('Jag räknar.\n<verktyg namn="raknare">{"uttryck": "12*7"}</verktyg>')!;
      expect(a.namn, 'raknare');
      expect(a.argument['uttryck'], '12*7');
      expect(a.fore, 'Jag räknar.');
      expect(hittaAnrop('Vanligt svar utan verktyg.'), isNull);
    });
    test('ogiltig JSON blir ett fel, inte en krasch', () async {
      final a = hittaAnrop('<verktyg namn="raknare">{trasig</verktyg>')!;
      final r = await Agent(verktyg: standardVerktyg(), miljo: miljo(), generera: (_) async => '', godkann: (_, __) async => true)
          .korAnrop(a);
      expect(r.fel, isTrue);
    });
    test('beskrivningen nämner alla verktyg', () {
      final b = verktygsBeskrivning(standardVerktyg());
      for (final v in standardVerktyg()) {
        expect(b, contains(v.namn));
      }
    });
  });

  group('verktyg', () {
    test('räknare', () async {
      final r = Raknare();
      Future<String> calc(String u) => r.kor({'uttryck': u}, miljo());
      expect(await calc('12*7'), '84');
      expect(await calc('(12+8)*3/4'), '15');
      expect(await calc('2^3^2'), '512');
      expect(await calc('-3+5'), '2');
      expect(await calc('25%*200'), '50');
      expect(await calc('1/3'), '0,333333333333');
      expect(await calc('sqrt(16)+abs(-2)'), '6');
      expect(await calc('3,5*2'), '7');
      expect(() => calc('1/0'), throwsA(isA<VerktygsFel>()));
      expect(() => calc('2+'), throwsA(isA<VerktygsFel>()));
      expect(() => calc('system("rm")'), throwsA(isA<VerktygsFel>()));
    });
    test('klocka', () async {
      expect(await Klocka().kor({}, miljo()), 'torsdag 26 november 2026, klockan 09.05');
    });
    test('lista, läsa och söka i arbetsmappen', () async {
      expect(await ListaMapp().kor({}, miljo()), contains('anteckningar.txt'));
      expect(await ListaMapp().kor({}, miljo()), contains('kod/'));
      expect(await LasFil().kor({'fil': 'anteckningar.txt'}, miljo()), contains('Köp kaffe'));
      expect(await SokIFiler().kor({'text': 'nätfiske'}, miljo()), 'anteckningar.txt:3: Ring banken om nätfiske.');
    });
    test('kan inte ta sig ut ur arbetsmappen', () async {
      for (final p in ['../hemligt.txt', '/etc/passwd', 'C:/Windows/win.ini', 'kod/../../x']) {
        expect(() => LasFil().kor({'fil': p}, miljo()), throwsA(isA<VerktygsFel>()), reason: p);
      }
      if (!Platform.isWindows) {
        final ute = Directory.systemTemp.createTempSync('ute');
        File('${ute.path}/hemligt.txt').writeAsStringSync('nej');
        Link('${mapp.path}/genvag').createSync(ute.path);
        expect(() => LasFil().kor({'fil': 'genvag/hemligt.txt'}, miljo()), throwsA(isA<VerktygsFel>()));
        ute.deleteSync(recursive: true);
      }
    });
    test('utan arbetsmapp', () async {
      expect(() => LasFil().kor({'fil': 'a.txt'}, AgentMiljo()), throwsA(isA<VerktygsFel>()));
    });
  });

  group('agentslingan', () {
    test('anropar räknaren och svarar med resultatet', () async {
      final sett = <List<ChatTurn>>[];
      final agent = Agent(
        verktyg: standardVerktyg(),
        miljo: miljo(),
        godkann: (_, __) async => true,
        generera: (turer) async {
          sett.add(List.of(turer));
          final sista = turer.last.text;
          if (arResultat(sista)) return '12 gånger 7 är ${RegExp(r'>(\d+)<').firstMatch(sista)![1]}.';
          return anropsText('raknare', {'uttryck': '12*7'});
        },
      );
      final h = await agent.kor([ChatTurn(true, 'Hur mycket är 12 gånger 7?')]).toList();
      expect(h.whereType<AgentAnrop>().single.anrop.namn, 'raknare');
      expect(h.whereType<AgentResultat>().single.resultat, '84');
      expect((h.last as AgentSvar).text, '12 gånger 7 är 84.');
      expect(sett.last.last.text, '<resultat namn="raknare">84</resultat>');
    });

    test('skriv_fil kräver godkännande – nekat betyder att inget skrivs', () async {
      var fragade = 0;
      final agent = Agent(
        verktyg: standardVerktyg(),
        miljo: miljo(),
        godkann: (a, v) async {
          fragade++;
          return false;
        },
        generera: (turer) async => arResultat(turer.last.text)
            ? 'Okej, jag lät bli.'
            : anropsText('skriv_fil', {'fil': 'ny.txt', 'innehall': 'hej'}),
      );
      final h = await agent.kor([ChatTurn(true, 'Skapa en fil')]).toList();
      expect(fragade, 1);
      expect(h.whereType<AgentResultat>().single.nekad, isTrue);
      expect(File('${mapp.path}/ny.txt').existsSync(), isFalse);
    });

    test('godkänd skrivning skapar filen', () async {
      final agent = Agent(
        verktyg: standardVerktyg(),
        miljo: miljo(),
        godkann: (_, __) async => true,
        generera: (turer) async => arResultat(turer.last.text)
            ? 'Klart.'
            : anropsText('skriv_fil', {'fil': 'ut/ny.txt', 'innehall': 'hej från Lennart'}),
      );
      await agent.kor([ChatTurn(true, 'Skapa en fil')]).toList();
      expect(File('${mapp.path}/ut/ny.txt').readAsStringSync(), 'hej från Lennart');
    });

    test('stannar efter stegtaket', () async {
      final agent = Agent(
        verktyg: standardVerktyg(),
        miljo: miljo(),
        maxSteg: 3,
        godkann: (_, __) async => true,
        generera: (_) async => anropsText('klocka', {}),
      );
      final h = await agent.kor([ChatTurn(true, 'Vad är klockan?')]).toList();
      expect(h.whereType<AgentAnrop>().length, 3);
      expect(h.last, isA<AgentStopp>());
    });
  });
}
