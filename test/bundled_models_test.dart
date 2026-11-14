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
}
