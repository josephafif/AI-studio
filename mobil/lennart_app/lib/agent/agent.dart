// Agentslingan och verktygsprotokollet.
//
// Protokollet passar Lennarts befintliga samtalsformat (inga nya specialtecken behövs):
//
//   <|user|>Hur mycket är 12 gånger 7?
//   <|assistant|><verktyg namn="raknare">{"uttryck": "12*7"}</verktyg><|end|>
//   <|user|><resultat namn="raknare">84</resultat>
//   <|assistant|>12 gånger 7 är 84.<|end|>
//
// Modellen anropar ett verktyg genom att svara med en <verktyg>-tagg. Appen kör verktyget (efter
// godkännande om det ändrar något) och skickar tillbaka en <resultat>-tagg som nästa tur. Det upprepas
// tills modellen svarar utan verktygsanrop, eller tills stegtaket nås.
//
// Lennart 3.x är inte tränad på protokollet. Lennart 4 ska få träningsdata i exakt det här formatet
// (se moln/lennart4/PLAN.md) – därför ligger formatet fast här och är testat.
import 'dart:convert';

import '../core/tokenizer.dart';
import 'verktyg.dart';

class VerktygsAnrop {
  final String namn;
  final Map<String, dynamic> argument;
  final String text; // hela taggen som modellen skrev
  final String fore; // eventuell text före anropet ("Jag räknar ut det.")
  VerktygsAnrop(this.namn, this.argument, this.text, this.fore);
}

final _anropRe = RegExp(r'<verktyg\s+namn="([a-z_]{1,40})"\s*>(.*?)</verktyg>', dotAll: true);

/// Hittar det första verktygsanropet i ett svar, eller null.
VerktygsAnrop? hittaAnrop(String svar) {
  final m = _anropRe.firstMatch(svar);
  if (m == null) return null;
  Map<String, dynamic> arg = {};
  final body = m.group(2)!.trim();
  if (body.isNotEmpty) {
    try {
      final j = jsonDecode(body);
      if (j is Map) arg = j.cast<String, dynamic>();
    } catch (_) {
      arg = {'_ogiltig': body};
    }
  }
  return VerktygsAnrop(m.group(1)!, arg, m.group(0)!, svar.substring(0, m.start).trim());
}

String anropsText(String namn, Map<String, dynamic> argument) => '<verktyg namn="$namn">${jsonEncode(argument)}</verktyg>';

String resultatText(String namn, String innehall, {bool fel = false}) =>
    '<resultat namn="$namn"${fel ? ' fel="ja"' : ''}>${innehall.replaceAll('</resultat>', '')}</resultat>';

bool arResultat(String text) => text.startsWith('<resultat ');

/// Beskrivning av verktygen, att lägga först i samtalet för en modell som kan protokollet.
String verktygsBeskrivning(List<Verktyg> verktyg) {
  final b = StringBuffer('Du kan använda verktyg. Svara då med exakt en tagg, t.ex. ')
    ..writeln('<verktyg namn="raknare">{"uttryck": "2+2"}</verktyg>, och vänta på <resultat>.')
    ..writeln('Tillgängliga verktyg:');
  for (final v in verktyg) {
    final p = v.parametrar.entries.map((e) => '"${e.key}": ${e.value}').join(', ');
    b.writeln('- ${v.namn}: ${v.beskrivning}${p.isEmpty ? '' : ' Argument: {$p}'}');
  }
  return b.toString().trim();
}

// ───────────────────────────────────────────────────────── agentslingan
sealed class AgentHandelse {}

/// Modellens slutliga svar (inga fler verktygsanrop).
class AgentSvar extends AgentHandelse {
  final String text;
  AgentSvar(this.text);
}

/// Modellen vill använda ett verktyg.
class AgentAnrop extends AgentHandelse {
  final VerktygsAnrop anrop;
  AgentAnrop(this.anrop);
}

/// Verktyget har körts (eller nekats).
class AgentResultat extends AgentHandelse {
  final VerktygsAnrop anrop;
  final String resultat;
  final bool fel, nekad;
  AgentResultat(this.anrop, this.resultat, {this.fel = false, this.nekad = false});
}

/// Stegtaket nåddes.
class AgentStopp extends AgentHandelse {
  final String orsak;
  AgentStopp(this.orsak);
}

typedef Generera = Future<String> Function(List<ChatTurn> samtal);
typedef Godkann = Future<bool> Function(VerktygsAnrop anrop, Verktyg verktyg);

class Agent {
  final Map<String, Verktyg> verktyg;
  final AgentMiljo miljo;
  final Generera generera;
  final Godkann godkann;
  final int maxSteg;

  Agent({required List<Verktyg> verktyg, required this.miljo, required this.generera, required this.godkann, this.maxSteg = 6})
    : verktyg = {for (final v in verktyg) v.namn: v};

  /// Kör ett verktygsanrop: kontrollerar att verktyget finns, ber om godkännande när det behövs och
  /// fångar fel så att modellen får veta vad som gick snett.
  Future<AgentResultat> korAnrop(VerktygsAnrop a) async {
    final v = verktyg[a.namn];
    if (v == null) return AgentResultat(a, 'Verktyget "${a.namn}" finns inte', fel: true);
    if (a.argument.containsKey('_ogiltig')) return AgentResultat(a, 'Argumenten måste vara JSON', fel: true);
    if (v.behoverMapp && miljo.arbetsmapp == null) {
      return AgentResultat(a, 'Ingen arbetsmapp är vald', fel: true);
    }
    if (v.andrarMed(a.argument) && !await godkann(a, v)) {
      return AgentResultat(a, 'Användaren nekade anropet', nekad: true);
    }
    try {
      return AgentResultat(a, await v.kor(a.argument, miljo));
    } on VerktygsFel catch (e) {
      return AgentResultat(a, e.meddelande, fel: true);
    } catch (e) {
      return AgentResultat(a, 'Oväntat fel: $e', fel: true);
    }
  }

  Stream<AgentHandelse> kor(List<ChatTurn> samtal) async* {
    final turer = List<ChatTurn>.of(samtal);
    for (var steg = 0; steg < maxSteg; steg++) {
      final svar = await generera(turer);
      final anrop = hittaAnrop(svar);
      if (anrop == null) {
        yield AgentSvar(svar.trim());
        return;
      }
      yield AgentAnrop(anrop);
      final r = await korAnrop(anrop);
      yield r;
      turer
        ..add(ChatTurn(false, anrop.text))
        ..add(ChatTurn(true, resultatText(anrop.namn, r.resultat, fel: r.fel || r.nekad)));
    }
    yield AgentStopp('Stannade efter $maxSteg steg');
  }
}
