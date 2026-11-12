import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Devuelve una ruta local para un fichero elegido. En Android los ficheros
/// pueden llegar como content:// y se copian a la carpeta de la app.
Future<String?> localPathFor(PlatformFile f, String copyDir) async {
  final path = f.path;
  if (path != null && File(path).existsSync()) return path;
  Directory(copyDir).createSync(recursive: true);
  final dest = File(p.join(copyDir, f.name));
  if (!dest.existsSync()) {
    final sink = dest.openWrite();
    await sink.addStream(f.xFile.openRead());
    await sink.close();
  }
  return dest.path;
}
