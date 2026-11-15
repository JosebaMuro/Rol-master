import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';
import 'portable.dart';
import 'scenes.dart';
import 'settings.dart';

/// Qué se mete en un paquete de campaña al exportar.
class PackageOptions {
  const PackageOptions({
    this.progress = true,
    this.music = true,
    this.backgrounds = true,
    this.voiceModels = false,
    this.globalDocs = true,
    this.images = true,
  });

  /// Sesiones jugadas, registros, fichas, memoria del director... Sin esto
  /// se exporta sólo la historia, lista para que otro grupo la empiece.
  final bool progress;

  /// Biblioteca de música por situaciones (los ficheros de audio).
  final bool music;

  /// Imágenes de fondo de cada tipo de escena.
  final bool backgrounds;

  /// Los modelos de voz neuronal que usan el narrador y los PNJ (pesan
  /// 60-350 MB cada uno). Sin ellos sólo va la referencia y el otro equipo
  /// los descarga desde Ajustes.
  final bool voiceModels;

  /// La documentación general (no ligada a ninguna campaña) que el director
  /// también consulta en esta campaña.
  final bool globalDocs;

  /// Retratos, cuerpos enteros y escenas de la campaña.
  final bool images;
}

/// Qué se aplica al importar un paquete.
class ImportOptions {
  const ImportOptions({
    this.music = true,
    this.backgrounds = true,
    this.replaceBackgrounds = false,
    this.voiceModels = true,
    this.narrator = true,
    this.globalDocs = true,
    this.images = true,
  });

  final bool images;
  final bool music;
  final bool backgrounds;

  /// Si es false, sólo se rellenan los tipos de escena que no tienen fondo.
  final bool replaceBackgrounds;
  final bool voiceModels;

  /// Usar la voz de narrador que traía la campaña (es un ajuste general).
  final bool narrator;
  final bool globalDocs;
}

/// Resultado de una importación, para contárselo al usuario.
class ImportReport {
  ImportReport(this.campaign);
  final Campaign campaign;
  int tracks = 0;
  int tracksSkipped = 0;
  int backgrounds = 0;
  int images = 0;
  int documents = 0;
  bool narratorApplied = false;
  final installedVoices = <String>[];

  /// Voces neuronales que usa la campaña y no están en este equipo.
  final missingVoices = <String>[];
  String chatModel = '';

  /// Los vectores venían de otro modelo de embeddings: se han quitado y hay
  /// que recalcularlos (la búsqueda léxica sigue funcionando mientras tanto).
  bool needsReembed = false;
  final warnings = <String>[];
}

/// Resumen de lo que trae un paquete, para enseñarlo antes de importar.
class PackageSummary {
  PackageSummary(this.json);
  final Map<String, dynamic> json;

