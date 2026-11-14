import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'whisper.dart';
import 'win_native.dart';

export 'whisper.dart' show SpeechModelFiles;

/// Modelo de reconocimiento de voz (Whisper para sherpa-onnx). Funciona sin
/// Internet una vez descargado.
class SpeechModelInfo {
  const SpeechModelInfo(this.id, this.label, this.sizeMb, this.description);
  final String id;
  final String label;
  final int sizeMb;
  final String description;
  String get url => 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$id.tar.bz2';
}

const speechModelCatalog = <SpeechModelInfo>[
  SpeechModelInfo('sherpa-onnx-whisper-tiny', 'Whisper tiny', 116, 'Rápido, para móvil. Entiende bien frases claras.'),
  SpeechModelInfo('sherpa-onnx-whisper-base', 'Whisper base', 208, 'Equilibrio recomendado: más preciso y aún ágil.'),
  SpeechModelInfo('sherpa-onnx-whisper-small', 'Whisper small', 640, 'El más preciso. Mejor en PC.'),
];

/// Graba con el micrófono y transcribe en local con Whisper (sherpa-onnx).
/// Pulsar para empezar a hablar y otra vez para terminar: el texto queda en
/// la caja de la partida para revisarlo antes de enviarlo.
class SpeechInput extends ChangeNotifier {
  SpeechInput(this.rootDir, {this.selectedModel = '', this.bundledDirs = const []});
  final String rootDir;

  /// Carpetas de sólo lectura con modelos que trae la app (en Windows,
  /// `incluidos/reconocimiento` junto al ejecutable).
  final List<String> bundledDirs;

  /// Id del modelo elegido ('' = el primero instalado).
  String selectedModel;

  final Map<String, double?> downloading = {};
  final Map<String, String> errors = {};

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  final _pcm = BytesBuilder(copy: false);
  bool recording = false;
  bool transcribing = false;
  double level = 0;
  static const sampleRate = 16000;

  _Worker? _worker;

  /// Carpeta del modelo [id]: la descargada si existe y si no, la incluida
  /// con la app. null si no está.
  String? dirFor(String id) {
    for (final base in [rootDir, ...bundledDirs]) {
      final d = p.join(base, id);
      if (SpeechModelFiles.detect(d).complete) return d;
    }
    return null;
  }

  /// Si el modelo viene con la app (y no hay copia propia que borrar).
  bool isBundled(String id) {
    final d = dirFor(id);
    return d != null && !p.isWithin(rootDir, d);
  }

  /// Vuelve a mirar qué modelos hay (tras copiar los incluidos).
  void rescan() => notifyListeners();

  List<String> get installed => [
        for (final m in speechModelCatalog)
          if (dirFor(m.id) != null) m.id,
      ];

  String? get activeModel {
    final list = installed;
    if (list.isEmpty) return null;
    return list.contains(selectedModel) ? selectedModel : list.first;
  }

  bool get available => activeModel != null;

  void select(String id) {
    selectedModel = id;
    _worker?.dispose();
    _worker = null;
    notifyListeners();
  }

