import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/downloader.dart';

/// Paquete de voces neuronales para sherpa-onnx (se ejecuta en local, sin
/// Internet, en CPU de móvil o PC).
class VoicePackInfo {
  const VoicePackInfo({
    required this.id,
    required this.label,
    required this.kind,
    required this.sizeMb,
    required this.description,
    this.lang = 'es',
  });
  final String id;
  final String label;

  /// 'vits' (Piper) o 'kokoro'.
  final String kind;
  final int sizeMb;
  final String description;
  final String lang;

  String get url => 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$id.tar.bz2';
}

const voicePackCatalog = <VoicePackInfo>[
  VoicePackInfo(
    id: 'vits-piper-es_ES-davefx-medium',
    label: 'Piper · Davefx (España, hombre)',
    kind: 'vits',
    sizeMb: 64,
    description: 'Voz masculina natural en castellano. Ligera, ideal para móvil.',
  ),
  VoicePackInfo(
    id: 'vits-piper-es_ES-sharvard-medium',
    label: 'Piper · Sharvard (España, 2 voces)',
    kind: 'vits',
    sizeMb: 64,
    description: 'Dos hablantes (hombre y mujer) en castellano.',
  ),
  VoicePackInfo(
    id: 'vits-piper-es_MX-ald-medium',
    label: 'Piper · Ald (México, hombre)',
    kind: 'vits',
    sizeMb: 64,
    description: 'Voz masculina con acento mexicano.',
  ),
  VoicePackInfo(
    id: 'vits-piper-es_ES-carlfm-x_low',
    label: 'Piper · Carlfm (España, muy ligera)',
    kind: 'vits',
    sizeMb: 30,
    description: 'Calidad básica, para móviles modestos.',
  ),
  VoicePackInfo(
    id: 'kokoro-int8-multi-lang-v1_0',
    label: 'Kokoro multilingüe v1.0 ligera (53 voces)',
    kind: 'kokoro',
    sizeMb: 130,
    description: 'Las mismas 53 voces de Kokoro comprimidas (int8): casi igual de buenas, la mitad de tamaño y más rápidas en móvil.',
  ),
  VoicePackInfo(
    id: 'kokoro-multi-lang-v1_0',
    label: 'Kokoro multilingüe v1.0 (53 voces)',
    kind: 'kokoro',
    sizeMb: 330,
    description: 'Muchas voces distintas (incluidas españolas: ef_dora, em_alex, em_santa). Mejor en PC.',
  ),
];

/// Ficheros resueltos de un paquete instalado.
class InstalledVoicePack {
  InstalledVoicePack({
    required this.id,
    required this.kind,
    required this.dir,
    required this.files,
    this.numSpeakers = 1,
    this.bundled = false,
  });
  final String id;
  final String kind;
  final String dir;
  final Map<String, String> files;
  int numSpeakers;

  /// Viene incluido con la app (no se descarga ni se puede borrar).
  bool bundled;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'dir': dir, 'files': files, 'numSpeakers': numSpeakers};
  factory InstalledVoicePack.fromJson(Map<String, dynamic> j) => InstalledVoicePack(
        id: j['id'] as String,
        kind: j['kind'] as String,
        dir: j['dir'] as String,
        files: (j['files'] as Map).cast<String, String>(),
        numSpeakers: (j['numSpeakers'] as num?)?.toInt() ?? 1,
      );
}

class VoicePackManager extends ChangeNotifier {
  VoicePackManager(this.rootDir, {this.bundledDirs = const []});
  final String rootDir;

  /// Carpetas de sólo lectura con voces que trae la app (en Windows,
  /// `incluidos/voces` junto al ejecutable). Se usan sin copiarlas.
  final List<String> bundledDirs;

  final Map<String, double?> downloading = {};
  final Map<String, String> errors = {};
  List<InstalledVoicePack> installed = [];

  Future<void> refresh() async {
    final root = Directory(rootDir);
    if (!root.existsSync()) root.createSync(recursive: true);
    final out = <InstalledVoicePack>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final pack = _load(d);
      if (pack != null) out.add(pack);
    }
    for (final dir in bundledDirs) {
      final b = Directory(dir);
      if (!b.existsSync()) continue;
      for (final d in b.listSync().whereType<Directory>()) {
        final id = p.basename(d.path);
        if (out.any((e) => e.id == id)) continue; // la copia del usuario manda
        final pack = _load(d) ?? _detect(id, id.contains('kokoro') ? 'kokoro' : 'vits', d.path);
        if (!pack.files.containsKey('model') || !pack.files.containsKey('tokens')) continue;
        pack.bundled = true;
        out.add(pack);
      }
    }
    // Orden del catálogo (lo que no es del catálogo, al final): la lista de
    // Ajustes y la voz que se usa si no se ha elegido ninguna no dependen
    // del orden en que el sistema de ficheros devuelva las carpetas.
    int rank(InstalledVoicePack e) {
      final i = voicePackCatalog.indexWhere((c) => c.id == e.id);
      return i < 0 ? voicePackCatalog.length : i;
    }

