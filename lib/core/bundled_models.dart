import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'portable.dart';

/// Lee ficheros de los modelos que vienen dentro de la app.
abstract class BundledAssetSource {
  /// Texto del fichero [path] dentro del paquete (null si no está).
  Future<String?> readText(String path);

  /// Copia el fichero [path] del paquete a [dest] (crea las carpetas).
  Future<void> copy(String path, String dest);
}

/// En Android los modelos van como assets del APK: los lee un canal nativo
/// (MainActivity.kt) que copia a disco por trozos, sin cargar en memoria
/// ficheros de cientos de MB.
class AndroidAssetSource implements BundledAssetSource {
  static const _channel = MethodChannel('director_de_rol/incluidos');

  @override
  Future<String?> readText(String path) => _channel.invokeMethod<String>('readText', {'path': path});

  @override
  Future<void> copy(String path, String dest) => _channel.invokeMethod<void>('copy', {'path': path, 'dest': dest});
}

/// Voces (Piper, Kokoro) y reconocimiento (Whisper) que trae la app, para no
/// tener que descargarlos desde Ajustes. Los prepara el workflow de GitHub
/// Actions con `tool/incluir_modelos.py`, en una carpeta `incluidos/` con
/// `voces/<id>`, `reconocimiento/<id>` y un `manifest.json`.
///
/// * Windows / Linux: `incluidos/` va junto al ejecutable y se usa tal cual,
///   sin copiarla (ver [desktopDir]).
/// * Android: va dentro del APK y en el primer arranque se copia a la
///   carpeta de datos ([installFromAssets]); a partir de ahí son voces
///   instaladas normales.
class BundledModels extends ChangeNotifier {
  BundledModels(this.root, {BundledAssetSource? source}) : source = source ?? AndroidAssetSource();

  final DataRoot root;
  final BundledAssetSource source;

  /// Progreso de la copia (0..1); null si no se está copiando.
  double? progress;
  String? error;

  bool get busy => progress != null;

  /// Fichero que recuerda qué versión de los modelos incluidos ya se copió,
  /// para no volver a copiarlos (ni a reponer los que el usuario borre).
  File get _marker => File(p.join(root.root, '.incluidos.json'));

  /// Carpeta `incluidos` junto al ejecutable en escritorio (null si no hay).
  static String? desktopDir() {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return null;
    final d = p.join(p.dirname(Platform.resolvedExecutable), 'incluidos');
    return Directory(d).existsSync() ? d : null;
  }

  /// Copia los modelos del paquete a la carpeta de datos si aún no se ha
  /// hecho con esta versión. Devuelve el manifiesto copiado (null si no
  /// había nada que copiar).
  Future<BundledManifest?> installFromAssets() async {
    final BundledManifest manifest;
    try {
      final text = await source.readText('incluidos/manifest.json');
      if (text == null) return null;
      manifest = BundledManifest.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null; // APK sin modelos incluidos
    }
    try {
      if (_marker.existsSync() && (jsonDecode(_marker.readAsStringSync()) as Map)['version'] == manifest.version) {
        return null;
      }
    } catch (_) {}

    final total = manifest.files.fold<int>(0, (a, f) => a + f.size);
    var done = 0;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      for (final f in manifest.files) {
        final dest = destinationFor(f.path);
        if (dest != null) {
          final file = File(dest);
          if (!file.existsSync() || file.lengthSync() != f.size) {
            await source.copy('incluidos/${f.path}', dest);
          }
        }
        done += f.size;
        progress = total == 0 ? 1 : done / total;
        notifyListeners();
      }
      _marker.writeAsStringSync(jsonEncode({'version': manifest.version}));
      return manifest;
    } catch (e) {
      // Se reintenta en el próximo arranque; lo ya copiado no se repite.
      error = 'No se pudieron preparar las voces incluidas: $e';
      return null;
    } finally {
      progress = null;
      notifyListeners();
    }
  }

  /// Ruta de destino en la carpeta de datos de un fichero del paquete.
  String? destinationFor(String rel) {
    final parts = rel.split('/');
    if (parts.length < 2 || parts.contains('..')) return null;
    final base = switch (parts.first) {
      'voces' => root.voices,
      'reconocimiento' => root.speech,
      _ => null,
    };
    return base == null ? null : p.joinAll([base, ...parts.skip(1)]);
  }
}

class BundledFile {
  const BundledFile(this.path, this.size);
  final String path;
  final int size;
}

class BundledManifest {
  const BundledManifest({required this.version, required this.files, required this.voices, required this.speech});
  final String version;
  final List<BundledFile> files;
  final List<String> voices;
  final List<String> speech;

  factory BundledManifest.fromJson(Map<String, dynamic> j) => BundledManifest(
    version: j['version'] as String,
    files: [
      for (final f in (j['files'] as List).cast<Map>()) BundledFile(f['path'] as String, (f['size'] as num).toInt()),
    ],
    voices: ((j['voces'] as List?) ?? const []).cast<String>(),
    speech: ((j['reconocimiento'] as List?) ?? const []).cast<String>(),
  );
}
