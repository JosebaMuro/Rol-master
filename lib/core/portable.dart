import 'dart:io';

import 'package:path/path.dart' as p;

/// Carpeta única de datos de la app. Todo (base de datos, ajustes, modelos,
/// voces, música, mapas, registros y exportaciones) vive aquí, así que copiar
/// esta carpeta a otro equipo (o a un USB) se lleva la app entera.
///
/// * Windows / Linux: `datos/` junto al ejecutable. Si esa carpeta no se
///   puede escribir (p. ej. instalado en Archivos de programa), se usa
///   `Documentos/DirectorDeRol`.
/// * Android: `Android/data/<paquete>/files/DirectorDeRol`, accesible desde
///   el PC por USB.
///
/// Las rutas que se guardan en la base de datos son relativas a esta
/// carpeta, de modo que siguen funcionando si se mueve.
class DataRoot {
  DataRoot(this.root) {
    for (final d in [models, voices, music, maps, logs, exports, tmp]) {
      Directory(d).createSync(recursive: true);
    }
  }

  final String root;

  String get database => p.join(root, 'director.db');
  String get settingsFile => p.join(root, 'ajustes.json');
  String get models => p.join(root, 'modelos');
  String get voices => p.join(root, 'voces');
  String get music => p.join(root, 'musica');
  String get maps => p.join(root, 'mapas');
  String get logs => p.join(root, 'registros');
  String get exports => p.join(root, 'exportaciones');
  String get tmp => p.join(root, 'tmp');

  /// Convierte una ruta en relativa si está dentro de la carpeta de datos.
  String toStored(String path) {
    if (path.isEmpty || !p.isAbsolute(path)) return path;
    if (p.isWithin(root, path)) return p.relative(path, from: root).replaceAll(r'\', '/');
    return path;
  }

  /// Resuelve una ruta guardada (relativa o absoluta) a una ruta real.
  String resolve(String stored) {
    if (stored.isEmpty || stored.contains('://') || p.isAbsolute(stored)) return stored;
    return p.normalize(p.join(root, stored));
  }

  static bool _writable(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final probe = File(p.join(dir, '.escritura'));
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Elige la carpeta de datos. [fallback] y [androidDir] los aporta quien
  /// llama (path_provider) para que esta clase se pueda probar sin Flutter.
  static DataRoot locate({required String fallback, String? androidDir, String? override}) {
    if (override != null) return DataRoot(override);
    if (Platform.isAndroid && androidDir != null && _writable(androidDir)) return DataRoot(androidDir);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final portable = p.join(exeDir, 'datos');
      if (_writable(portable)) return DataRoot(portable);
    }
    return DataRoot(fallback);
  }

  /// Copia un fichero dentro de [subdir] (si no está ya en la carpeta de
  /// datos) y devuelve la ruta nueva.
  Future<String> adopt(String path, String subdir) async {
    if (p.isWithin(root, path)) return path;
    final destDir = Directory(subdir);
    await destDir.create(recursive: true);
    var dest = p.join(destDir.path, p.basename(path));
    if (File(dest).existsSync()) {
      if (File(dest).lengthSync() == File(path).lengthSync()) return dest;
      dest = p.join(destDir.path, '${p.basenameWithoutExtension(path)}_${DateTime.now().millisecondsSinceEpoch}${p.extension(path)}');
    }
    await File(path).copy(dest);
    return dest;
  }
}
