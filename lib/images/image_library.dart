import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../ai/llm.dart';
import '../core/bundled_models.dart';
import '../core/db.dart';
import '../core/downloader.dart';
import '../core/models.dart';
import '../core/portable.dart';
import '../core/scenes.dart';
import '../core/settings.dart';
import 'image_engine.dart';
import 'image_models.dart';

/// Personaje (PJ o PNJ) que puede tener retrato y cuerpo entero.
class ImageSubject {
  const ImageSubject(this.name, this.description, {this.player = false});
  final String name;

  /// Lo que se sabe de su aspecto y de quién es.
  final String description;

  /// true si es un personaje jugador.
  final bool player;
}

/// Biblioteca de imágenes de apoyo de cada campaña: el retrato y el cuerpo
/// entero de cada PJ y PNJ y las ilustraciones de las escenas.
///
/// Cada imagen la puede poner el usuario a mano o la puede dibujar el motor
/// configurado ([engine]). Las escenas que la historia necesita y aún no
/// tienen imagen se guardan como «faltan» ([planScenes], [noteLocation]) y
/// se generan de una en una en segundo plano ([generateMissing]).
class ImageLibrary extends ChangeNotifier {
  ImageLibrary(this.db, this.llm, this.settings, this.root, {this.engineOverride});

  final AppDatabase db;
  final TextGenerator llm;
  final AppSettings settings;
  final DataRoot root;
  /// Motor fijo (para pruebas).
  final ImageEngine? Function()? engineOverride;

  /// Clave en la biblia: imagen de la galería fijada a mano en la mesa.
  static const pinnedKey = '_imagenFija';
  static const extensions = ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'];
  static const negative = 'text, letters, watermark, signature, frame, blurry, deformed, extra limbs, low quality';

  // ------------------------------------------------------------------ motor

  /// `sd-cli` que viene con la app (carpeta `incluidos/sd` junto al
  /// ejecutable) o el que el usuario haya puesto en la carpeta de datos.
  /// Carpeta de bibliotecas nativas en Android (la rellena [initAndroid]).
  static String? androidNativeDir;

  /// Pregunta a Android dónde quedó libsdcli.so al instalar la app.
  static Future<void> initAndroid() async {
    if (!Platform.isAndroid) return;
    try {
      androidNativeDir = await const MethodChannel('director_de_rol/incluidos').invokeMethod<String>('nativeLibDir');
    } catch (e) {
      debugPrint('Carpeta nativa: $e');
    }
  }

  String get localExe {
    if (settings.sdExe.isNotEmpty) return root.resolve(settings.sdExe);
    if (Platform.isAndroid) {
      final dir = androidNativeDir;
      if (dir == null) return '';
      final f = p.join(dir, 'libsdcli.so');
      return File(f).existsSync() ? f : '';
    }
    final name = Platform.isWindows ? 'sd-cli.exe' : 'sd-cli';
    final bundled = BundledModels.desktopDir();
    for (final dir in [if (bundled != null) p.join(bundled, 'sd'), p.join(root.imageModels, 'sd')]) {
      final f = p.join(dir, name);
      if (File(f).existsSync()) return f;
    }
    return '';
  }

  /// La generación local sólo existe en escritorio.
  bool get localSupported => localExe.isNotEmpty;

  /// Motor que toca según los ajustes; null si no hay ninguno (sólo a mano).
  ImageEngine? get engine {
    if (engineOverride != null) return engineOverride!();
    var id = settings.imageEngine;
    if (id == 'none') return null;
    if (id.isEmpty) id = localSupported ? 'local' : (settings.imageApiUrl.isNotEmpty ? 'openai' : '');
    switch (id) {
      case 'local':
        return SdCppEngine(
          exe: localExe,
          model: root.resolve(settings.sdModel),
          vae: root.resolve(settings.sdVae),
          llm: root.resolve(settings.sdLlm),
          steps: settings.sdSteps,
          cfg: settings.sdCfg,
          lowVram: settings.sdLowVram,
          tmpDir: root.tmp,
        );
      case 'openai':
        return OpenAiImageEngine(baseUrl: settings.imageApiUrl, apiKey: settings.imageApiKey, model: settings.imageApiModel);
      case 'a1111':
        return A1111Engine(baseUrl: settings.imageApiUrl, steps: settings.sdSteps, cfg: settings.sdCfg);
    }
    return null;
  }

  /// null si se puede generar ahora mismo; si no, por qué no.
  String? get engineProblem {
    final e = engine;
    if (e == null) return 'No hay generador de imágenes configurado (Ajustes › Imágenes)';
    return e.problem;
  }

