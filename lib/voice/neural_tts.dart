import 'dart:async';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_packs.dart';

/// Síntesis neuronal con sherpa-onnx en un isolate dedicado para no
/// bloquear la interfaz. Mantiene en memoria los modelos ya cargados.
class NeuralTts {
  SendPort? _port;
  Isolate? _isolate;
  final _pending = <int, Completer<Map>>{};
  var _nextId = 0;
  Completer<void>? _starting;

  Future<void> _ensure() async {
    if (_port != null) return;
    if (_starting != null) return _starting!.future;
    _starting = Completer<void>();
    final rx = ReceivePort();
    _isolate = await Isolate.spawn(_main, rx.sendPort);
    rx.listen((msg) {
      if (msg is SendPort) {
        _port = msg;
        _starting!.complete();
      } else if (msg is Map) {
        _pending.remove(msg['id'])?.complete(msg);
      }
    });
    return _starting!.future;
  }

  /// Genera un WAV en [outPath]. Devuelve el número de hablantes del modelo.
  Future<int> synthesize({
    required InstalledVoicePack pack,
    required String text,
    required int speakerId,
    required double speed,
    required String outPath,
  }) async {
    await _ensure();
    final id = _nextId++;
    final c = Completer<Map>();
    _pending[id] = c;
    _port!.send({
      'id': id,
      'pack': pack.toJson(),
      'text': text,
      'sid': speakerId,
      'speed': speed,
      'out': outPath,
    });
    final r = await c.future;
    if (r['error'] != null) throw Exception(r['error']);
    return (r['speakers'] as int?) ?? 1;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port = null;
    _starting = null;
  }

  static void _main(SendPort out) {
    final rx = ReceivePort();
    out.send(rx.sendPort);
    var initialized = false;
    final cache = <String, sherpa.OfflineTts>{};
    rx.listen((msg) {
      final m = msg as Map;
      try {
        if (!initialized) {
          sherpa.initBindings();
          initialized = true;
        }
        final pack = InstalledVoicePack.fromJson((m['pack'] as Map).cast<String, dynamic>());
        final tts = cache[pack.id] ??= _create(pack);
        final n = tts.numSpeakers;
        final sid = n <= 0 ? 0 : (m['sid'] as int) % n;
        final audio = tts.generate(text: m['text'] as String, sid: sid, speed: (m['speed'] as num).toDouble());
        if (audio.samples.isEmpty) throw Exception('el modelo no generó audio');
        sherpa.writeWave(filename: m['out'] as String, samples: audio.samples, sampleRate: audio.sampleRate);
        out.send({'id': m['id'], 'speakers': n});
      } catch (e) {
        out.send({'id': m['id'], 'error': '$e'});
      }
    });
  }

  static sherpa.OfflineTts _create(InstalledVoicePack pack) {
    final f = pack.files;
    final model = pack.kind == 'kokoro'
        ? sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: f['model'] ?? '',
              voices: f['voices'] ?? '',
              tokens: f['tokens'] ?? '',
              dataDir: f['dataDir'] ?? '',
              dictDir: f['dictDir'] ?? '',
              lexicon: f['lexicon'] ?? '',
              lang: 'es',
            ),
            numThreads: 2,
          )
        : sherpa.OfflineTtsModelConfig(
            vits: sherpa.OfflineTtsVitsModelConfig(
              model: f['model'] ?? '',
              tokens: f['tokens'] ?? '',
              dataDir: f['dataDir'] ?? '',
              lexicon: f['lexicon'] ?? '',
            ),
            numThreads: 2,
          );
    return sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: model));
  }
}
