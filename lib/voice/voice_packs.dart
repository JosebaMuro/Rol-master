import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

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
    id: 'kokoro-multi-lang-v1_0',
    label: 'Kokoro multilingüe v1.0 (53 voces)',
    kind: 'kokoro',
    sizeMb: 330,
    description: 'Muchas voces distintas (incluidas españolas: ef_dora, em_alex, em_santa). Mejor en PC.',
  ),
];

/// Ficheros resueltos de un paquete instalado.
class InstalledVoicePack {
  InstalledVoicePack({required this.id, required this.kind, required this.dir, required this.files, this.numSpeakers = 1});
  final String id;
  final String kind;
  final String dir;
  final Map<String, String> files;
  int numSpeakers;

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
  VoicePackManager(this.rootDir);
  final String rootDir;

  final Map<String, double?> downloading = {};
  final Map<String, String> errors = {};
  List<InstalledVoicePack> installed = [];

  Future<void> refresh() async {
    final root = Directory(rootDir);
    if (!root.existsSync()) root.createSync(recursive: true);
    final out = <InstalledVoicePack>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final meta = File(p.join(d.path, 'pack.json'));
      if (meta.existsSync()) {
        try {
          out.add(InstalledVoicePack.fromJson(jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    installed = out;
    notifyListeners();
  }

  InstalledVoicePack? byId(String id) => installed.where((e) => e.id == id).firstOrNull;

  void setSpeakers(String id, int n) {
    final pack = byId(id);
    if (pack == null || pack.numSpeakers == n) return;
    pack.numSpeakers = n;
    File(p.join(pack.dir, 'pack.json')).writeAsStringSync(jsonEncode(pack.toJson()));
    notifyListeners();
  }

  Future<void> install(VoicePackInfo info) async {
    downloading[info.id] = 0;
    errors.remove(info.id);
    notifyListeners();
    final tmp = File(p.join(rootDir, '${info.id}.tar.bz2'));
    try {
      final client = http.Client();
      final res = await client.send(http.Request('GET', Uri.parse(info.url)));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      var received = 0;
      final sink = tmp.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        downloading[info.id] = total > 0 ? received / total : null;
        notifyListeners();
      }
      await sink.close();
      client.close();
      downloading[info.id] = null;
      notifyListeners();
      final dest = p.join(rootDir, info.id);
      await Isolate.run(() => _extract(tmp.path, rootDir));
      final pack = _detect(info.id, info.kind, dest);
      File(p.join(dest, 'pack.json')).writeAsStringSync(jsonEncode(pack.toJson()));
      await refresh();
    } catch (e) {
      errors[info.id] = '$e';
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
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
      final pack = _detect(p.basename(d.path), kind, d.path);
      File(p.join(d.path, 'pack.json')).writeAsStringSync(jsonEncode(pack.toJson()));
    }
    await refresh();
  }

  Future<void> remove(String id) async {
    final d = Directory(p.join(rootDir, id));
    if (d.existsSync()) d.deleteSync(recursive: true);
    await refresh();
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