  bool get canGenerate => engineProblem == null;

  // --------------------------------------------------------------- consultas

  ImageRecord? find(int campaignId, String kind, String subject) => db.image(campaignId, kind, subject);

  /// Fichero de la imagen de ese tipo y sujeto, si existe en disco.
  File? fileOf(int campaignId, String kind, String subject) => fileFor(find(campaignId, kind, subject));

  static File? fileFor(ImageRecord? r) {
    if (r == null || r.path.isEmpty) return null;
    final f = File(r.path);
    return f.existsSync() ? f : null;
  }

  List<ImageRecord> scenes(int campaignId) => db.images(campaignId, kind: ImageRecord.sceneKind);

  /// PJ y PNJ de la campaña, con lo que se sabe de cada uno.
  List<ImageSubject> subjects(Campaign c) {
    final id = c.id!;
    final out = <ImageSubject>[];
    final seen = <String>{};
    void add(String name, String description, {bool player = false}) {
      final n = name.trim();
      if (n.isEmpty || !seen.add(AppDatabase.normalize(n))) return;
      out.add(ImageSubject(n, description.trim(), player: player));
    }

    for (final pl in db.campaignPlayers(id)) {
      add(pl.characterName, pl.characterSheet, player: true);
    }
    final npcNames = {for (final n in db.npcs(id)) AppDatabase.normalize(n.name)};
    for (final ch in db.charStates(id)) {
      // Las fichas incluyen a los PJ y a compañeros del grupo.
      if (!npcNames.contains(AppDatabase.normalize(ch.name))) add(ch.name, ch.notes, player: true);
    }
    final bibleNpcs = {
      for (final n in ((c.bible['npcs'] as List?) ?? const []).whereType<Map>()) AppDatabase.normalize('${n['name'] ?? ''}'): n,
    };
    for (final n in db.npcs(id)) {
      final b = bibleNpcs[AppDatabase.normalize(n.name)];
      final traits = b == null
          ? ''
          : [b['gender'], b['age'], b['role'], b['personality']].map((e) => '${e ?? ''}'.trim()).where((e) => e.isNotEmpty).join(', ');
      add(n.name, [traits, n.description].where((e) => e.isNotEmpty).join('. '));
    }
    return out;
  }

  /// Lo que se sabe de un personaje, para dibujarlo.
  String descriptionOf(Campaign c, String name) {
    final n = AppDatabase.normalize(name);
    for (final s in subjects(c)) {
      if (AppDatabase.normalize(s.name) == n) return s.description;
    }
    return '';
  }

  /// Imagen de la escena en la que está el grupo: la del lugar actual, o la
  /// de un lugar que lo contiene («Taberna del Cuervo» ⊂ «…, el sótano»).
  ImageRecord? sceneFor(Campaign c) {
    final loc = AppDatabase.normalize(c.location);
    if (loc.isEmpty || c.id == null) return null;
    ImageRecord? best;
    var bestLen = 0;
    for (final r in scenes(c.id!)) {
      if (fileFor(r) == null) continue;
      final n = AppDatabase.normalize(r.subject);
      if (n == loc) return r;
      if (n.length >= 5 && (loc.contains(n) || n.contains(loc)) && n.length > bestLen) {
        best = r;
        bestLen = n.length;
      }
    }
    return best;
  }

  /// Imagen que el usuario ha fijado en la mesa desde la galería.
  ImageRecord? pinned(Campaign c) {
    final id = c.bible[pinnedKey];
    if (id is! num || c.id == null) return null;
    for (final r in db.images(c.id!)) {
      if (r.id == id.toInt()) return fileFor(r) == null ? null : r;
    }
    return null;
  }

  void pin(Campaign c, ImageRecord? r) {
    if (r == null) {
      c.bible.remove(pinnedKey);
    } else {
      c.bible[pinnedKey] = r.id;
    }
    db.updateCampaign(c);
    notifyListeners();
  }

  // --------------------------------------------------------------- a mano

  /// Guarda [sourcePath] como la imagen de ese tipo y sujeto (la copia a la
  /// carpeta de datos, así viaja con la app y con el `.rolpack`).
  Future<ImageRecord> setFromFile(int campaignId, String kind, String subject, String sourcePath, {String origin = 'manual'}) async {
    final ext = p.extension(sourcePath).toLowerCase();
    if (!extensions.contains(ext)) throw ImageEngineException('Formato de imagen no admitido ($ext)');
    final dest = _newPath(campaignId, kind, subject, ext);
    await File(sourcePath).copy(dest);
    return _store(campaignId, kind, subject, dest, origin);
  }

