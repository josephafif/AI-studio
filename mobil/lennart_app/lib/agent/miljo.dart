// Var agentens filverktyg får arbeta.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/prefs.dart';

/// Mappen "Lennart-anteckningar" i appens dokument. Används när ingen egen arbetsmapp är vald – alltid
/// på telefonen, där appen bara får arbeta i sin egen lagring.
Future<Directory> anteckningsmapp() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}Lennart-anteckningar');
  await d.create(recursive: true);
  return d;
}

/// Arbetsmappen: den du har valt (dator), annars anteckningsmappen.
Future<Directory> arbetsmapp() async {
  final vald = Prefs.arbetsmapp;
  if (vald != null && await Directory(vald).exists()) return Directory(vald);
  return anteckningsmapp();
}
