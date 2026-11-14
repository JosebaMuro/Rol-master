@Tags(['e2e'])
library;

import 'dart:io';

import 'package:director_de_rol/voice/neural_tts.dart';
import 'package:director_de_rol/voice/voice_packs.dart';
import 'package:director_de_rol/voice/win_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final archive = Platform.environment['PIPER_ARCHIVE'];
  test('instala desde .tar.bz2 y sintetiza', () async {
    final root = Directory.systemTemp.createTempSync('voces');
    final m = VoicePackManager(root.path);
    await m.refresh();
    await m.installFromFile(archive!, 'vits');
    expect(m.installed, isNotEmpty);
    final pack = m.installed.first;
    print(pack.toJson());
    final out = '${root.path}/o.wav';
    final n = await NeuralTts().synthesize(pack: pack, text: 'Saludos, viajeros. ¿Qué os trae por aquí?', speakerId: 0, speed: 1.0, outPath: out);
    final b = File(out).readAsBytesSync();
    print('speakers=$n bytes=${b.length} dur=${WinNative.wavDuration(b)}');
    expect(b.length, greaterThan(10000));
  }, skip: archive == null ? 'sin PIPER_ARCHIVE' : false, timeout: const Timeout(Duration(minutes: 5)));
}
