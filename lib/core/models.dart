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
  });
  int? id;
  final int campaignId;
  String name;
  String description;

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
      );
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
  });
  int? id;
  final int campaignId;
  final int sourceId;
  final String relation;
  final int targetId;
  String sourceName;
  String targetName;

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