  Future<ImageRecord> setFromBytes(int campaignId, String kind, String subject, Uint8List bytes, {String origin = 'generada', String? prompt}) async {
    final ext = imageExtension(bytes);
    if (ext == null) throw ImageEngineException('El generador no ha devuelto una imagen válida');
    final dest = _newPath(campaignId, kind, subject, ext);
    await File(dest).writeAsBytes(bytes, flush: true);
    return _store(campaignId, kind, subject, dest, origin, prompt: prompt);
  }

  String _newPath(int campaignId, String kind, String subject, String ext) {
    final dir = Directory(root.campaignImages(campaignId))..createSync(recursive: true);
    var safe = AppDatabase.normalize(subject).replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (safe.length > 40) safe = safe.substring(0, 40);
    return p.join(dir.path, '${kind}_${safe.isEmpty ? 'imagen' : safe}_${DateTime.now().millisecondsSinceEpoch}$ext');
  }

  ImageRecord _store(int campaignId, String kind, String subject, String dest, String origin, {String? prompt}) {
    final rec = find(campaignId, kind, subject) ?? ImageRecord(campaignId: campaignId, kind: kind, subject: subject);
    final oldPath = rec.path;
    rec
      ..path = dest
      ..origin = origin;
    if (prompt != null) rec.prompt = prompt;
    db.saveImage(rec);
    if (oldPath.isNotEmpty && oldPath != dest) _deleteFile(oldPath);
    notifyListeners();
    return rec;
  }

  void _deleteFile(String path) {
    if (path.isEmpty || !p.isWithin(root.images, path)) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  /// Quita la imagen. Una escena se queda en la galería como «falta» salvo
  /// que se pida borrarla del todo con [forget].
  void remove(ImageRecord r, {bool forget = false}) {
    _deleteFile(r.path);
    if (forget || !r.isScene) {
      if (r.id != null) db.deleteImage(r.id!);
    } else {
      db.saveImage(r
        ..path = ''
        ..origin = '');
    }
    notifyListeners();
  }

  void updateDescription(ImageRecord r, String description) {
    r
      ..description = description.trim()
      ..prompt = ''; // el texto para el generador se vuelve a escribir
    db.saveImage(r);
    notifyListeners();
  }

  /// Borra de disco las imágenes de una campaña (al borrar la campaña).
  void deleteCampaignFiles(int campaignId) {
    try {
      final d = Directory(root.campaignImages(campaignId));
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ----------------------------------------------------------------- escenas

  /// Apunta una escena en la galería si no estaba (sin imagen = «falta»).
  /// Devuelve el registro (nuevo o el que ya había).
  ImageRecord ensureScene(int campaignId, String title, {String description = '', String scene = ''}) {
    final existing = find(campaignId, ImageRecord.sceneKind, title);
    if (existing != null) {
      var changed = false;
      if (existing.description.isEmpty && description.trim().isNotEmpty) {
        existing.description = description.trim();
        changed = true;
      }
      if (existing.scene.isEmpty && scene.isNotEmpty) {
        existing.scene = scene;
        changed = true;
      }
      if (changed) db.saveImage(existing);
      return existing;
    }
    return db.saveImage(ImageRecord(
      campaignId: campaignId,
      kind: ImageRecord.sceneKind,
      subject: title.trim(),
      description: description.trim(),
      scene: scene.isNotEmpty ? scene : (Scenes.detect(title)?.id ?? ''),
    ));
  }

  /// Repasa la historia y apunta las escenas que deberían tener imagen y no
  /// están en la galería: los lugares de la biblia y del grafo, el lugar
  /// actual y, si hay modelo de lenguaje, los momentos clave de cada acto
  /// que la IA considere que merecen ilustración. Devuelve cuántas añade.
  Future<int> planScenes(Campaign c, {bool useAi = true}) async {
    final id = c.id!;
    final before = {for (final r in scenes(id)) AppDatabase.normalize(r.subject)};
    var added = 0;
    void want(String title, String description) {
      final t = title.trim();
      if (t.isEmpty) return;
      final isNew = before.add(AppDatabase.normalize(t));
      ensureScene(id, t, description: description);
      if (isNew) added++;
    }

    for (final l in ((c.bible['locations'] as List?) ?? const []).whereType<Map>()) {
      want('${l['name'] ?? ''}', '${l['description'] ?? ''}');
    }
    for (final e in db.entities(id)) {
      if (e.type == 'lugar') want(e.name, e.description);
    }
    if (c.location.isNotEmpty) want(c.location, '');

    if (useAi && llm.isReady) {
      try {
        final acts = [
          for (var i = 0; i < c.acts.length; i++)
            'Acto ${i + 1} «${c.acts[i]['title']}»: ${c.acts[i]['summary']} Objetivo: ${c.acts[i]['goal']}. Giro: ${c.acts[i]['twist']}',
        ].join('\n');
        final r = await llm.json(
          [
            const LlmMessage.system(
              'Eres el director de arte de una partida de rol. Decides qué escenas de la historia merecen una '
              'ilustración de apoyo para enseñar a los jugadores. Respondes en español.',
            ),
            LlmMessage.user(
              'Campaña: ${c.title} (${c.theme}, ${c.tone}).\nPremisa: ${c.premise}\n'
              '${(c.bible['hook'] ?? '').toString().isEmpty ? '' : 'Gancho: ${c.bible['hook']}\n'}'
              '${acts.isEmpty ? '' : '$acts\n'}'
              '${c.memory.isEmpty ? '' : 'Lo que ha pasado hasta ahora: ${_clip(c.memory, 900)}\n'}'
              '\nEscenas que ya están en la galería: ${before.isEmpty ? 'ninguna' : scenes(id).map((e) => e.subject).join('; ')}.\n\n'
              'Propón hasta 6 escenas NUEVAS que falten (momentos clave, lugares importantes aún sin imagen, '
              'el enfrentamiento final…). Para cada una: un título corto y una descripción visual de 1-2 frases '
              '(qué lugar es, qué se ve, quién aparece y con qué aspecto, la luz y el ambiente). No repitas las que ya están.',
            ),
          ],
          schema: {
            'type': 'object',
            'properties': {
              'scenes': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'title': {'type': 'string'},
                    'description': {'type': 'string'},
                  },
                  'required': ['title', 'description'],
                },
              },
            },
            'required': ['scenes'],
          },
          maxTokens: 900,
          temperature: 0.7,
        );
        for (final s in ((r['scenes'] as List?) ?? const []).whereType<Map>().take(6)) {
          want('${s['title'] ?? ''}', '${s['description'] ?? ''}');
        }
      } catch (e) {
        debugPrint('Escenas propuestas por la IA: $e');
      }
    }
    if (added > 0) notifyListeners();
    return added;
  }

