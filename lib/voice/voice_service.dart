import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;

import '../ai/narration_parser.dart';
import '../core/db.dart';
import '../core/models.dart';
import '../core/settings.dart';
import 'neural_tts.dart';
import 'voice_packs.dart';
import 'win_native.dart';
import 'windows_tts.dart';

/// Línea a locutar con la voz que le corresponde.
class SpeechLine {
  const SpeechLine(this.text, this.voice, {this.speaker});
  final String text;
  final VoiceProfile voice;
  final String? speaker;
}

/// Voces de la partida. El narrador tiene su voz y cada PNJ la suya, ya sea
/// con el TTS del sistema (Windows SAPI / Android TextToSpeech) variando voz,
/// tono y velocidad, o con voces neuronales locales (sherpa-onnx).
class VoiceService extends ChangeNotifier {
  VoiceService({required this.settings, required this.packs, required this.tempDir});

  final AppSettings settings;
  final VoicePackManager packs;
  final String tempDir;

  // En Windows el plugin flutter_tts cierra la app al parar la voz, así que
  // allí se usa WindowsTts (sintetiza a WAV y lo reproduce la app).
  final FlutterTts? _tts = (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) ? FlutterTts() : null;
  late final WindowsTts? _win = Platform.isWindows ? WindowsTts(scriptDir: tempDir) : null;
  final AudioPlayer _player = AudioPlayer(playerId: 'voice');
  final NeuralTts _neural = NeuralTts();

  List<Map<String, String>> systemVoices = [];
  bool speaking = false;
  /// Último fallo de la voz (se muestra al probar voces).
  String? lastError;

  void _setError(String? e) {
    if (e != null) _log('ERROR: $e');
    if (lastError == e) return;
    lastError = e;
    notifyListeners();
  }

  void clearError() => _setError(null);

  /// Registro de lo que hace la voz (para el diagnóstico que se puede copiar).
  final List<String> log = [];

  void _log(String s) {
    final t = DateTime.now().toIso8601String().substring(11, 23);
    log.add('$t $s');
    if (log.length > 400) log.removeRange(0, log.length - 400);
    debugPrint('Voz: $s');
  }
  String? currentSpeaker;
  int _generation = 0;
  Completer<void>? _playing;

  /// Para bajar el volumen de la música mientras se habla.
  void Function(bool speaking)? onSpeakingChanged;

  bool get systemAvailable => _tts != null || _win != null;

