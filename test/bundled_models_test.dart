import 'dart:convert';
import 'dart:io';

import 'package:director_de_rol/core/bundled_models.dart';
import 'package:director_de_rol/core/portable.dart';
import 'package:director_de_rol/voice/speech_input.dart';
import 'package:director_de_rol/voice/voice_packs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Simula los assets del APK con una carpeta normal.
class _FolderSource implements BundledAssetSource {
  _FolderSource(this.dir);
  final String dir;
  int copies = 0;

  @override
  Future<String?> readText(String path) async {
    final f = File(p.join(dir, path));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  Future<void> copy(String path, String dest) async {
    copies++;
    File(dest).parent.createSync(recursive: true);
    File(p.join(dir, path)).copySync(dest);
  }
}

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

/// Carpeta `incluidos` como la deja tool/incluir_modelos.py.
void _fakeBundle(String inc) {
  _write(p.join(inc, 'voces', 'vits-piper-es_ES-sharvard-medium', 'es_ES-sharvard-medium.onnx'), 'onnx');
  _write(p.join(inc, 'voces', 'vits-piper-es_ES-sharvard-medium', 'tokens.txt'), 'a 1');
  _write(p.join(inc, 'voces', 'vits-piper-es_ES-sharvard-medium', 'espeak-ng-data', 'phontab'), 'x');
  _write(p.join(inc, 'reconocimiento', 'sherpa-onnx-whisper-base', 'base-encoder.int8.onnx'), 'e');
  _write(p.join(inc, 'reconocimiento', 'sherpa-onnx-whisper-base', 'base-decoder.int8.onnx'), 'd');
  _write(p.join(inc, 'reconocimiento', 'sherpa-onnx-whisper-base', 'base-tokens.txt'), 't');
  final files = [
    for (final f in Directory(inc).listSync(recursive: true).whereType<File>())
      {'path': p.relative(f.path, from: inc).replaceAll(r'\', '/'), 'size': f.lengthSync()},
  ];
  _write(
    p.join(inc, 'manifest.json'),
    jsonEncode({
      'version': 'v1',
      'voces': ['vits-piper-es_ES-sharvard-medium'],
      'reconocimiento': ['sherpa-onnx-whisper-base'],
      'files': files,
    }),
  );
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('incluidos_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('en escritorio las voces y Whisper incluidos se usan sin copiarlos', () async {
    final inc = p.join(tmp.path, 'incluidos');
    _fakeBundle(inc);
    final root = DataRoot(p.join(tmp.path, 'datos'));
    final packs = VoicePackManager(root.voices, bundledDirs: [p.join(inc, 'voces')]);
    await packs.refresh();
    final pack = packs.byId('vits-piper-es_ES-sharvard-medium')!;
    expect(pack.bundled, isTrue);
    expect(pack.files['model'], endsWith('es_ES-sharvard-medium.onnx'));
    expect(pack.files['dataDir'], endsWith('espeak-ng-data'));
    await packs.remove(pack.id); // no se borra lo incluido
    expect(Directory(pack.dir).existsSync(), isTrue);

    final speech = SpeechInput(root.speech, bundledDirs: [p.join(inc, 'reconocimiento')]);
    expect(speech.installed, ['sherpa-onnx-whisper-base']);
    expect(speech.isBundled('sherpa-onnx-whisper-base'), isTrue);
  });

  test('en Android se copian del APK una sola vez y quedan como instaladas', () async {
    final apk = p.join(tmp.path, 'apk');
    _fakeBundle(p.join(apk, 'incluidos'));
    final root = DataRoot(p.join(tmp.path, 'datos'));
    final source = _FolderSource(apk);
    final bundled = BundledModels(root, source: source);

    final manifest = await bundled.installFromAssets();
    expect(manifest, isNotNull);
    expect(bundled.busy, isFalse);
    expect(bundled.error, isNull);
    expect(source.copies, 6);

    final packs = VoicePackManager(root.voices);
    for (final id in manifest!.voices) {
      packs.register(id);
    }
    await packs.refresh();
    expect(packs.byId('vits-piper-es_ES-sharvard-medium')?.bundled, isFalse);
    expect(SpeechInput(root.speech).installed, ['sherpa-onnx-whisper-base']);

    // Segundo arranque: no se vuelve a copiar.
    expect(await BundledModels(root, source: source).installFromAssets(), isNull);
    expect(source.copies, 6);
  });

  test('un APK sin modelos incluidos no hace nada', () async {
    final root = DataRoot(p.join(tmp.path, 'datos'));
    expect(await BundledModels(root, source: _FolderSource(p.join(tmp.path, 'vacio'))).installFromAssets(), isNull);
  });

  test('todo el catálogo de voces y de Whisper va incluido en las tres plataformas', () {
    final tool = File(p.join('tool', 'incluir_modelos.py')).readAsStringSync();
    final todo = tool.substring(tool.indexOf('TODO = {'), tool.indexOf('PERFILES = '));
    List<String> ids(String key, String next) {
      final from = todo.indexOf("'$key'");
      final to = next.isEmpty ? todo.length : todo.indexOf("'$next'");
      return [for (final m in RegExp(r"'([\w.-]+)',").allMatches(todo.substring(from, to))) m.group(1)!];
    }

    expect(ids('voces', 'reconocimiento'), [for (final v in voicePackCatalog) v.id]);
    expect(ids('reconocimiento', ''), [for (final m in speechModelCatalog) m.id]);
    expect(tool, contains("PERFILES = {'windows': TODO, 'android': TODO, 'linux': TODO}"));
  });

  test('con todos los Whisper incluidos se usa base si no se ha elegido otro', () {
    final rec = p.join(tmp.path, 'reconocimiento');
    for (final m in ['tiny', 'base', 'small']) {
      _write(p.join(rec, 'sherpa-onnx-whisper-$m', '$m-encoder.int8.onnx'), 'e');
      _write(p.join(rec, 'sherpa-onnx-whisper-$m', '$m-decoder.int8.onnx'), 'd');
      _write(p.join(rec, 'sherpa-onnx-whisper-$m', '$m-tokens.txt'), 't');
    }
    final speech = SpeechInput(p.join(tmp.path, 'datos'), bundledDirs: [rec]);
    expect(speech.installed, hasLength(3));
    expect(speech.activeModel, 'sherpa-onnx-whisper-base');
    speech.select('sherpa-onnx-whisper-small');
    expect(speech.activeModel, 'sherpa-onnx-whisper-small');
  });

  test('las voces incluidas salen en el orden del catálogo', () async {
    final voces = p.join(tmp.path, 'voces');
    for (final v in voicePackCatalog.reversed) {
      _write(p.join(voces, v.id, 'model.onnx'), 'onnx');
      _write(p.join(voces, v.id, 'tokens.txt'), 'a 1');
    }
    final packs = VoicePackManager(p.join(tmp.path, 'datos'), bundledDirs: [voces]);
    await packs.refresh();
    expect([for (final e in packs.installed) e.id], [for (final v in voicePackCatalog) v.id]);
    expect(packs.installed.every((e) => e.bundled), isTrue);
  });
}