  Future<void> install(SpeechModelInfo info) async {
    downloading[info.id] = 0;
    errors.remove(info.id);
    notifyListeners();
    Directory(rootDir).createSync(recursive: true);
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
      await installFromFile(tmp.path);
    } catch (e) {
      errors[info.id] = '$e';
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
      downloading.remove(info.id);
      notifyListeners();
    }
  }

  /// Instala un .tar.bz2 descargado a mano (sin Internet en el equipo).
  Future<void> installFromFile(String archive) async {
    final dest = rootDir;
    await Isolate.run(() => extractFileToDisk(archive, dest));
    // Las grabaciones de ejemplo no hacen falta.
    for (final d in Directory(rootDir).listSync(recursive: true).whereType<Directory>().toList()) {
      if (p.basename(d.path) == 'test_wavs') d.deleteSync(recursive: true);
    }
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final d = Directory(p.join(rootDir, id));
    if (d.existsSync()) d.deleteSync(recursive: true);
    _worker?.dispose();
    _worker = null;
    notifyListeners();
  }

  /// Empieza a grabar. Devuelve un mensaje de error si no se puede.
  Future<String?> start() async {
    if (recording || transcribing) return null;
    if (!available) return 'Descarga un modelo de reconocimiento de voz en Ajustes';
    final rec = _recorder ??= AudioRecorder();
    try {
      if (!await rec.hasPermission()) return 'Sin permiso para usar el micrófono';
      _pcm.clear();
      final stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ));
      _sub = stream.listen((data) {
        _pcm.add(data);
        level = _rms(data);
        notifyListeners();
      });
      recording = true;
      notifyListeners();
      return null;
    } catch (e) {
      return 'No se pudo abrir el micrófono: $e';
    }
  }

  /// Termina la grabación y devuelve el texto reconocido.
  Future<String> stop() async {
    if (!recording) return '';
    recording = false;
    level = 0;
    transcribing = true;
    notifyListeners();
    try {
      await _recorder?.stop();
      await _sub?.cancel();
      _sub = null;
      final bytes = _pcm.takeBytes();
      if (bytes.length < sampleRate) return ''; // menos de medio segundo
      final samples = pcm16ToFloat(bytes);
      final model = activeModel!;
      final found = SpeechModelFiles.detect(dirFor(model)!);
      // En Windows sherpa-onnx no abre rutas con tildes: se usan las cortas.
      final files = SpeechModelFiles(
        encoder: WinNative.safePath(found.encoder),
        decoder: WinNative.safePath(found.decoder),
        tokens: WinNative.safePath(found.tokens),
      );
      _worker ??= _Worker();
      return (await _worker!.transcribe(files, samples)).trim();
    } finally {
      transcribing = false;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    if (!recording) return;
    recording = false;
    await _recorder?.stop();
    await _sub?.cancel();
    _sub = null;
    _pcm.clear();
    notifyListeners();
  }

  static double _rms(Uint8List data) {
    final v = ByteData.sublistView(data);
    var sum = 0.0;
    final n = data.lengthInBytes ~/ 2;
    if (n == 0) return 0;
    for (var i = 0; i < n; i++) {
      final s = v.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return (sum / n).clamp(0.0, 1.0);
  }

  /// PCM de 16 bits little-endian a muestras en coma flotante (-1..1).
  static Float32List pcm16ToFloat(Uint8List bytes) {
    final v = ByteData.sublistView(bytes);
    final n = bytes.lengthInBytes ~/ 2;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = v.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder?.dispose();
    _worker?.dispose();
    super.dispose();
  }
}

/// Reconocimiento en un isolate aparte para no congelar la interfaz.
class _Worker {
  SendPort? _port;
  Isolate? _isolate;
  Completer<void>? _starting;
  final _pending = <int, Completer<String>>{};
  var _next = 0;

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
        final c = _pending.remove(msg['id']);
        if (msg['error'] != null) {
          c?.completeError(Exception(msg['error']));
        } else {
          c?.complete(msg['text'] as String);
        }
      }
    });
    return _starting!.future;
  }

  Future<String> transcribe(SpeechModelFiles files, Float32List samples) async {
    await _ensure();
    final id = _next++;
    final c = Completer<String>();
    _pending[id] = c;
    _port!.send({'id': id, 'files': files.toJson(), 'samples': TransferableTypedData.fromList([samples])});
    return c.future;
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
    final cache = <String, sherpa.OfflineRecognizer>{};
    rx.listen((msg) {
      final m = msg as Map;
      try {
        if (!initialized) {
          sherpa.initBindings();
          initialized = true;
        }
        final f = (m['files'] as Map).cast<String, String>();
        final rec = cache[f['encoder']!] ??= createWhisperRecognizer(
          SpeechModelFiles(encoder: f['encoder']!, decoder: f['decoder']!, tokens: f['tokens']!),
        );
        final samples = (m['samples'] as TransferableTypedData).materialize().asFloat32List();
        out.send({'id': m['id'], 'text': transcribeWith(rec, samples, SpeechInput.sampleRate)});
      } catch (e) {
        out.send({'id': m['id'], 'error': '$e'});
      }
    });
  }
}