  Future<void> init() async {
    final win = _win;
    if (win != null) {
      final all = await win.voices();
      final es = all.where((v) => (v['locale'] ?? '').toLowerCase().startsWith('es')).toList();
      systemVoices = es.isNotEmpty ? es : all;
      if (all.isEmpty && win.lastError != null) lastError = 'Voz del sistema: ${win.lastError}';
      notifyListeners();
      return;
    }
    final tts = _tts;
    if (tts == null) return;
    try {
      await tts.awaitSpeakCompletion(true);
      final voices = await tts.getVoices;
      if (voices is List) {
        systemVoices = voices
            .whereType<Map>()
            .map((v) => v.map((k, val) => MapEntry('$k', '$val')))
            .where((v) => (v['locale'] ?? '').toLowerCase().startsWith('es'))
            .toList();
      }
      if (systemVoices.isEmpty) await tts.setLanguage('es-ES');
    } catch (e) {
      debugPrint('TTS del sistema no disponible: $e');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ asignación
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Asigna una voz distinta y estable a un PNJ a partir de su nombre y de
  /// la pista de voz que dio la IA (género, edad, timbre).
  VoiceProfile assign(int campaignId, String name, String hint) {
    final h = _hash('$campaignId:$name');
    final hn = AppDatabase.normalize(hint);
    final female = hn.contains('mujer') || hn.contains('femen') || hn.contains('anciana') || hn.contains('nina') || hn.contains('chica') || hn.contains('dama');
    final male = !female && (hn.contains('hombre') || hn.contains('mascul') || hn.contains('anciano') || hn.contains('nino'));
    final child = hn.contains('nino') || hn.contains('nina') || hn.contains('infantil');
    final old = hn.contains('anciano') || hn.contains('anciana') || hn.contains('viej');
    final deep = hn.contains('grave') || hn.contains('ronc') || hn.contains('villano') || hn.contains('profund');

    var pitch = female ? 1.2 : (male ? 0.85 : 1.0);
    var rate = 0.5;
    if (child) pitch += 0.35;
    if (old) {
      pitch -= 0.1;
      rate -= 0.08;
    }
    if (deep) pitch -= 0.15;
    // Variación individual para que dos PNJ parecidos no suenen igual.
    pitch += ((h % 17) - 8) / 100.0;
    rate += ((h ~/ 17 % 9) - 4) / 100.0;

    if (settings.defaultVoiceEngine == 'neural') {
      final pack = packs.byId(settings.defaultNeuralPack) ?? packs.installed.firstOrNull;
      if (pack != null) {
        final n = pack.numSpeakers <= 0 ? 1 : pack.numSpeakers;
        return VoiceProfile(
          engine: 'neural',
          neuralPack: pack.id,
          speakerId: h % n,
          speed: (1.0 + ((h % 11) - 5) / 50.0) * (old ? 0.9 : 1.0),
          pitch: pitch.clamp(0.5, 2.0),
          rate: rate.clamp(0.2, 0.9),
        );
      }
    }

    var voiceName = '', locale = '';
    if (systemVoices.isNotEmpty) {
      var candidates = systemVoices;
      final byGender = systemVoices.where((v) {
        final n = AppDatabase.normalize('${v['name']} ${v['gender'] ?? ''}');
        if (female) return n.contains('female') || n.contains('helena') || n.contains('laura') || n.contains('sabina') || n.contains('elvira');
        if (male) return n.contains('male') && !n.contains('female') || n.contains('pablo') || n.contains('raul') || n.contains('alvaro');
        return false;
      }).toList();
      if (byGender.isNotEmpty) candidates = byGender;
      final v = candidates[h % candidates.length];
      voiceName = v['name'] ?? '';
      locale = v['locale'] ?? '';
    }
    return VoiceProfile(
      engine: 'system',
      systemVoice: voiceName,
      systemLocale: locale,
      pitch: pitch.clamp(0.5, 2.0),
      rate: rate.clamp(0.2, 0.9),
    );
  }

  // ------------------------------------------------------------- locución
  List<SpeechLine> linesFor(ParsedNarration parsed, List<Npc> npcs) {
    final byName = {for (final n in npcs) AppDatabase.normalize(n.name): n};
    final out = <SpeechLine>[];
    for (final s in parsed.segments) {
      if (s.isDialogue) {
        final npc = byName[AppDatabase.normalize(s.speaker!)];
        out.add(SpeechLine(s.text, npc?.voice ?? assign(0, s.speaker!, ''), speaker: s.speaker));
      } else if (settings.narrateNarration) {
        out.add(SpeechLine(_clean(s.text), settings.narratorVoice));
      }
    }
    return out;
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'[*_#>`]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<void> speakAll(List<SpeechLine> lines) async {
    if (!settings.voiceEnabled) {
      _log('speakAll ignorado: voces desactivadas en Ajustes');
      return;
    }
    if (lines.isEmpty) {
      _log('speakAll sin líneas que leer');
      return;
    }
    _log('speakAll: ${lines.length} línea(s)');
    await stop();
    final gen = ++_generation;
    _setSpeaking(true);
    try {
      for (final l in lines) {
        if (gen != _generation) break;
        currentSpeaker = l.speaker;
        notifyListeners();
        await speak(l.text, l.voice);
      }
    } finally {
      if (gen == _generation) {
        currentSpeaker = null;
        _setSpeaking(false);
      }
    }
  }

  Future<void> speak(String text, VoiceProfile v) async {
    if (text.trim().isEmpty) return;
    _log('speak motor=${v.engine} pack=${v.neuralPack} voz="${v.systemVoice}" texto=${text.length} car.');
    if (v.engine == 'neural' && packs.byId(v.neuralPack) == null) {
      _log('el paquete neuronal "${v.neuralPack}" no está instalado; se usa la voz del sistema');
    }
    if (v.engine == 'neural' && packs.byId(v.neuralPack) != null) {
      try {
        await _speakNeural(text, v);
        _setError(null);
        return;
      } catch (e) {
        debugPrint('Voz neuronal falló, uso la del sistema: $e');
        final neural = 'La voz neuronal falló: ${_msg(e)}';
        try {
          await _speakSystem(text, v);
          _setError('$neural. Se usó la voz del sistema.');
        } catch (e2) {
          _setError('$neural. Y la del sistema también: ${_msg(e2)}');
        }
        return;
      }
    }
    try {
      await _speakSystem(text, v);
      _setError(null);
    } catch (e) {
      debugPrint('Voz del sistema falló: $e');
      _setError('La voz del sistema falló: ${_msg(e)}');
    }
  }

  static String _msg(Object e) => '$e'.replaceFirst('Exception: ', '');

  Future<void> _speakSystem(String text, VoiceProfile v) async {
    final gen = _generation;
    final win = _win;
    if (win != null) {
      final out = p.join(tempDir, 'tts_${DateTime.now().microsecondsSinceEpoch}.wav');
      try {
        Directory(tempDir).createSync(recursive: true);
        await win.synthesize(
          text: text,
          outPath: out,
          voice: v.systemVoice,
          locale: v.systemLocale.isEmpty ? 'es-ES' : v.systemLocale,
          pitch: v.pitch,
          rate: v.rate * 2, // 0,5 en el perfil = velocidad normal
        );
        _log('voz de Windows sintetizada: ${_size(out)}');
        await _playFile(out, gen);
      } finally {
        try {
          File(out).deleteSync();
        } catch (_) {}
      }
      return;
    }
    final tts = _tts;
    if (tts == null) return;
    if (v.systemVoice.isNotEmpty) {
      await tts.setVoice({'name': v.systemVoice, 'locale': v.systemLocale});
    } else {
      await tts.setLanguage('es-ES');
    }
    await tts.setPitch(v.pitch);
    await tts.setSpeechRate(v.rate);
    final sw = Stopwatch()..start();
    final r = await tts.speak(text);
    _log('TTS de Android speak() devolvió $r en ${sw.elapsedMilliseconds} ms');
    if (r == 0) throw Exception('el TTS de Android no pudo hablar (código $r). Revisa el motor de voz en Ajustes de Android › Accesibilidad › Texto a voz');
  }

  static String _size(String path) {
    try {
      final b = File(path).readAsBytesSync();
      final kb = (b.length / 1024).toStringAsFixed(1);
      try {
        return '$kb KB, ${(WinNative.wavDuration(b).inMilliseconds / 1000).toStringAsFixed(2)} s';
      } catch (e) {
        return '$kb KB (${_msg(e)})';
      }
    } catch (_) {
      return 'sin fichero';
    }
  }

  Future<void> _speakNeural(String text, VoiceProfile v) async {
    final gen = _generation;
    final pack = packs.byId(v.neuralPack)!;
    // Si falta algún fichero, sherpa-onnx abortaría el proceso: se comprueba antes.
    for (final k in const ['model', 'tokens']) {
      final path = pack.files[k] ?? '';
      if (path.isEmpty || !File(path).existsSync()) throw Exception('Falta $k en la voz ${pack.id}');
    }
    if (pack.kind == 'kokoro' && !File(pack.files['voices'] ?? '').existsSync()) {
      throw Exception('Falta voices en la voz ${pack.id}');
    }
    for (final k in const ['dataDir', 'dictDir']) {
      final path = pack.files[k] ?? '';
      if (path.isNotEmpty && !Directory(path).existsSync()) throw Exception('Falta $k en la voz ${pack.id}');
    }
    Directory(tempDir).createSync(recursive: true);
    final out = p.join(tempDir, 'tts_${DateTime.now().microsecondsSinceEpoch}.wav');
    // En Windows sherpa-onnx/espeak-ng no abren rutas con tildes o eñes: se
    // les pasan las rutas cortas (8.3), que son sólo ASCII.
    final native = Platform.isWindows
        ? InstalledVoicePack(
            id: pack.id,
            kind: pack.kind,
            dir: WinNative.safePath(pack.dir),
            files: {
              for (final e in pack.files.entries) e.key: e.value.split(',').map(WinNative.safePath).join(','),
            },
            numSpeakers: pack.numSpeakers,
          )
        : pack;
    try {
      final n = await _neural.synthesize(
          pack: native, text: text, speakerId: v.speakerId, speed: v.speed, outPath: WinNative.safePath(out));
      packs.setSpeakers(pack.id, n);
      _log('voz neuronal ${pack.id} sintetizada: ${_size(out)}');
      await _playFile(out, gen);
    } finally {
      try {
        File(out).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _playFile(String out, int gen) async {
    if (gen != _generation) {
      _log('reproducción cancelada (se paró la voz mientras se generaba)');
      return;
    }
    if (!File(out).existsSync()) throw Exception('No se generó el audio');
    final sw = Stopwatch()..start();
    if (Platform.isWindows) {
      // PlaySound de Windows: no depende de Media Foundation.
      await WinNative.play(out);
      _log('reproducido con PlaySound en ${sw.elapsedMilliseconds} ms');
      return;
    }
    final done = Completer<void>();
    _playing = done;
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.setVolume(1.0);
      await _player.play(DeviceFileSource(out));
      _log('audioplayers reproduciendo (estado ${_player.state.name})');
      await done.future.timeout(const Duration(minutes: 3), onTimeout: () {
        _log('audioplayers no avisó del final en 3 min');
      });
      _log('reproducido con audioplayers en ${sw.elapsedMilliseconds} ms');
    } finally {
      await sub.cancel();
      try {
        await _player.release().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  /// WAV con un pitido de [ms] milisegundos (para probar la salida de audio).
  static Uint8List toneWav({int ms = 700, int rate = 22050, double freq = 440}) {
    final n = rate * ms ~/ 1000;
    final data = ByteData(44 + n * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      final fade = math.min(1.0, math.min(i, n - i) / (rate * 0.02));
      final v = math.sin(2 * math.pi * freq * i / rate) * 0.5 * fade;
      data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// Prueba paso a paso la salida de audio, la voz del sistema y cada voz
  /// neuronal instalada. Devuelve un informe que el usuario puede copiar.
  Future<String> diagnose({void Function(String step)? onStep}) async {
    final out = StringBuffer();
    void line(String s) {
      out.writeln(s);
      _log('[diag] $s');
    }

    Future<void> step(String name, Future<void> Function() body) async {
      onStep?.call(name);
      final sw = Stopwatch()..start();
      try {
        await body();
        line('✔ $name (${sw.elapsedMilliseconds} ms)');
      } catch (e) {
        line('✘ $name (${sw.elapsedMilliseconds} ms): ${_msg(e)}');
      }
    }

    await stop();
    _setError(null);
    line('Diagnóstico de voces · ${DateTime.now().toIso8601String().substring(0, 19)}');
    line('Sistema: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    line('Voces activadas: ${settings.voiceEnabled} · motor por defecto: ${settings.defaultVoiceEngine} · narrar: ${settings.narrateNarration}');
    line('Narrador: motor=${settings.narratorVoice.engine} pack=${settings.narratorVoice.neuralPack} voz="${settings.narratorVoice.systemVoice}"');
    line('Carpeta temporal: $tempDir');
    await step('Escribir en la carpeta temporal', () async {
      Directory(tempDir).createSync(recursive: true);
      final f = File(p.join(tempDir, 'prueba.txt'))..writeAsStringSync('ok');
      f.deleteSync();
    });
    if (_win != null && systemVoices.isEmpty) await init();
    line('Voces del sistema (${systemVoices.length}): ${systemVoices.take(8).map((v) => '${v['name']} [${v['locale']}]').join(', ')}');
    if (_win?.lastError != null) line('Motor de Windows: ${_win!.lastError}');
    for (final pk in packs.installed) {
      final missing = pk.files.entries.where((e) => e.value.split(',').any((f) => !File(f).existsSync() && !Directory(f).existsSync())).map((e) => e.key);
      line('Paquete ${pk.id} (${pk.kind}): ficheros ${pk.files.keys.join('/')}${missing.isEmpty ? '' : ' · FALTAN: ${missing.join(', ')}'}');
    }
    if (packs.installed.isEmpty) line('No hay voces neuronales instaladas.');

    final gen = ++_generation;
    await step('Pitido por la salida de audio (debería oírse)', () async {
      final f = File(p.join(tempDir, 'pitido_${DateTime.now().microsecondsSinceEpoch}.wav'))..writeAsBytesSync(toneWav());
      try {
        await _playFile(f.path, gen);
      } finally {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    });
    final sys = VoiceProfile(
      engine: 'system',
      systemVoice: systemVoices.isEmpty ? '' : systemVoices.first['name'] ?? '',
      systemLocale: systemVoices.isEmpty ? 'es-ES' : systemVoices.first['locale'] ?? 'es-ES',
    );
    await step('Voz del sistema', () async {
      _generation = gen;
      await _speakSystem('Prueba de la voz del sistema.', sys);
    });
    for (final pk in packs.installed) {
      await step('Voz neuronal ${pk.id}', () async {
        _generation = gen;
        await _speakNeural('Prueba de la voz neuronal.', VoiceProfile(engine: 'neural', neuralPack: pk.id));
      });
    }
    line('');
    line('Registro reciente:');
    for (final l in log.reversed.take(60).toList().reversed) {
      out.writeln(l);
    }
    return out.toString();
  }

  Future<void> stop() async {
    _generation++;
    // Con tiempo límite: si un plugin no responde, la voz no debe quedarse
    // bloqueada para siempre (antes speakAll esperaba aquí sin avisar).
    Future<void> guarded(String what, Future<dynamic>? Function() f) async {
      try {
        await f()?.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _log('$what no respondió al parar');
      } catch (_) {}
    }

    if (Platform.isWindows) {
      WinNative.stop();
    } else {
      await guarded('El TTS del sistema', () => _tts?.stop());
      await guarded('El reproductor', () => _player.stop());
    }
    if (_playing != null && !_playing!.isCompleted) _playing!.complete();
    currentSpeaker = null;
    _setSpeaking(false);
  }

  void _setSpeaking(bool v) {
    if (speaking == v) return;
    speaking = v;
    onSpeakingChanged?.call(v);
    notifyListeners();
  }

  @override
  void dispose() {
    _neural.dispose();
    _win?.dispose();
    _player.dispose();
    super.dispose();
  }
}