  /// El grupo ha llegado a [Campaign.location]: apunta la escena (con lo que
  /// el director acaba de narrar como descripción) y, si está activado y hay
  /// generador, la dibuja en segundo plano.
  ImageRecord? noteLocation(Campaign c, {String narration = ''}) {
    if (c.id == null || c.location.trim().isEmpty) return null;
    if (sceneFor(c) != null) return null; // ya hay imagen para este sitio
    final known = find(c.id!, ImageRecord.sceneKind, c.location) != null;
    final rec = ensureScene(
      c.id!,
      c.location,
      description: _clip(_plain(narration), 320),
      scene: (c.bible[Scenes.bibleKey] ?? '').toString(),
    );
    if (!known) notifyListeners();
    if (rec.missing && settings.imageAuto && canGenerate && !busy) {
      unawaited(_run(c, [rec]));
    }
    return rec;
  }

  // --------------------------------------------------------------- generar

  bool busy = false;
  int done = 0;
  int total = 0;

  /// Qué se está dibujando ahora («Retrato de Bran»).
  String current = '';
  String? lastError;
  bool _stop = false;
  ImageEngine? _running;

  /// Tamaño de cada tipo. En el móvil (o con modelos de 512 px como
  /// SD-Turbo) se usan tamaños más pequeños: tardan menos y salen mejor.
  static (int, int) sizeFor(String kind, {bool large = false, bool small = false}) {
    if (small) {
      return switch (kind) {
        ImageRecord.portrait => (512, 512),
        ImageRecord.fullBody => (384, 640),
        _ => (640, 384),
      };
    }
    return switch (kind) {
      ImageRecord.portrait => large ? (768, 768) : (512, 512),
      ImageRecord.fullBody => large ? (704, 1024) : (512, 768),
      _ => large ? (1024, 704) : (768, 512),
    };
  }

