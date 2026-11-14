import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Ficheros de un modelo Whisper instalado.
class SpeechModelFiles {
  const SpeechModelFiles({required this.encoder, required this.decoder, required this.tokens});
  final String encoder, decoder, tokens;

  bool get complete => [encoder, decoder, tokens].every((f) => f.isNotEmpty && File(f).existsSync());

  /// Busca encoder, decoder y tokens en una carpeta (prefiere int8).
  static SpeechModelFiles detect(String dir) {
    String enc = '', dec = '', tok = '';
    if (Directory(dir).existsSync()) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        final n = p.basename(f.path);
        if (n.endsWith('-encoder.int8.onnx') || (enc.isEmpty && n.endsWith('-encoder.onnx'))) enc = f.path;
        if (n.endsWith('-decoder.int8.onnx') || (dec.isEmpty && n.endsWith('-decoder.onnx'))) dec = f.path;
        if (n.endsWith('tokens.txt')) tok = f.path;
      }
    }
    return SpeechModelFiles(encoder: enc, decoder: dec, tokens: tok);
  }

  Map<String, String> toJson() => {'encoder': encoder, 'decoder': decoder, 'tokens': tokens};
}

/// Crea el reconocedor Whisper configurado para español.
sherpa.OfflineRecognizer createWhisperRecognizer(SpeechModelFiles files, {int threads = 2}) =>
    sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: files.encoder,
          decoder: files.decoder,
          language: 'es',
          task: 'transcribe',
        ),
        tokens: files.tokens,
        modelType: 'whisper',
        numThreads: threads,
        debug: false,
      ),
    ));

/// Transcribe un audio completo. Whisper trabaja en ventanas de 30 s, así
/// que lo largo se trocea.
String transcribeWith(sherpa.OfflineRecognizer rec, Float32List samples, int sampleRate) {
  final window = sampleRate * 28;
  final parts = <String>[];
  for (var start = 0; start < samples.length; start += window) {
    final end = (start + window).clamp(0, samples.length);
    final stream = rec.createStream();
    stream.acceptWaveform(samples: Float32List.sublistView(samples, start, end), sampleRate: sampleRate);
    rec.decode(stream);
    final t = rec.getResult(stream).text.trim();
    stream.free();
    if (t.isNotEmpty) parts.add(t);
  }
  return parts.join(' ');
}
