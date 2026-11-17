import 'dart:convert';

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Almacén de ajustes en un fichero JSON dentro de la carpeta de datos, para
/// que la app sea portable (nada en el registro de Windows ni en AppData).
class JsonPrefs {
  JsonPrefs(this.path) {
    final f = path == null ? null : File(path!);
    if (f != null && f.existsSync()) {
      try {
        _data.addAll((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
      } catch (_) {}
    }
  }

  /// Sin ruta: sólo en memoria (pruebas).
  JsonPrefs.memory() : path = null;

  final String? path;
  final Map<String, Object?> _data = {};

  String? getString(String k) => _data[k] is String ? _data[k] as String : null;
  bool? getBool(String k) => _data[k] is bool ? _data[k] as bool : null;
  int? getInt(String k) => _data[k] is num ? (_data[k] as num).toInt() : null;
  double? getDouble(String k) => _data[k] is num ? (_data[k] as num).toDouble() : null;

  void set(String k, Object v) {
    _data[k] = v;
    if (path == null) return;
    try {
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_data));
      tmp.renameSync(path!);
    } catch (e) {
      debugPrint('No se pudieron guardar los ajustes: $e');
    }
  }
}

/// Preferencias de la aplicación, guardadas en `ajustes.json`.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  factory AppSettings.load(String path) => AppSettings(JsonPrefs(path));

  final JsonPrefs _prefs;

  String _s(String k, String d) => _prefs.getString(k) ?? d;
  void _set(String k, Object v) {
    _prefs.set(k, v);
    notifyListeners();
  }

  // ---- Motor de IA
  /// URI del modelo de chat: hf://..., https://... o ruta local a un .gguf.
  String get chatModel => _s('chatModel', '');
  set chatModel(String v) => _set('chatModel', v);

  /// Proyector de visión (mmproj) del modelo de chat; '' si no tiene.
  String get chatProjector => _s('chatProjector', '');
  set chatProjector(String v) => _set('chatProjector', v);

  String get embedModel => _s('embedModel', '');
  set embedModel(String v) => _set('embedModel', v);

  int get contextSize => _prefs.getInt('contextSize') ?? 8192;
  set contextSize(int v) => _set('contextSize', v);

  /// 'auto', 'cpu' o 'gpu'.
  String get device => _s('device', 'auto');
  set device(String v) => _set('device', v);

  /// 'auto', 'vulkan', 'cuda', 'opencl' o 'cpu'.
  String get backend => _s('backend', 'auto');
  set backend(String v) => _set('backend', v);

  int get gpuLayers => _prefs.getInt('gpuLayers') ?? 99;
  set gpuLayers(int v) => _set('gpuLayers', v);

  double get temperature => _prefs.getDouble('temperature') ?? 0.85;
  set temperature(double v) => _set('temperature', v);

  int get maxTokens => _prefs.getInt('maxTokens') ?? 900;
  set maxTokens(int v) => _set('maxTokens', v);

  /// Razonamiento (modo "thinking") del modelo antes de narrar.
  bool get thinking => _prefs.getBool('thinking') ?? true;
  set thinking(bool v) => _set('thinking', v);

  int get thinkingBudget => _prefs.getInt('thinkingBudget') ?? 768;
  set thinkingBudget(int v) => _set('thinkingBudget', v);

  bool get showThinking => _prefs.getBool('showThinking') ?? false;
  set showThinking(bool v) => _set('showThinking', v);

  // ---- Panel gráfico de la partida
  bool get showScenePanel => _prefs.getBool('showScenePanel') ?? true;
  set showScenePanel(bool v) => _set('showScenePanel', v);

  /// Imagen de fondo (ruta guardada) para un tipo de escena; '' = ninguna.
  String sceneBackground(String sceneId) => _s('fondo_$sceneId', '');
  void setSceneBackground(String sceneId, String storedPath) => _set('fondo_$sceneId', storedPath);

  // ---- Voces
  bool get voiceEnabled => _prefs.getBool('voiceEnabled') ?? true;
  set voiceEnabled(bool v) => _set('voiceEnabled', v);

  bool get narrateNarration => _prefs.getBool('narrateNarration') ?? true;
  set narrateNarration(bool v) => _set('narrateNarration', v);

  VoiceProfile get narratorVoice => VoiceProfile.decode(_prefs.getString('narratorVoice'));
  set narratorVoice(VoiceProfile v) => _set('narratorVoice', v.encode());

  /// Motor de voz por defecto para PNJ nuevos: 'system' o 'neural'.
  String get defaultVoiceEngine => _s('defaultVoiceEngine', 'system');
  set defaultVoiceEngine(String v) => _set('defaultVoiceEngine', v);

  String get defaultNeuralPack => _s('defaultNeuralPack', '');
  set defaultNeuralPack(String v) => _set('defaultNeuralPack', v);

  // ---- Música
  /// Si es true, la música sugerida por la IA se reproduce sola. Por defecto
  /// el usuario elige siempre qué suena.
  bool get autoMusic => _prefs.getBool('autoMusic') ?? false;
  set autoMusic(bool v) => _set('autoMusic', v);

  double get musicVolume => _prefs.getDouble('musicVolume') ?? 0.6;
  set musicVolume(double v) => _set('musicVolume', v);

  bool get duckMusic => _prefs.getBool('duckMusic') ?? true;
  set duckMusic(bool v) => _set('duckMusic', v);

  // ---- Juego
  /// Cada cuántos turnos avanza el mundo por su cuenta (0 = nunca).
  int get worldEvery => _prefs.getInt('worldEvery') ?? 4;
  set worldEvery(int v) => _set('worldEvery', v);

  // ---- Reconocimiento de voz (jugar hablando)
  String get speechModel => _s('speechModel', '');
  set speechModel(String v) => _set('speechModel', v);

  /// Enviar en cuanto se reconoce el texto, sin revisarlo antes.
  bool get speechAutoSend => _prefs.getBool('speechAutoSend') ?? false;
  set speechAutoSend(bool v) => _set('speechAutoSend', v);

  // ---- Varios
  List<String> get recentModels {
    final s = _prefs.getString('recentModels');
    if (s == null) return const [];
    return (jsonDecode(s) as List).cast<String>();
  }

  void addRecentModel(String uri) {
    final l = [uri, ...recentModels.where((e) => e != uri)].take(8).toList();
    _set('recentModels', jsonEncode(l));
  }
}
