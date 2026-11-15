import 'dart:convert';

/// Modelos de datos de la aplicación. Se guardan en SQLite (ver db.dart).

class Player {
  Player({this.id, required this.name, this.notes = ''});
  int? id;
  String name;
  String notes;

  factory Player.fromRow(Map<String, Object?> r) => Player(
        id: r['id'] as int,
        name: r['name'] as String,
        notes: (r['notes'] as String?) ?? '',
      );
}

class CampaignPlayer {
  CampaignPlayer({
    required this.playerId,
    required this.playerName,
    this.characterName = '',
    this.characterSheet = '',
  });
  final int playerId;
  final String playerName;
  String characterName;
  String characterSheet;
}

class Campaign {
  Campaign({
    this.id,
    required this.title,
    required this.theme,
    this.setting = '',
    this.tone = '',
    this.premise = '',
    Map<String, dynamic>? bible,
    this.memory = '',
    this.currentAct = 0,
    this.location = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : bible = bible == null ? <String, dynamic>{} : Map<String, dynamic>.of(bible),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  int? id;
  String title;

  /// Tema o género: fantasía, terror, ciencia ficción... Se usa para ordenar los logs.
  String theme;
  String setting;
  String tone;
  String premise;

  /// "Biblia" de campaña generada por la IA: actos, villano, PNJ, secretos...
  Map<String, dynamic> bible;

  /// Memoria a largo plazo: resumen acumulado del estado de la historia.
  String memory;
  int currentAct;
  String location;
  DateTime createdAt;
  DateTime updatedAt;

  factory Campaign.fromRow(Map<String, Object?> r) => Campaign(
        id: r['id'] as int,
        title: r['title'] as String,
        theme: r['theme'] as String,
        setting: (r['setting'] as String?) ?? '',
        tone: (r['tone'] as String?) ?? '',
        premise: (r['premise'] as String?) ?? '',
        bible: _decodeMap(r['bible'] as String?),
        memory: (r['memory'] as String?) ?? '',
        currentAct: (r['current_act'] as int?) ?? 0,
        location: (r['location'] as String?) ?? '',
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
      );

  List<Map<String, dynamic>> get acts =>
      ((bible['acts'] as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}

Map<String, dynamic> _decodeMap(String? s) {
  if (s == null || s.isEmpty) return <String, dynamic>{};
  try {
    final v = jsonDecode(s);
    return v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

class GameSession {
  GameSession({
    this.id,
    required this.campaignId,
    required this.number,
    DateTime? startedAt,
    this.endedAt,
    this.summary = '',
  }) : startedAt = startedAt ?? DateTime.now();
  int? id;
  final int campaignId;
  final int number;
  final DateTime startedAt;
  DateTime? endedAt;
  String summary;

  factory GameSession.fromRow(Map<String, Object?> r) => GameSession(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        number: r['number'] as int,
        startedAt: DateTime.parse(r['started_at'] as String),
        endedAt: r['ended_at'] == null ? null : DateTime.parse(r['ended_at'] as String),
        summary: (r['summary'] as String?) ?? '',
      );
}

enum MessageRole { player, gm, system }

class ChatMessage {
  ChatMessage({
    this.id,
    required this.campaignId,
    required this.sessionId,
    required this.role,
    this.speaker = '',
    required this.content,
    this.thinking = '',
    DateTime? ts,
  }) : ts = ts ?? DateTime.now();
  int? id;
  final int campaignId;
  final int sessionId;
  final MessageRole role;
  String speaker;
  String content;
  String thinking;
  final DateTime ts;

  factory ChatMessage.fromRow(Map<String, Object?> r) => ChatMessage(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        sessionId: r['session_id'] as int,
        role: MessageRole.values.byName(r['role'] as String),
        speaker: (r['speaker'] as String?) ?? '',
        content: r['content'] as String,
        thinking: (r['thinking'] as String?) ?? '',
        ts: DateTime.parse(r['ts'] as String),
      );
}

/// Perfil de voz de un PNJ (o del narrador).
class VoiceProfile {
  const VoiceProfile({
    this.engine = 'system',
    this.systemVoice = '',
    this.systemLocale = '',
    this.pitch = 1.0,
    this.rate = 0.5,
    this.neuralPack = '',
    this.speakerId = 0,
    this.speed = 1.0,
  });

  /// 'system' (TTS del sistema operativo) o 'neural' (sherpa-onnx local).
  final String engine;
  final String systemVoice;
  final String systemLocale;
  final double pitch;
  final double rate;
  final String neuralPack;
  final int speakerId;
  final double speed;

  Map<String, dynamic> toJson() => {
        'engine': engine,
        'systemVoice': systemVoice,
        'systemLocale': systemLocale,
        'pitch': pitch,
        'rate': rate,
        'neuralPack': neuralPack,
        'speakerId': speakerId,
        'speed': speed,
      };

  factory VoiceProfile.fromJson(Map<String, dynamic> j) => VoiceProfile(
        engine: (j['engine'] as String?) ?? 'system',
        systemVoice: (j['systemVoice'] as String?) ?? '',
        systemLocale: (j['systemLocale'] as String?) ?? '',
        pitch: (j['pitch'] as num?)?.toDouble() ?? 1.0,
        rate: (j['rate'] as num?)?.toDouble() ?? 0.5,
        neuralPack: (j['neuralPack'] as String?) ?? '',
        speakerId: (j['speakerId'] as num?)?.toInt() ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
      );

  VoiceProfile copyWith({
    String? engine,
    String? systemVoice,
    String? systemLocale,
    double? pitch,
    double? rate,
    String? neuralPack,
    int? speakerId,
    double? speed,
  }) =>
      VoiceProfile(
        engine: engine ?? this.engine,
        systemVoice: systemVoice ?? this.systemVoice,
        systemLocale: systemLocale ?? this.systemLocale,
        pitch: pitch ?? this.pitch,
        rate: rate ?? this.rate,
        neuralPack: neuralPack ?? this.neuralPack,
        speakerId: speakerId ?? this.speakerId,
        speed: speed ?? this.speed,
      );

  String encode() => jsonEncode(toJson());
  static VoiceProfile decode(String? s) => VoiceProfile.fromJson(_decodeMap(s));
}

class Npc {
  Npc({
    this.id,
    required this.campaignId,
    required this.name,
    this.description = '',
    this.voiceHint = '',
    this.voice = const VoiceProfile(),
    this.goal = '',
    this.attitude = 0,
    List<String>? knows,
    this.lastSeen = 0,
  }) : knows = knows ?? [];
  int? id;
  final int campaignId;
  String name;
  String description;

  /// Lo que quiere conseguir este PNJ (lo persigue aunque nadie le mire).
  String goal;

  /// Actitud hacia el grupo, de −3 (enemigo) a +3 (leal).
  int attitude;

  /// Lo que este PNJ ha presenciado en persona (sólo sabe eso y lo que le cuenten).
  List<String> knows;

  /// Último id de mensaje en el que intervino (0 = nunca).
  int lastSeen;

  static const attitudeNames = {-3: 'enemigo', -2: 'hostil', -1: 'receloso', 0: 'neutral', 1: 'cordial', 2: 'amistoso', 3: 'leal'};
  String get attitudeName => attitudeNames[attitude.clamp(-3, 3)]!;

  /// Pista de voz que sugirió la IA ("anciana ronca", "joven nervioso"...).
  String voiceHint;
  VoiceProfile voice;

  factory Npc.fromRow(Map<String, Object?> r) => Npc(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        name: r['name'] as String,
        description: (r['description'] as String?) ?? '',
        voiceHint: (r['voice_hint'] as String?) ?? '',
        voice: VoiceProfile.decode(r['voice'] as String?),
        goal: (r['goal'] as String?) ?? '',
        attitude: (r['attitude'] as int?) ?? 0,
        knows: _decodeList(r['knows'] as String?),
        lastSeen: (r['last_seen'] as int?) ?? 0,
      );
}

List<String> _decodeList(String? s) {
  if (s == null || s.isEmpty) return [];
  try {
    final v = jsonDecode(s);
    return v is List ? v.map((e) => e.toString()).toList() : [];
  } catch (_) {
    return [];
  }
}

/// Nodo del grafo de conocimiento.
class Entity {
  Entity({
    this.id,
    required this.campaignId,
    required this.name,
    this.type = 'otro',
    this.description = '',
  });
  int? id;
  final int campaignId;
  String name;
  String type;
  String description;

  factory Entity.fromRow(Map<String, Object?> r) => Entity(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        name: r['name'] as String,
        type: (r['type'] as String?) ?? 'otro',
        description: (r['description'] as String?) ?? '',
      );
}

/// Arista del grafo de conocimiento.
class Relation {
  Relation({
    this.id,
    required this.campaignId,
    required this.sourceId,
    required this.relation,
    required this.targetId,
    this.sourceName = '',
    this.targetName = '',
    this.ended = false,
    this.sinceSession = 0,
    this.untilSession = 0,
  });
  int? id;
  final int campaignId;
  final int sourceId;
  final String relation;
  final int targetId;
  String sourceName;
  String targetName;

  /// El hecho dejó de ser cierto (alguien se marchó, murió, perdió algo…).
  bool ended;

  /// Sesión en la que se supo y en la que dejó de ser cierto (0 = no consta).
  int sinceSession;
  int untilSession;

  @override
  String toString() => '$sourceName —$relation→ $targetName';
}

class Situation {
  Situation({this.id, required this.name, this.icon = '🎵', this.sortOrder = 0});
  int? id;
  String name;
  String icon;
  int sortOrder;

  factory Situation.fromRow(Map<String, Object?> r) => Situation(
        id: r['id'] as int,
        name: r['name'] as String,
        icon: (r['icon'] as String?) ?? '🎵',
        sortOrder: (r['sort_order'] as int?) ?? 0,
      );
}

class Track {
  Track({this.id, required this.path, required this.title, this.situationId, this.volume = 1.0});
  int? id;
  String path;
  String title;
  int? situationId;
  double volume;

  factory Track.fromRow(Map<String, Object?> r) => Track(
        id: r['id'] as int,
        path: r['path'] as String,
        title: r['title'] as String,
        situationId: r['situation_id'] as int?,
        volume: (r['volume'] as num?)?.toDouble() ?? 1.0,
      );
}

class MapRecord {
  MapRecord({
    this.id,
    this.campaignId,
    required this.title,
    required this.kind,
    required this.seed,
    required this.imagePath,
    this.keyJson = '[]',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  int? id;
  int? campaignId;
  String title;
  String kind;
  int seed;
  String imagePath;

  /// Leyenda de salas: lista JSON [{"n":1,"title":"...","text":"..."}].
  String keyJson;
  final DateTime createdAt;

  List<Map<String, dynamic>> get roomKey {
    try {
      final v = jsonDecode(keyJson);
      if (v is List) return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {}
    return const [];
  }

  factory MapRecord.fromRow(Map<String, Object?> r) => MapRecord(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int?,
        title: r['title'] as String,
        kind: r['kind'] as String,
        seed: r['seed'] as int,
        imagePath: r['image_path'] as String,
        keyJson: (r['key_json'] as String?) ?? '[]',
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

class LoreChunk {
  LoreChunk({
    this.id,
    required this.campaignId,
    required this.source,
    required this.text,
    this.embedding,
  });
  int? id;
  final int campaignId;
  final String source;
  final String text;
  List<double>? embedding;
}

/// Documento que la IA ha "aprendido" (indexado en su memoria).
class DocumentRecord {
  DocumentRecord({
    this.id,
    this.campaignId,
    required this.title,
    required this.path,
    required this.kind,
    this.chars = 0,
    this.chunks = 0,
    this.pendingEmbeddings = 0,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  factory DocumentRecord.fromRow(Map<String, Object?> r, {required String path}) => DocumentRecord(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int?,
        title: r['title'] as String,
        path: path,
        kind: r['kind'] as String,
        chars: r['chars'] as int,
        chunks: (r['n'] as int?) ?? 0,
        pendingEmbeddings: (r['pending'] as int?) ?? 0,
        addedAt: DateTime.tryParse(r['added_at'] as String),
      );

  int? id;
  /// null = documentación para todas las campañas.
  final int? campaignId;
  final String title;
  final String path;
  final String kind;
  final int chars;
  final int chunks;
  final int pendingEmbeddings;
  final DateTime addedAt;
}

// ======================================================================
// Estado de juego que lleva la app (no la IA): fichas, recuerdos fijados,
// asuntos pendientes y relojes del mundo.
// ======================================================================

/// Objeto del inventario de un personaje.
class InventoryItem {
  InventoryItem(this.name, [this.qty = 1]);
  String name;
  int qty;

  Map<String, dynamic> toJson() => {'name': name, 'qty': qty};
  factory InventoryItem.fromJson(Map<String, dynamic> j) =>
      InventoryItem((j['name'] ?? '').toString(), (j['qty'] as num?)?.toInt() ?? 1);
}

/// Ficha de juego de un personaje: lo que la app sabe con certeza.
class CharacterState {
  CharacterState({
    this.id,
    required this.campaignId,
    required this.name,
    this.player = '',
    this.hp = 10,
    this.maxHp = 10,
    this.gold = 0,
    List<String>? conditions,
    List<InventoryItem>? inventory,
    Map<String, int>? mods,
    this.notes = '',
  })  : conditions = conditions ?? [],
        inventory = inventory ?? [],
        mods = mods ?? {};

  int? id;
  final int campaignId;
  String name;

  /// Jugador que lleva al personaje ('' si es un compañero del grupo).
  String player;
  int hp;
  int maxHp;
  int gold;
  List<String> conditions;
  List<InventoryItem> inventory;

  /// Modificadores por habilidad o característica ("Percepción": 2).
  Map<String, int> mods;
  String notes;

  bool get down => hp <= 0;

  int modFor(String skill) {
    final n = _norm(skill);
    for (final e in mods.entries) {
      if (_norm(e.key) == n) return e.value;
    }
    for (final e in mods.entries) {
      final k = _norm(e.key);
      if (k.isNotEmpty && (n.contains(k) || k.contains(n))) return e.value;
    }
    return 0;
  }

  static String _norm(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñ';
    const to = 'aaaaeeeeiiiioooouuuun';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().trim().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'player': player,
        'hp': hp,
        'maxHp': maxHp,
        'gold': gold,
        'conditions': conditions,
        'inventory': [for (final i in inventory) i.toJson()],
        'mods': mods,
        'notes': notes,
      };

  factory CharacterState.fromJson(int campaignId, String name, Map<String, dynamic> j, {int? id}) => CharacterState(
        id: id,
        campaignId: campaignId,
        name: name,
        player: (j['player'] ?? '').toString(),
        hp: (j['hp'] as num?)?.toInt() ?? 10,
        maxHp: (j['maxHp'] as num?)?.toInt() ?? 10,
        gold: (j['gold'] as num?)?.toInt() ?? 0,
        conditions: ((j['conditions'] as List?) ?? const []).map((e) => e.toString()).toList(),
        inventory: ((j['inventory'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => InventoryItem.fromJson(e.cast<String, dynamic>()))
            .toList(),
        mods: ((j['mods'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0)),
        notes: (j['notes'] ?? '').toString(),
      );

  /// Línea compacta para el prompt del director.
  String summary() {
    final b = StringBuffer('$name: PV $hp/$maxHp');
    if (down) b.write(' (¡FUERA DE COMBATE!)');
    if (gold != 0) b.write(', oro $gold');
    if (conditions.isNotEmpty) b.write(', estados: ${conditions.join(', ')}');
    if (inventory.isNotEmpty) {
      b.write(', lleva: ${inventory.map((i) => i.qty == 1 ? i.name : '${i.name} x${i.qty}').join(', ')}');
    }
    if (mods.isNotEmpty) b.write(', modificadores: ${mods.entries.map((e) => '${e.key} ${e.value >= 0 ? '+' : ''}${e.value}').join(', ')}');
    return b.toString();
  }
}

/// Recuerdo que el grupo ha fijado: entra siempre en el contexto del director.
class PinnedMemory {
  PinnedMemory({this.id, required this.campaignId, required this.text, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();
  int? id;
  final int campaignId;
  String text;
  final DateTime createdAt;

  factory PinnedMemory.fromRow(Map<String, Object?> r) => PinnedMemory(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        text: r['text'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

/// Asunto pendiente de la historia: promesas, deudas, amenazas, misiones…
class PlotThread {
  PlotThread({
    this.id,
    required this.campaignId,
    this.kind = 'pendiente',
    required this.text,
    this.open = true,
    this.session = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  static const kinds = ['promesa', 'deuda', 'amenaza', 'misión', 'pista', 'pendiente'];
  static const icons = {'promesa': '🤝', 'deuda': '💰', 'amenaza': '⚠️', 'misión': '📜', 'pista': '🔍', 'pendiente': '📌'};

  int? id;
  final int campaignId;
  String kind;
  String text;
  bool open;
  /// Sesión en la que apareció.
  int session;
  final DateTime createdAt;

  String get icon => icons[kind] ?? '📌';

  factory PlotThread.fromRow(Map<String, Object?> r) => PlotThread(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        kind: (r['kind'] as String?) ?? 'pendiente',
        text: r['text'] as String,
        open: (r['open'] as int? ?? 1) == 1,
        session: (r['session'] as int?) ?? 0,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

/// Reloj de progreso de una facción, del villano o de una amenaza: avanza
/// solo con el paso del tiempo aunque los jugadores no hagan nada.
class WorldClock {
  WorldClock({
    this.id,
    required this.campaignId,
    required this.name,
    this.owner = '',
    this.segments = 6,
    this.filled = 0,
    this.consequence = '',
    this.active = true,
    this.stance = 'desconocen',
  });

  /// Postura del grupo ante esta trama.
  static const stances = ['desconocen', 'se oponen', 'ayudan', 'ignoran', 'huyen'];

  int? id;
  final int campaignId;
  String name;
  /// Facción o PNJ que empuja este reloj.
  String owner;
  int segments;
  int filled;
  /// Qué pasa en el mundo cuando se llena.
  String consequence;
  bool active;
  String stance;

  bool get full => filled >= segments;

  factory WorldClock.fromRow(Map<String, Object?> r) => WorldClock(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        name: r['name'] as String,
        owner: (r['owner'] as String?) ?? '',
        segments: (r['segments'] as int?) ?? 6,
        filled: (r['filled'] as int?) ?? 0,
        consequence: (r['consequence'] as String?) ?? '',
        active: (r['active'] as int? ?? 1) == 1,
        stance: (r['stance'] as String?) ?? 'desconocen',
      );
}

// ======================================================================
// Imágenes de apoyo: retratos, cuerpos enteros y escenas.
// ======================================================================

/// Imagen de apoyo de una campaña. Hay como mucho una por tipo y sujeto:
/// el retrato y el cuerpo entero de cada personaje (PJ o PNJ, por nombre) y
/// una ilustración por escena o lugar de la historia.
///
/// Un registro sin fichero ([path] vacío) es una imagen que **falta**: la
/// escena o el personaje existen en la historia pero aún no tienen imagen.
class ImageRecord {
  ImageRecord({
    this.id,
    required this.campaignId,
    required this.kind,
    required this.subject,
    this.description = '',
    this.prompt = '',
    this.path = '',
    this.origin = '',
    this.scene = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  static const portrait = 'retrato';
  static const fullBody = 'cuerpo';
  static const sceneKind = 'escena';
  static const kinds = [portrait, fullBody, sceneKind];
  static const kindNames = {portrait: 'Retrato', fullBody: 'Cuerpo entero', sceneKind: 'Escena'};

  int? id;
  final int campaignId;

  /// 'retrato', 'cuerpo' o 'escena'.
  final String kind;

  /// Nombre del personaje o de la escena/lugar.
  String subject;

  /// Qué se ve, en español (lo escribe la historia, la IA o el usuario).
  String description;

  /// Texto que se envió al generador la última vez (editable).
  String prompt;

  /// Ruta del fichero (absoluta al leer; relativa a la carpeta de datos en la BD).
  String path;

  /// 'manual' (la eligió el usuario), 'generada' o 'importada'.
  String origin;

  /// Tipo de escena (castillo, cueva…) para las escenas; '' en personajes.
  String scene;
  final DateTime createdAt;

  bool get missing => path.isEmpty;
  bool get isScene => kind == sceneKind;

  factory ImageRecord.fromRow(Map<String, Object?> r, {required String path}) => ImageRecord(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        kind: r['kind'] as String,
        subject: r['subject'] as String,
        description: (r['description'] as String?) ?? '',
        prompt: (r['prompt'] as String?) ?? '',
        path: path,
        origin: (r['origin'] as String?) ?? '',
        scene: (r['scene'] as String?) ?? '',
        createdAt: DateTime.tryParse('${r['created_at']}'),
      );
}