    final order = {for (final (i, e) in out.indexed) e: i};
    out.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : order[a]!.compareTo(order[b]!));
    installed = out;
    notifyListeners();
  }

  /// Lee el paquete de [d] a partir de su pack.json (null si no tiene).
  InstalledVoicePack? _load(Directory d) {
    final meta = File(p.join(d.path, 'pack.json'));
    if (!meta.existsSync()) return null;
    try {
      final stored = InstalledVoicePack.fromJson(jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>);
      // Las rutas se guardan relativas al paquete: así la carpeta se
      // puede mover a otro equipo. Se resuelven aquí.
      final files = {
        for (final e in stored.files.entries)
          e.key: e.value.split(',').map((f) => p.isAbsolute(f) ? f : p.join(d.path, f)).join(','),
      };
      final broken = files.values.any((v) => v.split(',').any((f) => !File(f).existsSync() && !Directory(f).existsSync()));
      final pack = broken
          ? _detect(stored.id, stored.kind, d.path)
          : InstalledVoicePack(id: stored.id, kind: stored.kind, dir: d.path, files: files, numSpeakers: stored.numSpeakers);
      return pack;
    } catch (_) {
      return null;
    }
  }

  InstalledVoicePack? byId(String id) => installed.where((e) => e.id == id).firstOrNull;

  void setSpeakers(String id, int n) {
    final pack = byId(id);
    if (pack == null || pack.numSpeakers == n) return;
    pack.numSpeakers = n;
    try {
      _writeMeta(pack);
    } catch (_) {
      // Carpeta de sólo lectura (voz incluida con la app).
    }
    notifyListeners();
  }

  Future<void> install(VoicePackInfo info) async {
    downloading[info.id] = 0;
    errors.remove(info.id);
    notifyListeners();
    // Se descarga a un .part que se conserva si falla: al volver a pulsar
    // se continúa donde se quedó.
    final tmp = File(p.join(rootDir, '${info.id}.tar.bz2.part'));
    final archivePath = p.join(rootDir, '${info.id}.tar.bz2');
    var downloaded = false;
    try {
      await ResumableDownloader().download(Uri.parse(info.url), tmp, onProgress: (f) {
        downloading[info.id] = f;
        notifyListeners();
      });
      downloaded = true;
      downloading[info.id] = null;
      notifyListeners();
      final dest = p.join(rootDir, info.id);
      // La extracción reconoce el formato por la extensión.
      final archive = tmp.renameSync(archivePath);
      try {
        await Isolate.run(() => _extract(archive.path, rootDir));
      } catch (e) {
        throw Exception('el archivo descargado está dañado, vuelve a intentarlo');
      }
      _writeMeta(_detect(info.id, info.kind, dest));
      await refresh();
    } catch (e) {
      errors[info.id] = 'No se pudo instalar: ${ResumableDownloader.describe(e).replaceFirst('Exception: ', '')}';
    } finally {
      // Un archivo ya descargado (extraído o dañado) no sirve para reanudar.
      if (downloaded) {
        for (final f in [tmp, File(archivePath)]) {
          if (f.existsSync()) f.deleteSync();
        }
      }
      downloading.remove(info.id);
      notifyListeners();
    }
  }

  /// Instala un paquete desde un .tar.bz2 local (por si no hay Internet).
  Future<void> installFromFile(String archivePath, String kind) async {
    final before = Directory(rootDir).listSync().whereType<Directory>().map((d) => d.path).toSet();
    await Isolate.run(() => _extract(archivePath, rootDir));
    final after = Directory(rootDir).listSync().whereType<Directory>().where((d) => !before.contains(d.path));
    for (final d in after) {
      _writeMeta(_detect(p.basename(d.path), kind, d.path));
    }
    await refresh();
  }

  /// Da de alta una voz ya descomprimida en la carpeta de voces (p. ej. la
  /// que la app copia de su APK en el primer arranque).
  void register(String id) {
    final d = p.join(rootDir, id);
    if (!Directory(d).existsSync()) return;
    _writeMeta(_detect(id, id.contains('kokoro') ? 'kokoro' : 'vits', d));
  }

  /// Si la voz viene con la app (y no hay copia propia que borrar).
  bool isBundled(String id) => byId(id)?.bundled ?? false;

  Future<void> remove(String id) async {
    if (isBundled(id)) return;
    final d = Directory(p.join(rootDir, id));
    if (d.existsSync()) d.deleteSync(recursive: true);
    await refresh();
  }

  static void _writeMeta(InstalledVoicePack pack) {
    final rel = {
      for (final e in pack.files.entries)
        e.key: e.value.split(',').map((f) => p.relative(f, from: pack.dir).replaceAll(r'\', '/')).join(','),
    };
    final json = pack.toJson()
      ..['files'] = rel
      ..['dir'] = '.';
    File(p.join(pack.dir, 'pack.json')).writeAsStringSync(jsonEncode(json));
  }

  static Future<void> _extract(String archivePath, String destRoot) =>
      extractFileToDisk(archivePath, destRoot);

  static InstalledVoicePack _detect(String id, String kind, String dir) {
    final files = <String, String>{};
    final all = Directory(dir).listSync(recursive: true);
    for (final f in all) {
      final name = p.basename(f.path);
      if (f is File) {
        if (name.endsWith('.onnx') && !name.contains('.json')) files['model'] ??= f.path;
        if (name == 'tokens.txt') files['tokens'] = f.path;
        if (name == 'voices.bin') files['voices'] = f.path;
        if (name.startsWith('lexicon') && name.endsWith('.txt')) {
          files['lexicon'] = files.containsKey('lexicon') ? '${files['lexicon']},${f.path}' : f.path;
        }
      } else if (f is Directory) {
        if (name == 'espeak-ng-data') files['dataDir'] = f.path;
        if (name == 'dict' && File(p.join(f.path, 'jieba.dict.utf8')).existsSync()) files['dictDir'] = f.path;
      }
    }
    return InstalledVoicePack(id: id, kind: kind, dir: dir, files: files, numSpeakers: kind == 'kokoro' ? 53 : 1);
  }
}
