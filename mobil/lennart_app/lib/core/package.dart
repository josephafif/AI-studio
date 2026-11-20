// Läser ett modellpaket (.lennart) från tools/exportera_mobil.py --paket:
//   "LENPKG01" | uint32 längd | JSON {"entry": {...}, "tokenizer": {...}} | utfyllnad till 4096 | .lmod-data
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class PackageResult {
  final Map<String, dynamic> entry;
  PackageResult(this.entry);
}

Future<PackageResult> installPackage(String packagePath, String modelsDir) async {
  final raf = await File(packagePath).open();
  try {
    final head = await raf.read(12);
    if (head.length < 12 || ascii.decode(head.sublist(0, 8), allowInvalid: true) != 'LENPKG01') {
      throw const FormatException('Filen är inte ett Lennart-modellpaket (.lennart)');
    }
    final len = ByteData.sublistView(Uint8List.fromList(head), 8, 12).getUint32(0, Endian.little);
    final meta = jsonDecode(utf8.decode(await raf.read(len))) as Map<String, dynamic>;
    final entry = Map<String, dynamic>.from(meta['entry'] as Map);
    final id = entry['id'] as String;
    if (!RegExp(r'^[a-z0-9-]{1,60}$').hasMatch(id)) throw const FormatException('Ogiltigt modell-id i paketet');
    final dataStart = ((12 + len) + 4095) ~/ 4096 * 4096;
    await File('$modelsDir/$id.tok.json').writeAsString(jsonEncode(meta['tokenizer']));
    final tmp = File('$modelsDir/$id.lmod.tmp');
    await File(packagePath).openRead(dataStart).pipe(tmp.openWrite());
    final check = await tmp.open();
    final magic = ascii.decode(await check.read(8), allowInvalid: true);
    await check.close();
    if (magic != 'LMOD0001') {
      await tmp.delete();
      throw const FormatException('Modelldata i paketet är skadade');
    }
    await tmp.rename('$modelsDir/$id.lmod');
    return PackageResult(entry);
  } finally {
    await raf.close();
  }
}