  /// El modelo local elegido es de los de 512 px (SD 1.x/2.x, SD-Turbo).
  bool get _smallModel {
    final m = p.basename(settings.sdModel).toLowerCase();
    return settings.sdLlm.isEmpty && (m.contains('turbo') && !m.contains('xl') || m.contains('sd_1') || m.contains('v1-5') || m.contains('sd-v1'));
  }

  /// Semilla fija por personaje o escena: el retrato y el cuerpo entero de
  /// alguien salen de la misma, para que se parezcan.
  static int seedFor(int campaignId, String subject) {
    var h = 0x811C9DC5 ^ campaignId;
    for (final u in AppDatabase.normalize(subject).codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Texto que se envía al generador para [r].
  Future<String> buildPrompt(Campaign c, ImageRecord r, ImageEngine e) async {
    final english = e.prefersEnglish;
    var visual = r.prompt;
    if (visual.isEmpty) {
      final source = r.description.isEmpty ? r.subject : '${r.subject}: ${r.description}';
      visual = english ? (await _toEnglish(c, r, source) ?? source) : source;
      if (english && visual != source) {
        r.prompt = visual;
        db.saveImage(r);
      }
    }
    final style = settings.imageStyle.trim();
    final world = [c.theme, c.tone].where((s) => s.trim().isNotEmpty).join(', ');
    if (english) {
      final frame = switch (r.kind) {
        ImageRecord.portrait => 'portrait, head and shoulders close-up, face in focus, looking at viewer, plain dark background',
        ImageRecord.fullBody => 'full body character concept art, single character standing, head to toe, plain neutral background',
        _ => 'wide establishing shot, detailed environment, atmospheric, no text',
      };
      return [frame, visual, world, style].where((s) => s.isNotEmpty).join(', ');
    }
    final frame = switch (r.kind) {
      ImageRecord.portrait => 'Retrato de $visual. Primer plano de cabeza y hombros, mirando al espectador, fondo liso oscuro.',
      ImageRecord.fullBody => 'Personaje de cuerpo entero, de pie, de la cabeza a los pies, un solo personaje sobre fondo liso neutro: $visual.',
      _ => 'Escena: $visual. Plano general del lugar, con ambiente, sin texto ni rótulos.',
    };
    return [frame, if (world.isNotEmpty) 'Ambientación: $world.', if (style.isNotEmpty) 'Estilo: $style.'].join(' ');
  }

  Future<String?> _toEnglish(Campaign c, ImageRecord r, String source) async {
    if (!llm.isReady) return null;
    try {
      final j = await llm.json(
        [
          const LlmMessage.system(
            'You write prompts for an image generator. Given the Spanish description of a character or a place '
            'from a tabletop RPG, answer with a vivid English visual description: appearance, clothing, setting, '
            'mood and lighting, as comma-separated phrases, 50 words at most. No proper names, no story, no text in the image.',
          ),
          LlmMessage.user('${r.isScene ? 'Place or scene' : 'Character'} from a ${c.theme} campaign (${c.tone}).\n$source'),
        ],
        schema: {
          'type': 'object',
          'properties': {
            'prompt': {'type': 'string'},
          },
          'required': ['prompt'],
        },
        maxTokens: 200,
        temperature: 0.5,
      );
      final t = '${j['prompt'] ?? ''}'.trim();
      return t.isEmpty ? null : t;
    } catch (e) {
      debugPrint('Texto para la imagen: $e');
      return null;
    }
  }

  /// Dibuja (o vuelve a dibujar) una imagen. [fresh] cambia la semilla para
  /// que salga distinta de la anterior.
  Future<ImageRecord> generate(Campaign c, ImageRecord r, {bool fresh = false}) async {
    final e = engine;
    final why = e == null ? engineProblem : e.problem;
    if (e == null || why != null) throw ImageEngineException(why ?? 'Sin generador');
    final (w, h) = sizeFor(r.kind, large: settings.imageLarge, small: e.id == 'local' && (Platform.isAndroid || _smallModel));
    if (!r.isScene && r.description.isEmpty) r.description = descriptionOf(c, r.subject);
    if (r.id == null) db.saveImage(r);
    final prompt = await buildPrompt(c, r, e);
    _running = e;
    try {
      final bytes = await e.generate(ImageRequest(
        prompt: prompt,
        negative: negative,
        width: w,
        height: h,
        seed: fresh ? Random().nextInt(0x7fffffff) : seedFor(c.id!, r.subject),
      ));
      return await setFromBytes(c.id!, r.kind, r.subject, bytes);
    } finally {
      _running = null;
    }
  }

  /// Lo que falta en la campaña: retrato y cuerpo entero de cada PJ y PNJ y
  /// las escenas apuntadas sin imagen. [kinds] limita los tipos.
  List<ImageRecord> missing(Campaign c, {Set<String>? kinds}) {
    final id = c.id!;
    final out = <ImageRecord>[];
    bool wanted(String k) => kinds == null || kinds.contains(k);
    for (final s in subjects(c)) {
      for (final kind in [ImageRecord.portrait, ImageRecord.fullBody]) {
        if (!wanted(kind)) continue;
        final r = find(id, kind, s.name);
        if (fileFor(r) != null) continue;
        out.add(r ?? ImageRecord(campaignId: id, kind: kind, subject: s.name, description: s.description));
      }
    }
    if (wanted(ImageRecord.sceneKind)) {
      out.addAll(scenes(id).where((r) => fileFor(r) == null));
    }
    return out;
  }

  /// Genera todo lo que falta, de uno en uno. Devuelve cuántas ha hecho.
  Future<int> generateMissing(Campaign c, {Set<String>? kinds}) => _run(c, missing(c, kinds: kinds));

  /// Genera una sola imagen dentro de la cola (con progreso y errores).
  Future<int> generateOne(Campaign c, ImageRecord r, {bool fresh = false}) => _run(c, [r], fresh: fresh);

  Future<int> _run(Campaign c, List<ImageRecord> queue, {bool fresh = false}) async {
    if (busy || queue.isEmpty) return 0;
    final why = engineProblem;
    if (why != null) {
      lastError = why;
      notifyListeners();
      return 0;
    }
    busy = true;
    _stop = false;
    done = 0;
    total = queue.length;
    lastError = null;
    var ok = 0;
    var failures = 0;
    try {
      for (final r in queue) {
        if (_stop) break;
        current = '${ImageRecord.kindNames[r.kind]} de ${r.subject}';
        notifyListeners();
        try {
          await generate(c, r, fresh: fresh);
          ok++;
          failures = 0;
        } catch (e) {
          if (_stop) break;
          lastError = '$current: $e';
          // Dos fallos seguidos suelen ser de configuración: no se insiste.
          if (++failures >= 2) break;
        }
        done++;
      }
    } finally {
      busy = false;
      current = '';
      notifyListeners();
    }
    return ok;
  }

  void cancel() {
    _stop = true;
    _running?.cancel();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  // ------------------------------------------------- modelos del motor local

  /// Progreso de la descarga de un modelo (0..1); null si no hay descarga.
  double? downloadProgress;
  String downloadLabel = '';

  bool presetInstalled(ImageModelPreset preset) =>
      preset.files.every((f) => File(p.join(root.imageModels, f.name)).existsSync());

  /// Descarga las piezas que falten de [preset] y lo deja seleccionado.
  Future<void> installPreset(ImageModelPreset preset) async {
    if (downloadProgress != null) return;
    final totalBytes = preset.files.fold<int>(0, (a, f) => a + f.bytes);
    var before = 0;
    try {
      for (final f in preset.files) {
        final dest = File(p.join(root.imageModels, f.name));
        if (!dest.existsSync()) {
          downloadLabel = f.name;
          downloadProgress = before / totalBytes;
          notifyListeners();
          final part = File('${dest.path}.part');
          var last = 0.0;
          await ResumableDownloader().download(Uri.parse(f.url), part, onProgress: (frac) {
            final v = (before + (frac ?? 0) * f.bytes) / totalBytes;
            if (v - last < 0.002) return;
            last = v;
            downloadProgress = v;
            notifyListeners();
          });
          part.renameSync(dest.path);
        }
        before += f.bytes;
      }
      usePreset(preset);
    } finally {
      downloadProgress = null;
      downloadLabel = '';
      notifyListeners();
    }
  }

  void usePreset(ImageModelPreset preset) {
    String stored(String role) {
      final f = preset.files.where((f) => f.role == role).firstOrNull;
      return f == null ? '' : root.toStored(p.join(root.imageModels, f.name));
    }

    settings
      ..sdModel = stored('model')
      ..sdVae = stored('vae')
      ..sdLlm = stored('llm')
      ..sdSteps = preset.steps
      ..sdCfg = preset.cfg;
    notifyListeners();
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

  /// Quita las marcas del texto del director (negritas, diálogos «@Nombre:»).
  static String _plain(String s) => s
      .replaceAll(RegExp(r'\[\[.*?\]\]'), '')
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('@') && !l.trimLeft().startsWith('**'))
      .join(' ')
      .replaceAll('*', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
