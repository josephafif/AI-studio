// Verktygen i webbversionen. Samma beräkningar som i appen (berakning.dart), men anteckningar och listor
// ligger i webbläsarens lagring i stället för i en arbetsmapp. Sidan skickar med "filerna" och sparar
// de nya versionerna som kommer tillbaka.
import 'dart:math' as math;

import 'berakning.dart';

/// Verktyg som ändrar något och därför kräver godkännande när Lennart själv anropar dem.
bool webbVerktygAndrar(String namn, Map<String, dynamic> arg) => namn == 'anteckna' || (namn == 'att_gora' && arg['atgard'] != 'visa');

class WebbResultat {
  final String resultat;
  final bool fel;

  /// Filer som har ändrats (namn → nytt innehåll).
  final Map<String, String> andrade;
  const WebbResultat(this.resultat, {this.fel = false, this.andrade = const {}});
}

int? _heltal(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse(v.toString().trim()));

String _str(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v == null || (v is String && v.trim().isEmpty)) throw VerktygsFel('Argumentet "$k" saknas');
  return v.toString();
}

WebbResultat korWebbVerktyg(String namn, Map<String, dynamic> arg, Map<String, String> filer, DateTime nu, math.Random slump) {
  try {
    switch (namn) {
      case 'klocka':
        return WebbResultat(klockText(nu));
      case 'kalender':
        return WebbResultat(kalender((arg['datum'] ?? 'idag').toString(), _heltal(arg['plus_dagar']) ?? 0, nu));
      case 'dagar_till':
        return WebbResultat(dagarTill(_str(arg, 'datum'), nu));
      case 'helgdagar':
        return WebbResultat(helgdagar(_heltal(arg['ar']), nu));
      case 'raknare':
        return WebbResultat(rakna(_str(arg, 'uttryck')));
      case 'omvandla':
        final v = arg['varde'];
        final tal = v is num ? v.toDouble() : double.tryParse((v ?? '').toString().replaceAll(',', '.'));
        if (tal == null) throw VerktygsFel('"varde" måste vara ett tal');
        return WebbResultat(omvandla(tal, _str(arg, 'fran'), _str(arg, 'till')));
      case 'slumpa':
        return WebbResultat(slumpa(arg, slump));
      case 'losenord':
        return WebbResultat(losenord(_heltal(arg['langd']) ?? 20, slump));
      case 'textinfo':
        return WebbResultat(textinfo(_str(arg, 'text')));
      case 'att_gora':
        final fil = listfil(arg);
        final (r, nytt) = listAtgard(filer[fil] ?? '', arg);
        return WebbResultat(r, andrade: nytt == null ? const {} : {fil: nytt});
      case 'anteckna':
        final (r, nytt) = anteckna(filer['anteckningar.md'] ?? '', _str(arg, 'text'), nu);
        return WebbResultat(r, andrade: {'anteckningar.md': nytt});
      case 'las_fil':
        final fil = _str(arg, 'fil');
        final text = filer[fil];
        if (text == null || text.isEmpty) throw VerktygsFel('Filen finns inte');
        return WebbResultat(text);
      case 'lista_mapp':
        final namnen = [
          for (final e in filer.entries)
            if (e.value.isNotEmpty) '${e.key} (${e.value.length} tecken)',
        ]..sort();
        return WebbResultat(namnen.isEmpty ? '(inga filer än)' : namnen.join('\n'));
      case 'sok_i_filer':
        final q = _str(arg, 'text').toLowerCase();
        final traffar = <String>[];
        for (final e in filer.entries) {
          final rader = e.value.split('\n');
          for (var n = 0; n < rader.length && traffar.length < 30; n++) {
            if (rader[n].toLowerCase().contains(q)) traffar.add('${e.key}:${n + 1}: ${rader[n].trim()}');
          }
        }
        return WebbResultat(traffar.isEmpty ? 'Inga träffar på "$q"' : traffar.join('\n'));
    }
    throw VerktygsFel('Verktyget "$namn" finns inte i webbversionen');
  } on VerktygsFel catch (e) {
    return WebbResultat(e.meddelande, fel: true);
  }
}