  Map<String, dynamic> get _c => ((json['campaign'] as Map?) ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> get _music => ((json['music'] as Map?) ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> get _voices => ((json['voices'] as Map?) ?? const {}).cast<String, dynamic>();

  String get title => (_c['title'] ?? 'Sin título').toString();
  String get theme => (_c['theme'] ?? '').toString();
  int get version => (json['version'] as num?)?.toInt() ?? 1;
  bool get includesProgress => json['includesProgress'] != false;
  int get sessions => (json['sessions'] as List?)?.length ?? 0;
  int get players => (json['players'] as List?)?.length ?? 0;
  int get npcs => (json['npcs'] as List?)?.length ?? 0;
  int get maps => (json['maps'] as List?)?.length ?? 0;
  int get loreChunks => (json['chunks'] as List?)?.length ?? 0;
  int get documents => (json['documents'] as List?)?.length ?? 0;
  int get tracks => (_music['tracks'] as List?)?.length ?? 0;
  int get backgrounds => ((json['backgrounds'] as Map?) ?? const {}).length;
  int get images => (json['images'] as List?)?.where((e) => e is Map && e['file'] != null).length ?? 0;
  bool get hasNarrator => _voices['narrator'] is Map;
  List<Map<String, dynamic>> get voicePacks => StoryPackage._maps(_voices['packs']).toList();
  int get includedVoicePacks => voicePacks.where((v) => v['included'] == true).length;
  String get chatModel => (((json['requirements'] as Map?) ?? const {})['chatModel'] ?? '').toString();
}

/// Exporta e importa campañas completas en un único fichero `.rolpack`:
/// un ZIP con `historia.json` (manifiesto con formato y versión) y los
/// ficheros que lo acompañan:
///
/// ```
/// historia.json        estado completo: biblia, jugadores y fichas, PNJ con
///                      voz y actitud, grafo, memoria RAG con vectores,
///                      documentación, sesiones y mensajes, relojes...
/// mapas/…              imágenes de los mapas
/// fondos/<escena>.*    fondos por tipo de escena
/// imagenes/…           retratos, cuerpos enteros y escenas de la historia
/// musica/…             pistas de la biblioteca por situación
/// documentos/…         documentos originales de la documentación
/// voces/<paquete>/…    (opcional) modelos de voz neuronal
/// ```
///
/// El modelo de lenguaje no viaja nunca (pesa gigas y cada equipo usa el que
/// le cabe); sólo se anota su nombre. Los modelos de voz van por referencia
/// salvo que se pida incluirlos.
///
/// Los paquetes de la versión 1 (sólo historia y mapas) se siguen importando.
class StoryPackage {
  static const format = 'director-de-rol/historia';
  static const version = 3;
  static const extension = 'rolpack';
  static const _memoryPointerKey = '_memoryUpTo';
  static const _manifest = 'historia.json';

  // ======================================================================
  // Exportar
  // ======================================================================

  /// Exporta a memoria. Cómodo para paquetes pequeños y pruebas; para
  /// campañas con música o voces usa [exportToFile].
  static Uint8List export(
    AppDatabase db,
    int campaignId, {
    bool includeProgress = true,
    PackageOptions? options,
    DataRoot? root,
    AppSettings? settings,
  }) {
    final (json, files) = _collect(db, campaignId, options ?? PackageOptions(progress: includeProgress), root, settings);
    final archive = Archive();
    for (final f in files) {
      archive.addFile(ArchiveFile.bytes(f.name, File(f.path).readAsBytesSync()));
    }
    archive.addFile(ArchiveFile.string(_manifest, const JsonEncoder.withIndent(' ').convert(json)));
    return ZipEncoder().encodeBytes(archive);
  }

  /// Exporta a un fichero en disco sin cargar la música ni las voces en
  /// memoria (el ZIP se escribe en segundo plano). Devuelve su tamaño.
  static Future<int> exportToFile(
    AppDatabase db,
    int campaignId,
    String outPath, {
    PackageOptions options = const PackageOptions(),
    DataRoot? root,
    AppSettings? settings,
  }) async {
    final (json, files) = _collect(db, campaignId, options, root, settings);
    final manifest = const JsonEncoder.withIndent(' ').convert(json);
    final entries = [for (final f in files) (f.name, f.path, f.store)];
    final tmp = '$outPath.parcial';
    await Isolate.run(() => _writeZip(tmp, manifest, entries));
    final out = File(outPath);
    if (out.existsSync()) out.deleteSync();
    File(tmp).renameSync(outPath);
    return out.lengthSync();
  }

  static Future<void> _writeZip(String path, String manifest, List<(String, String, bool)> entries) async {
    final enc = ZipFileEncoder()..create(path);
    // El manifiesto primero: así se puede leer la cabecera rápido.
    enc.addArchiveFile(ArchiveFile.string(_manifest, manifest));
    for (final (name, file, store) in entries) {
      await enc.addFile(File(file), name, store ? ZipFileEncoder.store : null);
    }
    await enc.close();
  }

  /// Lo que pesarán los ficheros que acompañan al manifiesto, por apartado.
  static Map<String, int> estimateSizes(
    AppDatabase db,
    int campaignId, {
    PackageOptions options = const PackageOptions(voiceModels: true),
    DataRoot? root,
    AppSettings? settings,
  }) {
    final (_, files) = _collect(db, campaignId, options, root, settings);
    final out = <String, int>{};
    for (final f in files) {
      final section = f.name.split('/').first;
      out[section] = (out[section] ?? 0) + File(f.path).lengthSync();
    }
    return out;
  }

  static (Map<String, dynamic>, List<_Attachment>) _collect(
    AppDatabase db,
    int campaignId,
    PackageOptions o,
    DataRoot? root,
    AppSettings? settings,
  ) {
    final includeProgress = o.progress;
    final c = db.campaign(campaignId)!;
    final files = <_Attachment>[];
    final usedNames = <String>{};
    String attach(String folder, String path, {bool store = true}) {
      var name = '$folder/${p.basename(path)}';
      for (var i = 2; !usedNames.add(name); i++) {
        name = '$folder/${p.basenameWithoutExtension(path)}_$i${p.extension(path)}';
      }
      files.add(_Attachment(name, path, store));
      return name;
    }

    String resolve(String stored) => root?.resolve(stored) ?? stored;
    bool exists(String path) => path.isNotEmpty && !path.contains('://') && File(path).existsSync();

    final bible = Map<String, dynamic>.from(c.bible);
    if (!includeProgress) {
      for (final k in [_memoryPointerKey, '_turnos', '_eventosMundo', '_escena', '_imagenFija']) {
        bible.remove(k);
      }
    }

    final maps = <Map<String, dynamic>>[];
    for (final m in db.maps(campaignId: campaignId)) {
      final f = resolve(m.imagePath);
      maps.add({
        'title': m.title,
        'kind': m.kind,
        'seed': m.seed,
        'key': m.roomKey,
        'createdAt': m.createdAt.toIso8601String(),
        'image': exists(f) ? attach('mapas', f) : null,
      });
    }

    // ---- Documentación (RAG): la de la campaña y, si se pide, la general.
    final docs = <Map<String, dynamic>>[];
    for (final d in db.documents()) {
      final own = d.campaignId == campaignId;
      if (!own && !(o.globalDocs && d.campaignId == null)) continue;
      final original = resolve(d.path);
      docs.add({
        'title': d.title,
        'kind': d.kind,
        'chars': d.chars,
        'global': !own,
        'addedAt': d.addedAt.toIso8601String(),
        if (exists(original)) 'file': attach('documentos', original, store: false),
        'chunks': [
          for (final r in db.db.select('SELECT text, embedding FROM doc_chunks WHERE doc_id = ? ORDER BY id', [d.id]))
            {
              'text': r['text'],
              if (r['embedding'] != null) 'embedding': base64Encode(r['embedding'] as Uint8List),
            },
        ],
      });
    }

    // ---- Imágenes de apoyo: retratos, cuerpos enteros y escenas. Las
    // escenas que faltan viajan también (sin fichero) para generarlas allí.
    final images = <Map<String, dynamic>>[];
    if (o.images) {
      for (final i in db.images(campaignId)) {
        final f = resolve(i.path);
        if (!exists(f) && !i.isScene) continue;
        images.add({
          'id': i.id,
          'kind': i.kind,
          'subject': i.subject,
          'description': i.description,
          'prompt': i.prompt,
          'origin': i.origin,
          'scene': i.scene,
          'file': exists(f) ? attach('imagenes', f) : null,
        });
      }
    }

    // ---- Música: situaciones y pistas.
    Map<String, dynamic>? music;
    if (o.music) {
      final situations = db.situations();
      final byId = {for (final s in situations) s.id: s.name};
      final tracks = <Map<String, dynamic>>[];
      for (final t in db.tracks()) {
        final f = resolve(t.path);
        if (!exists(f)) continue;
        tracks.add({
          'title': t.title,
          'situation': byId[t.situationId],
          'volume': t.volume,
          'bytes': File(f).lengthSync(),
          'file': attach('musica', f),
        });
      }
      music = {
        'situations': [
          for (final s in situations) {'name': s.name, 'icon': s.icon, 'order': s.sortOrder},
        ],
        'tracks': tracks,
      };
    }

    // ---- Fondos por tipo de escena.
    final backgrounds = <String, String>{};
    if (o.backgrounds && settings != null) {
      for (final k in Scenes.kinds) {
        final f = resolve(settings.sceneBackground(k.id));
        if (!exists(f)) continue;
        final name = 'fondos/${k.id}${p.extension(f).toLowerCase()}';
        if (usedNames.add(name)) files.add(_Attachment(name, f, true));
        backgrounds[k.id] = name;
      }
    }

    // ---- Voces: narrador y paquetes neuronales que se usan.
    final npcs = db.npcs(campaignId);
    final narrator = settings?.narratorVoice;
    final packIds = <String>{
      for (final n in npcs)
        if (n.voice.engine == 'neural' && n.voice.neuralPack.isNotEmpty) n.voice.neuralPack,
      if (narrator != null && narrator.engine == 'neural' && narrator.neuralPack.isNotEmpty) narrator.neuralPack,
      if (settings != null && settings.defaultNeuralPack.isNotEmpty) settings.defaultNeuralPack,
    };
    final packs = <Map<String, dynamic>>[];
    for (final id in packIds) {
      final dir = root == null ? null : Directory(p.join(root.voices, id));
      final installed = dir != null && File(p.join(dir.path, 'pack.json')).existsSync();
      var kind = '';
      if (installed) {
        try {
          kind = ((jsonDecode(File(p.join(dir.path, 'pack.json')).readAsStringSync()) as Map)['kind'] ?? '').toString();
        } catch (_) {}
      }
      final include = installed && o.voiceModels;
      if (include) {
        for (final f in dir.listSync(recursive: true).whereType<File>()) {
          final rel = p.relative(f.path, from: dir.path).replaceAll(r'\', '/');
          final name = 'voces/$id/$rel';
          if (usedNames.add(name)) files.add(_Attachment(name, f.path, false));
        }
      }
      packs.add({'id': id, 'kind': kind, 'included': include});
    }

    final json = <String, dynamic>{
      'format': format,
      'version': version,
      'exportedAt': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'includesProgress': includeProgress,
      'requirements': {
        'chatModel': settings == null ? '' : p.basename(settings.chatModel),
        'embedModel': settings == null ? '' : p.basename(settings.embedModel),
      },
      'campaign': {
        'title': c.title,
        'theme': c.theme,
        'setting': c.setting,
        'tone': c.tone,
        'premise': c.premise,
        'bible': bible,
        'memory': includeProgress ? c.memory : '',
        'currentAct': includeProgress ? c.currentAct : 0,
        'location': includeProgress ? c.location : '',
        'createdAt': c.createdAt.toIso8601String(),
      },
      'players': [
        for (final pl in db.campaignPlayers(campaignId))
          {'name': pl.playerName, 'characterName': pl.characterName, 'characterSheet': pl.characterSheet},
      ],
      'npcs': [
        for (final n in npcs)
          {
            'name': n.name,
            'description': n.description,
            'voiceHint': n.voiceHint,
            'voice': n.voice.toJson(),
            'goal': n.goal,
            if (includeProgress) 'attitude': n.attitude,
            if (includeProgress) 'knows': n.knows,
          },
      ],
      'entities': [
        for (final e in db.entities(campaignId)) {'name': e.name, 'type': e.type, 'description': e.description},
      ],
      'relations': [
        for (final r in db.relations(campaignId, ended: includeProgress ? null : false))
          {
            'source': r.sourceName,
            'relation': r.relation,
            'target': r.targetName,
            if (includeProgress) 'ended': r.ended,
            if (includeProgress) 'since': r.sinceSession,
            if (includeProgress) 'until': r.untilSession,
          },
      ],
      'characters': includeProgress
          ? [for (final ch in db.charStates(campaignId)) {'name': ch.name, ...ch.toJson()}]
          : [],
      'pins': includeProgress ? [for (final pin in db.pins(campaignId)) pin.text] : [],
      'threads': includeProgress
          ? [
              for (final t in db.plotThreads(campaignId))
                {'kind': t.kind, 'text': t.text, 'open': t.open, 'session': t.session},
            ]
          : [],
      'clocks': [
        for (final k in db.clocks(campaignId))
          {
            'name': k.name,
            'owner': k.owner,
            'segments': k.segments,
            'filled': includeProgress ? k.filled : 0,
            'consequence': k.consequence,
            'active': includeProgress ? k.active : true,
            'stance': includeProgress ? k.stance : 'desconocen',
          },
      ],
      'chunks': [
        for (final ch in db.chunks(campaignId))
          if (includeProgress || !ch.source.startsWith('sesión') && !ch.source.startsWith('resumen'))
            {
              'source': ch.source,
              'text': ch.text,
              if (ch.embedding != null) 'embedding': base64Encode(AppDatabase.encodeVector(ch.embedding!)),
            },
      ],
      'sessions': includeProgress
          ? [
              for (final s in db.sessions(campaignId))
                {
                  'number': s.number,
                  'startedAt': s.startedAt.toIso8601String(),
                  'endedAt': s.endedAt?.toIso8601String(),
                  'summary': s.summary,
                  'messages': [
                    for (final m in db.messagesForSession(s.id!))
                      {
                        'id': m.id,
                        'role': m.role.name,
                        'speaker': m.speaker,
                        'content': m.content,
                        'thinking': m.thinking,
                        'ts': m.ts.toIso8601String(),
                      },
                  ],
                },
            ]
          : [],
      'maps': maps,
      'documents': docs,
      'music': ?music,
      'backgrounds': backgrounds,
      'images': images,
      'voices': {
        if (narrator != null) 'narrator': narrator.toJson(),
        if (settings != null) 'defaultEngine': settings.defaultVoiceEngine,
        if (settings != null) 'defaultNeuralPack': settings.defaultNeuralPack,
        'packs': packs,
      },
    };
    return (json, files);
  }

  // ======================================================================
  // Leer
  // ======================================================================

  /// Lee la cabecera de un paquete sin importarlo (para mostrar qué contiene).
  static Map<String, dynamic> peek(Uint8List bytes) => _parse(ZipDecoder().decodeBytes(bytes));

  /// Igual que [peek] pero desde un fichero, sin cargarlo entero.
  static PackageSummary peekFile(String path) {
    final input = InputFileStream(path);
    try {
      return PackageSummary(_parse(ZipDecoder().decodeStream(input)));
    } finally {
      input.closeSync();
    }
  }

  static Map<String, dynamic> _parse(Archive archive) {
    final f = archive.findFile(_manifest);
    if (f == null) throw const FormatException('El fichero no es una campaña de Director de Rol');
    final json = (jsonDecode(utf8.decode(f.content)) as Map).cast<String, dynamic>();
    if (json['format'] != format) throw const FormatException('Formato de campaña desconocido');
    if ((json['version'] as num? ?? 0) > version) {
      throw const FormatException('La campaña es de una versión más nueva de la app: actualízala');
    }
    return json;
  }

  // ======================================================================
  // Importar
  // ======================================================================

  /// Importa la historia desde memoria como una campaña nueva (sin música,
  /// fondos ni voces: para eso, [importFile]).
  static Campaign import(AppDatabase db, Uint8List bytes, {required String mapsDir, AppSettings? settings}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final json = _parse(archive);
    return _importCore(db, json, archive, mapsDir: mapsDir, docsDir: null, settings: settings, options: const ImportOptions())
        .campaign;
  }

  /// Importa un paquete completo desde un fichero: campaña, mapas,
  /// documentación, música, fondos y voces.
  static Future<ImportReport> importFile(
    AppDatabase db,
    String path, {
    required DataRoot root,
    AppSettings? settings,
    ImportOptions options = const ImportOptions(),
  }) async {
    final input = InputFileStream(path);
    final ImportReport report;
    final Map<String, dynamic> json;
    final List<(String, String)> pending;
    try {
      final archive = ZipDecoder().decodeStream(input);
      json = _parse(archive);
      report = _importCore(db, json, archive,
          mapsDir: root.maps, docsDir: root.documents, settings: settings, options: options);
      pending = _planAssets(db, json, archive, root, settings, options, report);
    } finally {
      input.closeSync();
    }
    // Los ficheros grandes (música, voces) se extraen en segundo plano.
    if (pending.isNotEmpty) await Isolate.run(() => _extractAll(path, pending));
    _finishAssets(db, json, root, settings, options, report);
    return report;
  }

  static ImportReport _importCore(
    AppDatabase db,
    Map<String, dynamic> json,
    Archive archive, {
    required String mapsDir,
    required String? docsDir,
    required AppSettings? settings,
    required ImportOptions options,
  }) {
    final cj = (json['campaign'] as Map).cast<String, dynamic>();
    final existing = db.campaigns().map((c) => c.title).toSet();
    var title = (cj['title'] ?? 'Historia importada').toString();
    if (existing.contains(title)) title = '$title (importada)';

    // Vectores calculados con otro modelo de embeddings no sirven aquí.
    final pkgEmbed = (((json['requirements'] as Map?) ?? const {})['embedModel'] ?? '').toString();
    final localEmbed = settings == null ? '' : p.basename(settings.embedModel);
    final dropVectors = pkgEmbed.isNotEmpty && localEmbed.isNotEmpty && pkgEmbed != localEmbed;
    List<double>? vector(Object? emb) => !dropVectors && emb is String ? AppDatabase.decodeVector(base64Decode(emb)) : null;

    final bible = ((cj['bible'] as Map?) ?? {}).cast<String, dynamic>();
    final c = db.insertCampaign(Campaign(
      title: title,
      theme: (cj['theme'] ?? 'Sin tema').toString(),
      setting: (cj['setting'] ?? '').toString(),
      tone: (cj['tone'] ?? '').toString(),
      premise: (cj['premise'] ?? '').toString(),
      bible: bible,
      memory: (cj['memory'] ?? '').toString(),
      currentAct: (cj['currentAct'] as num?)?.toInt() ?? 0,
      location: (cj['location'] ?? '').toString(),
    ));
    final id = c.id!;
    final report = ImportReport(c)
      ..chatModel = (((json['requirements'] as Map?) ?? const {})['chatModel'] ?? '').toString();
    final written = <String>[];

    db.db.execute('BEGIN');
    try {
      db.setCampaignPlayers(id, [
        for (final pl in _maps(json['players']))
          () {
            final player = db.upsertPlayer((pl['name'] ?? 'Jugador').toString());
            return CampaignPlayer(
              playerId: player.id!,
              playerName: player.name,
              characterName: (pl['characterName'] ?? '').toString(),
              characterSheet: (pl['characterSheet'] ?? '').toString(),
            );
          }(),
      ]);

      for (final n in _maps(json['npcs'])) {
        db.upsertNpc(Npc(
          campaignId: id,
          name: (n['name'] ?? '').toString(),
          description: (n['description'] ?? '').toString(),
          voiceHint: (n['voiceHint'] ?? '').toString(),
          voice: VoiceProfile.fromJson(((n['voice'] as Map?) ?? {}).cast<String, dynamic>()),
          goal: (n['goal'] ?? '').toString(),
        ));
        final saved = db.npcByName(id, (n['name'] ?? '').toString());
        if (saved != null && (n['attitude'] != null || n['knows'] != null)) {
          saved
            ..attitude = (n['attitude'] as num?)?.toInt() ?? 0
            ..knows = ((n['knows'] as List?) ?? const []).map((e) => e.toString()).toList();
          db.updateNpcState(saved);
        }
      }
      for (final e in _maps(json['entities'])) {
        db.upsertEntity(id, (e['name'] ?? '').toString(),
            type: (e['type'] ?? 'otro').toString(), description: (e['description'] ?? '').toString());
      }
      for (final r in _maps(json['relations'])) {
        final s = db.upsertEntity(id, (r['source'] ?? '').toString());
        final t = db.upsertEntity(id, (r['target'] ?? '').toString());
        final rid = db.addRelation(id, s.id!, (r['relation'] ?? '').toString(), t.id!,
            session: (r['since'] as num?)?.toInt() ?? 0);
        if (rid != null && r['ended'] == true) db.endRelation(rid, session: (r['until'] as num?)?.toInt() ?? 0);
      }
      for (final ch in _maps(json['characters'])) {
        final name = (ch['name'] ?? '').toString();
        if (name.isNotEmpty) db.saveCharState(CharacterState.fromJson(id, name, ch));
      }
      for (final pin in (json['pins'] as List? ?? const [])) {
        if ('$pin'.trim().isNotEmpty) db.addPin(PinnedMemory(campaignId: id, text: '$pin'));
      }
      for (final t in _maps(json['threads'])) {
        db.addPlotThread(PlotThread(
          campaignId: id,
          kind: (t['kind'] ?? 'pendiente').toString(),
          text: (t['text'] ?? '').toString(),
          open: t['open'] != false,
          session: (t['session'] as num?)?.toInt() ?? 0,
        ));
      }
      for (final k in _maps(json['clocks'])) {
        db.saveClock(WorldClock(
          campaignId: id,
          name: (k['name'] ?? '').toString(),
          owner: (k['owner'] ?? '').toString(),
          segments: (k['segments'] as num?)?.toInt() ?? 6,
          filled: (k['filled'] as num?)?.toInt() ?? 0,
          consequence: (k['consequence'] ?? '').toString(),
          active: k['active'] != false,
          stance: (k['stance'] ?? 'desconocen').toString(),
        ));
      }
      if (_maps(json['clocks']).isNotEmpty && c.bible['_relojes'] != true) {
        c.bible['_relojes'] = true;
        db.updateCampaign(c);
      }
      for (final ch in _maps(json['chunks'])) {
        final v = vector(ch['embedding']);
        if (ch['embedding'] != null && v == null) report.needsReembed = true;
        db.addChunk(LoreChunk(
          campaignId: id,
          source: (ch['source'] ?? '').toString(),
          text: (ch['text'] ?? '').toString(),
          embedding: v,
        ));
      }

      final idMap = <int, int>{};
      for (final s in _maps(json['sessions'])) {
        db.db.execute(
          'INSERT INTO sessions (campaign_id, number, started_at, ended_at, summary) VALUES (?, ?, ?, ?, ?)',
          [id, (s['number'] as num).toInt(), s['startedAt'], s['endedAt'], (s['summary'] ?? '').toString()],
        );
        final sid = db.db.lastInsertRowId;
        for (final m in _maps(s['messages'])) {
          db.db.execute(
            'INSERT INTO messages (campaign_id, session_id, role, speaker, content, thinking, ts) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [id, sid, m['role'], m['speaker'] ?? '', m['content'] ?? '', m['thinking'] ?? '', m['ts']],
          );
          if (m['id'] is num) idMap[(m['id'] as num).toInt()] = db.db.lastInsertRowId;
        }
      }
      // El puntero de memoria apunta a ids de mensajes: se traduce.
      final ptr = (bible[_memoryPointerKey] as num?)?.toInt();
      if (ptr != null) {
        final candidates = idMap.keys.where((k) => k <= ptr);
        if (candidates.isEmpty) {
          c.bible.remove(_memoryPointerKey);
        } else {
          c.bible[_memoryPointerKey] = idMap[candidates.reduce((a, b) => a > b ? a : b)];
        }
        db.updateCampaign(c);
      }

      Directory(mapsDir).createSync(recursive: true);
      for (final m in _maps(json['maps'])) {
        final image = m['image'];
        final file = image is String ? archive.findFile(image) : null;
        if (file == null) continue;
        final dest = _unique(mapsDir, 'importado_${p.basename(image as String)}');
        _extract(file, dest);
        written.add(dest);
        db.addMap(MapRecord(
          campaignId: id,
          title: (m['title'] ?? 'Mapa').toString(),
          kind: (m['kind'] ?? 'mazmorra').toString(),
          seed: (m['seed'] as num?)?.toInt() ?? 0,
          imagePath: dest,
          keyJson: jsonEncode(m['key'] ?? []),
          createdAt: DateTime.tryParse('${m['createdAt']}'),
        ));
      }

      // Documentación: la de la campaña se liga a la nueva; la general sólo
      // se añade si este equipo no tiene ya un documento con ese título.
      final globalTitles = {
        for (final d in db.documents())
          if (d.campaignId == null) AppDatabase.normalize(d.title),
      };
      for (final d in _maps(json['documents'])) {
        final global = d['global'] == true;
        final docTitle = (d['title'] ?? 'Documento').toString();
        if (global && (!options.globalDocs || globalTitles.contains(AppDatabase.normalize(docTitle)))) continue;
        var path = '';
        final fileName = d['file'];
        final entry = fileName is String && docsDir != null ? archive.findFile(fileName) : null;
        if (entry != null) {
          path = _unique(docsDir!, p.basename(fileName as String));
          _extract(entry, path);
          written.add(path);
        }
        final doc = db.addDocument(DocumentRecord(
          campaignId: global ? null : id,
          title: docTitle,
          path: path,
          kind: (d['kind'] ?? '').toString(),
          chars: (d['chars'] as num?)?.toInt() ?? 0,
        ));
        final chunks = _maps(d['chunks']).toList();
        final vectors = [for (final ch in chunks) vector(ch['embedding'])];
        if (chunks.any((ch) => ch['embedding'] != null) && vectors.contains(null)) report.needsReembed = true;
        db.addDocChunks(doc.id!, [for (final ch in chunks) (ch['text'] ?? '').toString()], vectors);
        report.documents++;
      }
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      db.deleteCampaign(id);
      for (final f in written) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
    return ImportReport(db.campaign(id)!)
      ..chatModel = report.chatModel
      ..needsReembed = report.needsReembed
      ..documents = report.documents;
  }

  // ---------------------------------------------------- música, fondos, voces

  /// Decide qué ficheros sacar del paquete y a dónde. Devuelve pares
  /// (entrada del ZIP, destino). Lo que hay que apuntar en la base de datos
  /// se hace después en [_finishAssets], ya con los ficheros en su sitio.
  static List<(String, String)> _planAssets(
    AppDatabase db,
    Map<String, dynamic> json,
    Archive archive,
    DataRoot root,
    AppSettings? settings,
    ImportOptions o,
    ImportReport report,
  ) {
    final out = <(String, String)>[];
    final names = {for (final f in archive.files) f.name};

    if (o.music) {
      final music = ((json['music'] as Map?) ?? const {}).cast<String, dynamic>();
      final existing = db.tracks();
      final sitNames = {for (final s in db.situations()) s.id: AppDatabase.normalize(s.name)};
      for (final t in _maps(music['tracks'])) {
        final file = t['file'];
        if (file is! String || !names.contains(file)) continue;
        final sit = (t['situation'] ?? '').toString();
        final title = (t['title'] ?? '').toString();
        // Ya está en la biblioteca (mismo título, situación y tamaño).
        final dup = existing.any((e) =>
            e.title == title &&
            (sitNames[e.situationId] ?? '') == AppDatabase.normalize(sit) &&
            _length(root.resolve(e.path)) == (t['bytes'] as num?)?.toInt());
        if (dup) {
          report.tracksSkipped++;
          t['_dest'] = null;
          continue;
        }
        final folder = p.join(root.music, _safe(sit.isEmpty ? 'Sin situación' : sit));
        final dest = _unique(folder, p.basename(file), reserved: out.map((e) => e.$2));
        t['_dest'] = dest;
        out.add((file, dest));
      }
    }

    if (o.backgrounds && settings != null) {
      final bgs = ((json['backgrounds'] as Map?) ?? const {}).cast<String, dynamic>();
      final plan = <String, String>{};
      for (final e in bgs.entries) {
        if (Scenes.byId(e.key) == null || e.value is! String || !names.contains(e.value)) continue;
        final current = settings.sceneBackground(e.key);
        if (!o.replaceBackgrounds && current.isNotEmpty && File(root.resolve(current)).existsSync()) continue;
        final dest = _unique(root.backgrounds, 'importado_${e.key}${p.extension(e.value as String)}');
        plan[e.key] = dest;
        out.add((e.value as String, dest));
      }
      json['_backgroundsPlan'] = plan;
    }

    if (o.images) {
      final dir = root.campaignImages(report.campaign.id!);
      for (final i in _maps(json['images'])) {
        final file = i['file'];
        if (file is! String || !names.contains(file)) continue;
        final dest = _unique(dir, p.basename(file), reserved: out.map((e) => e.$2));
        if (!p.isWithin(dir, dest)) continue;
        i['_dest'] = dest;
        out.add((file, dest));
      }
    }

    final voices = ((json['voices'] as Map?) ?? const {}).cast<String, dynamic>();
    for (final v in _maps(voices['packs'])) {
      final id = (v['id'] ?? '').toString();
      if (id.isEmpty || id.contains('/') || id.contains(r'\') || id.contains('..')) continue;
      final dir = p.join(root.voices, id);
      if (File(p.join(dir, 'pack.json')).existsSync()) continue; // ya instalada
      if (v['included'] == true && o.voiceModels) {
        final prefix = 'voces/$id/';
        for (final name in names.where((n) => n.startsWith(prefix))) {
          final dest = p.normalize(p.join(dir, name.substring(prefix.length)));
          if (!p.isWithin(dir, dest)) continue; // nada de rutas que se salgan
          out.add((name, dest));
        }
        report.installedVoices.add(id);
      } else {
        report.missingVoices.add(id);
      }
    }
    return out;
  }

  static void _finishAssets(
    AppDatabase db,
    Map<String, dynamic> json,
    DataRoot root,
    AppSettings? settings,
    ImportOptions o,
    ImportReport report,
  ) {
    if (o.music) {
      final music = ((json['music'] as Map?) ?? const {}).cast<String, dynamic>();
      final situations = {for (final s in db.situations()) AppDatabase.normalize(s.name): s};
      for (final s in _maps(music['situations'])) {
        final name = (s['name'] ?? '').toString().trim();
        if (name.isEmpty || situations.containsKey(AppDatabase.normalize(name))) continue;
        situations[AppDatabase.normalize(name)] = db.addSituation(name, (s['icon'] ?? '🎵').toString());
      }
      for (final t in _maps(music['tracks'])) {
        final dest = t['_dest'];
        if (dest is! String || !File(dest).existsSync()) continue;
        final sit = (t['situation'] ?? '').toString();
        db.addTrack(Track(
          path: root.toStored(dest),
          title: (t['title'] ?? p.basenameWithoutExtension(dest)).toString(),
          situationId: sit.isEmpty ? null : situations[AppDatabase.normalize(sit)]?.id,
          volume: (t['volume'] as num?)?.toDouble() ?? 1.0,
        ));
        report.tracks++;
      }
    }

    if (settings != null) {
      final plan = ((json['_backgroundsPlan'] as Map?) ?? const {}).cast<String, String>();
      for (final e in plan.entries) {
        if (!File(e.value).existsSync()) continue;
        settings.setSceneBackground(e.key, root.toStored(e.value));
        report.backgrounds++;
      }
    }

    if (o.images) {
      final cid = report.campaign.id!;
      int? pinned;
      final oldPin = (json['campaign'] as Map?)?['bible'] is Map ? ((json['campaign'] as Map)['bible'] as Map)['_imagenFija'] : null;
      for (final i in _maps(json['images'])) {
        final kind = (i['kind'] ?? '').toString();
        final subject = (i['subject'] ?? '').toString().trim();
        if (!ImageRecord.kinds.contains(kind) || subject.isEmpty) continue;
        final dest = i['_dest'];
        final hasFile = dest is String && File(dest).existsSync();
        if (!hasFile && kind != ImageRecord.sceneKind) continue;
        final rec = db.saveImage(ImageRecord(
          campaignId: cid,
          kind: kind,
          subject: subject,
          description: (i['description'] ?? '').toString(),
          prompt: (i['prompt'] ?? '').toString(),
          origin: hasFile ? (i['origin'] ?? 'importada').toString() : '',
          scene: (i['scene'] ?? '').toString(),
          path: hasFile ? dest : '',
        ));
        if (hasFile) report.images++;
        if (oldPin != null && i['id'] == oldPin) pinned = rec.id;
      }
      // La imagen fijada en la mesa apuntaba a ids del otro equipo.
      final c = db.campaign(cid)!;
      if (c.bible.containsKey('_imagenFija') || pinned != null) {
        if (pinned == null) {
          c.bible.remove('_imagenFija');
        } else {
          c.bible['_imagenFija'] = pinned;
        }
        db.updateCampaign(c);
      }
    } else {
      final c = db.campaign(report.campaign.id!)!;
      if (c.bible.remove('_imagenFija') != null) db.updateCampaign(c);
    }

    for (final id in report.installedVoices.toList()) {
      if (!File(p.join(root.voices, id, 'pack.json')).existsSync()) {
        report.installedVoices.remove(id);
        report.missingVoices.add(id);
        report.warnings.add('La voz $id venía incompleta');
      }
    }

    final voices = ((json['voices'] as Map?) ?? const {}).cast<String, dynamic>();
    final narrator = voices['narrator'];
    if (o.narrator && settings != null && narrator is Map) {
      final v = VoiceProfile.fromJson(narrator.cast<String, dynamic>());
      // Una voz neuronal que no está instalada dejaría al narrador mudo.
      final usable = v.engine != 'neural' || File(p.join(root.voices, v.neuralPack, 'pack.json')).existsSync();
      if (usable) {
        settings.narratorVoice = v;
        report.narratorApplied = true;
      }
    }
  }

  static void _extractAll(String zipPath, List<(String, String)> entries) {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final (name, dest) in entries) {
        final f = archive.findFile(name);
        if (f != null) _extract(f, dest);
      }
    } finally {
      input.closeSync();
    }
  }

  static void _extract(ArchiveFile f, String dest) {
    Directory(p.dirname(dest)).createSync(recursive: true);
    final out = OutputFileStream(dest);
    try {
      f.writeContent(out);
    } finally {
      out.closeSync();
    }
  }

  static String _unique(String dir, String name, {Iterable<String> reserved = const []}) {
    final taken = reserved.toSet();
    var dest = p.join(dir, name);
    for (var i = 2; File(dest).existsSync() || taken.contains(dest); i++) {
      dest = p.join(dir, '${p.basenameWithoutExtension(name)}_$i${p.extension(name)}');
    }
    return dest;
  }

  static int? _length(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return null;
    }
  }

  static String _safe(String s) {
    final t = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '').replaceAll(RegExp(r'\s+'), ' ');
    return t.isEmpty || t == '.' || t == '..' ? 'sin-nombre' : t;
  }

  static Iterable<Map<String, dynamic>> _maps(Object? v) =>
      v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()) : const [];
}

class _Attachment {
  _Attachment(this.name, this.path, this.store);
  final String name;
  final String path;

  /// Guardar sin comprimir (audio e imágenes ya vienen comprimidos).
  final bool store;
}
