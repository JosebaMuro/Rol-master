import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Preferencias de la aplicación, persistidas con shared_preferences.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static Future<AppSettings> load() async => AppSettings(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  String _s(String k, String d) => _prefs.getString(k) ?? d;
  void _set(String k, Object v) {
    switch (v) {
      case String s:
        _prefs.setString(k, s);
      case bool b:
        _prefs.setBool(k, b);
      case int i:
        _prefs.setInt(k, i);
      case double d:
        _prefs.setDouble(k, d);
    }
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
