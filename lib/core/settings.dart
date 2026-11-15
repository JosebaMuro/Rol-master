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

  // ---- Imágenes de apoyo (retratos, cuerpos enteros y escenas)
  /// Motor que genera las imágenes: '' (el que haya disponible), 'local'
  /// (stable-diffusion.cpp en este equipo), 'openai' (servicio compatible
  /// con la API de imágenes de OpenAI), 'a1111' (servidor Automatic1111 /
  /// Forge, p. ej. en el PC de casa) o 'none' (sólo imágenes a mano).
  String get imageEngine => _s('imageEngine', '');
  set imageEngine(String v) => _set('imageEngine', v);

  /// Estilo que se añade a todas las imágenes generadas.
  String get imageStyle => _s('imageStyle', 'ilustración de fantasía, pintura digital detallada, luz dramática');
  set imageStyle(String v) => _set('imageStyle', v);

  /// Imágenes grandes (1024 px de lado largo en vez de 768): más lentas.
  bool get imageLarge => _prefs.getBool('imageLarge') ?? false;
  set imageLarge(bool v) => _set('imageLarge', v);

  /// Generar sola la imagen de cada escena nueva durante la partida.
  bool get imageAuto => _prefs.getBool('imageAuto') ?? true;
  set imageAuto(bool v) => _set('imageAuto', v);

  /// Modelo local: fichero único (SD 1.5, SDXL…) o modelo de difusión.
  String get sdModel => _s('sdModel', '');
  set sdModel(String v) => _set('sdModel', v);

  /// VAE y codificador de texto (sólo los modelos que van en piezas).
  String get sdVae => _s('sdVae', '');
  set sdVae(String v) => _set('sdVae', v);
  String get sdLlm => _s('sdLlm', '');
  set sdLlm(String v) => _set('sdLlm', v);

  int get sdSteps => _prefs.getInt('sdSteps') ?? 20;
  set sdSteps(int v) => _set('sdSteps', v);
  double get sdCfg => _prefs.getDouble('sdCfg') ?? 7.0;
  set sdCfg(double v) => _set('sdCfg', v);

  /// Ahorrar memoria de vídeo (más lento; para gráficas de 4-6 GB).
  bool get sdLowVram => _prefs.getBool('sdLowVram') ?? true;
  set sdLowVram(bool v) => _set('sdLowVram', v);

  /// Ruta de sd-cli si no es el que viene con la app.
  String get sdExe => _s('sdExe', '');
  set sdExe(String v) => _set('sdExe', v);

  /// Servicio externo: dirección, clave y modelo. La clave se queda en este
  /// equipo (ajustes.json) y nunca viaja en un .rolpack.
  String get imageApiUrl => _s('imageApiUrl', '');
  set imageApiUrl(String v) => _set('imageApiUrl', v);
  String get imageApiKey => _s('imageApiKey', '');
  set imageApiKey(String v) => _set('imageApiKey', v);
  String get imageApiModel => _s('imageApiModel', '');
  set imageApiModel(String v) => _set('imageApiModel', v);

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
