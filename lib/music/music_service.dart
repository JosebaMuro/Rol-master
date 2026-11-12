import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/db.dart';
import '../core/models.dart';
import '../core/settings.dart';

/// Biblioteca musical por situaciones. El usuario asigna sus pistas a
/// situaciones (combate, taberna, misterio...) y elige qué suena desde un
/// menú. Hace fundido cruzado entre pistas y baja el volumen cuando hablan
/// las voces.
class MusicService extends ChangeNotifier {
  MusicService(this.db, this.settings);

  final AppDatabase db;
  final AppSettings settings;

  final _a = AudioPlayer(playerId: 'music_a');
  final _b = AudioPlayer(playerId: 'music_b');
  bool _useA = true;
  final _rnd = Random();

  Situation? currentSituation;
  Track? currentTrack;
  bool playing = false;
  bool shuffle = true;
  bool _ducked = false;
  StreamSubscription? _completeA, _completeB;
  Timer? _fadeTimer;

  static const audioExtensions = {'.mp3', '.ogg', '.wav', '.flac', '.m4a', '.aac', '.opus'};

  AudioPlayer get _current => _useA ? _a : _b;

  double get _targetVolume => settings.musicVolume * (_ducked ? 0.3 : 1.0) * (currentTrack?.volume ?? 1.0);

  void init() {
    _completeA = _a.onPlayerComplete.listen((_) => _next());
    _completeB = _b.onPlayerComplete.listen((_) => _next());
  }

  // ---------------------------------------------------------- biblioteca
  List<Track> addFiles(List<String> paths, {int? situationId}) {
    final out = <Track>[];
    for (final path in paths) {
      if (!audioExtensions.contains(p.extension(path).toLowerCase())) continue;
      out.add(db.addTrack(Track(path: path, title: p.basenameWithoutExtension(path), situationId: situationId)));
    }
    notifyListeners();
    return out;
  }

  /// Importa una carpeta. Si contiene subcarpetas con nombre de situación
  /// ("Combate", "Taberna"...), las pistas se asignan solas.
  int addFolder(String dir) {
    final situations = {for (final s in db.situations()) AppDatabase.normalize(s.name): s};
    var n = 0;
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
      if (!audioExtensions.contains(p.extension(f.path).toLowerCase())) continue;
      int? sid;
      for (final part in p.split(p.relative(f.path, from: dir))) {
        final s = situations[AppDatabase.normalize(part)];
        if (s != null) sid = s.id;
      }
      db.addTrack(Track(path: f.path, title: p.basenameWithoutExtension(f.path), situationId: sid));
      n++;
    }
    notifyListeners();
    return n;
  }

  void changed() => notifyListeners();

  Situation? situationByName(String name) {
    final n = AppDatabase.normalize(name);
    for (final s in db.situations()) {
      final sn = AppDatabase.normalize(s.name);
      if (sn == n || sn.contains(n) || n.contains(sn)) return s;
    }
    return null;
  }

  // ---------------------------------------------------------- reproducción
  Future<void> playSituation(Situation s) async {
    final tracks = db.tracks(situationId: s.id);
    currentSituation = s;
    if (tracks.isEmpty) {
      notifyListeners();
      return;
    }
    final t = shuffle ? tracks[_rnd.nextInt(tracks.length)] : tracks.first;
    await playTrack(t, situation: s);
  }

  Future<void> playTrack(Track t, {Situation? situation}) async {
    if (situation != null) currentSituation = situation;
    currentTrack = t;
    playing = true;
    notifyListeners();
    final from = _current;
    _useA = !_useA;
    final to = _current;
    try {
      await to.setVolume(0);
      await to.setReleaseMode(ReleaseMode.release);
      await to.play(DeviceFileSource(t.path));
      _crossFade(from, to);
    } catch (e) {
      debugPrint('No se pudo reproducir ${t.path}: $e');
      playing = false;
      notifyListeners();
    }
  }

  void _crossFade(AudioPlayer from, AudioPlayer to, {Duration duration = const Duration(milliseconds: 2500)}) {
    _fadeTimer?.cancel();
    const steps = 25;
    var i = 0;
    _fadeTimer = Timer.periodic(duration ~/ steps, (t) {
      i++;
      final k = i / steps;
      to.setVolume(_targetVolume * k);
      from.setVolume(_targetVolume * (1 - k));
      if (i >= steps) {
        t.cancel();
        from.stop();
      }
    });
  }

  Future<void> _next() async {
    if (!playing) return;
    final s = currentSituation;
    if (s != null) {
      final tracks = db.tracks(situationId: s.id);
      if (tracks.length > 1 && currentTrack != null) {
        tracks.removeWhere((t) => t.id == currentTrack!.id);
      }
      if (tracks.isNotEmpty) {
        final t = shuffle ? tracks[_rnd.nextInt(tracks.length)] : tracks.first;
        await playTrack(t);
        return;
      }
    }
    if (currentTrack != null) await playTrack(currentTrack!);
  }

  Future<void> pause() async {
    playing = false;
    _fadeTimer?.cancel();
    await _a.pause();
    await _b.pause();
    notifyListeners();
  }

  Future<void> resume() async {
    if (currentTrack == null) return;
    playing = true;
    await _current.resume();
    await _current.setVolume(_targetVolume);
    notifyListeners();
  }

  Future<void> stop() async {
    playing = false;
    _fadeTimer?.cancel();
    await _a.stop();
    await _b.stop();
    currentTrack = null;
    currentSituation = null;
    notifyListeners();
  }

  Future<void> skip() => _next();

  Future<void> setVolume(double v) async {
    settings.musicVolume = v;
    await _current.setVolume(_targetVolume);
    notifyListeners();
  }

  void duck(bool v) {
    if (!settings.duckMusic || _ducked == v) return;
    _ducked = v;
    if (playing && _fadeTimer?.isActive != true) _current.setVolume(_targetVolume);
  }

  @override
  void dispose() {
    _completeA?.cancel();
    _completeB?.cancel();
    _fadeTimer?.cancel();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }
}
