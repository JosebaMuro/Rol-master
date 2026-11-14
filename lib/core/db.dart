import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'portable.dart';

/// Acceso a la base de datos local (SQLite). Todo vive en un único fichero
/// dentro de la carpeta de datos de la app, así las partidas persisten entre
/// sesiones y se pueden continuar donde se dejaron.
class AppDatabase {
  AppDatabase(this.db, {this.root}) {
    _migrate();
  }

  factory AppDatabase.open(String path, {DataRoot? root}) => AppDatabase(sqlite3.open(path), root: root);
  factory AppDatabase.memory({DataRoot? root}) => AppDatabase(sqlite3.openInMemory(), root: root);

  final Database db;

  /// Carpeta de datos: las rutas de ficheros se guardan relativas a ella.
  final DataRoot? root;
  String _store(String path) => root?.toStored(path) ?? path;
  String _resolve(String path) => root?.resolve(path) ?? path;

  static const int schemaVersion = 3;

  void _migrate() {
    db.execute('PRAGMA foreign_keys = ON');
    final v = db.select('PRAGMA user_version').first.values.first as int;
    if (v < 1) {
      db.execute('''
CREATE TABLE IF NOT EXISTS players (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS campaigns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  theme TEXT NOT NULL,
  setting TEXT DEFAULT '',
  tone TEXT DEFAULT '',
  premise TEXT DEFAULT '',
  bible TEXT DEFAULT '{}',
  memory TEXT DEFAULT '',
  current_act INTEGER DEFAULT 0,
  location TEXT DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS campaign_players (
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  character_name TEXT DEFAULT '',
  character_sheet TEXT DEFAULT '',
  PRIMARY KEY (campaign_id, player_id)
);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  number INTEGER NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  summary TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  speaker TEXT DEFAULT '',
  content TEXT NOT NULL,
  thinking TEXT DEFAULT '',
  ts TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_campaign ON messages(campaign_id, id);
CREATE TABLE IF NOT EXISTS npcs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT DEFAULT '',
  voice_hint TEXT DEFAULT '',
  voice TEXT DEFAULT '{}',
  UNIQUE (campaign_id, name)
);
CREATE TABLE IF NOT EXISTS entities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  norm TEXT NOT NULL,
  type TEXT DEFAULT 'otro',
  description TEXT DEFAULT '',
  UNIQUE (campaign_id, norm)
);
CREATE TABLE IF NOT EXISTS relations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  source_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  relation TEXT NOT NULL,
  target_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  UNIQUE (campaign_id, source_id, relation, target_id)
);
CREATE TABLE IF NOT EXISTS chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding BLOB
);
CREATE INDEX IF NOT EXISTS idx_chunks_campaign ON chunks(campaign_id);
CREATE TABLE IF NOT EXISTS situations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  icon TEXT DEFAULT '🎵',
  sort_order INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS tracks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL,
  title TEXT NOT NULL,
  situation_id INTEGER REFERENCES situations(id) ON DELETE SET NULL,
  volume REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS maps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER REFERENCES campaigns(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,
  seed INTEGER NOT NULL,
  image_path TEXT NOT NULL,
  key_json TEXT DEFAULT '[]',
  created_at TEXT NOT NULL
);
''');
      _seedSituations();
    }
    if (v < 2) {
      // Documentación que la IA aprende (reglamentos, ambientación, apuntes…).
      // campaign_id NULL = sirve para todas las campañas.
      db.execute('''
CREATE TABLE IF NOT EXISTS documents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER REFERENCES campaigns(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  path TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT '',
  chars INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS doc_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  embedding BLOB
);
CREATE INDEX IF NOT EXISTS idx_doc_chunks_doc ON doc_chunks(doc_id);
''');
    }
    if (v < 3) {
      // Estado de juego que lleva la app, grafo con caducidad, PNJ vivos y
      // mundo que avanza solo.
      db.execute('''
CREATE TABLE IF NOT EXISTS char_states (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  norm TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '{}',
  UNIQUE (campaign_id, norm)
);
CREATE TABLE IF NOT EXISTS pins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS plot_threads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  kind TEXT NOT NULL DEFAULT 'pendiente',
  text TEXT NOT NULL,
  norm TEXT NOT NULL DEFAULT '',
  open INTEGER NOT NULL DEFAULT 1,
  session INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS world_clocks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  owner TEXT NOT NULL DEFAULT '',
  segments INTEGER NOT NULL DEFAULT 6,
  filled INTEGER NOT NULL DEFAULT 0,
  consequence TEXT NOT NULL DEFAULT '',
  active INTEGER NOT NULL DEFAULT 1,
  stance TEXT NOT NULL DEFAULT 'desconocen'
);
ALTER TABLE relations ADD COLUMN ended INTEGER NOT NULL DEFAULT 0;
ALTER TABLE relations ADD COLUMN since_session INTEGER NOT NULL DEFAULT 0;
ALTER TABLE relations ADD COLUMN until_session INTEGER NOT NULL DEFAULT 0;
ALTER TABLE npcs ADD COLUMN goal TEXT NOT NULL DEFAULT '';
ALTER TABLE npcs ADD COLUMN attitude INTEGER NOT NULL DEFAULT 0;
ALTER TABLE npcs ADD COLUMN knows TEXT NOT NULL DEFAULT '[]';
ALTER TABLE npcs ADD COLUMN last_seen INTEGER NOT NULL DEFAULT 0;
''');
    }
    if (v < schemaVersion) db.execute('PRAGMA user_version = $schemaVersion');
  }

  static const defaultSituations = <(String, String)>[
    ('Exploración', '🧭'),
    ('Combate', '⚔️'),
    ('Jefe final', '🐉'),
    ('Taberna', '🍺'),
    ('Ciudad', '🏰'),
    ('Viaje', '🐎'),
    ('Mazmorra', '🕯️'),
    ('Misterio', '🔍'),
    ('Terror', '👻'),
    ('Tristeza', '🌧️'),
    ('Victoria', '🏆'),
    ('Calma', '🌙'),
  ];

  void _seedSituations() {
    final st = db.prepare('INSERT OR IGNORE INTO situations (name, icon, sort_order) VALUES (?, ?, ?)');
    var i = 0;
    for (final (name, icon) in defaultSituations) {
      st.execute([name, icon, i++]);
    }
    st.close();
  }

  void close() => db.close();

  String _now() => DateTime.now().toIso8601String();

  // ---------------------------------------------------------------- players
  List<Player> players() =>
      db.select('SELECT * FROM players ORDER BY name COLLATE NOCASE').map(Player.fromRow).toList();

  Player upsertPlayer(String name, {String notes = ''}) {
    final existing = db.select('SELECT * FROM players WHERE name = ?', [name]);
    if (existing.isNotEmpty) return Player.fromRow(existing.first);
    db.execute('INSERT INTO players (name, notes) VALUES (?, ?)', [name, notes]);
    return Player(id: db.lastInsertRowId, name: name, notes: notes);
  }

  void deletePlayer(int id) => db.execute('DELETE FROM players WHERE id = ?', [id]);

  // -------------------------------------------------------------- campaigns
  List<Campaign> campaigns() =>
      db.select('SELECT * FROM campaigns ORDER BY updated_at DESC').map(Campaign.fromRow).toList();

  Campaign? campaign(int id) {
    final r = db.select('SELECT * FROM campaigns WHERE id = ?', [id]);
    return r.isEmpty ? null : Campaign.fromRow(r.first);
  }

  Campaign insertCampaign(Campaign c) {
    db.execute(
      'INSERT INTO campaigns (title, theme, setting, tone, premise, bible, memory, current_act, location, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        c.title,
        c.theme,
        c.setting,
        c.tone,
        c.premise,
        jsonEncode(c.bible),
        c.memory,
        c.currentAct,
        c.location,
        c.createdAt.toIso8601String(),
        c.updatedAt.toIso8601String(),
      ],
    );
    c.id = db.lastInsertRowId;
    return c;
  }

  void updateCampaign(Campaign c) {
    c.updatedAt = DateTime.now();
    db.execute(
      'UPDATE campaigns SET title=?, theme=?, setting=?, tone=?, premise=?, bible=?, memory=?, current_act=?, location=?, updated_at=? WHERE id=?',
      [
        c.title,
        c.theme,
        c.setting,
        c.tone,
        c.premise,
        jsonEncode(c.bible),
        c.memory,
        c.currentAct,
        c.location,
        c.updatedAt.toIso8601String(),
        c.id,
      ],
    );
  }

  void deleteCampaign(int id) => db.execute('DELETE FROM campaigns WHERE id = ?', [id]);

  void setCampaignPlayers(int campaignId, List<CampaignPlayer> list) {
    db.execute('DELETE FROM campaign_players WHERE campaign_id = ?', [campaignId]);
    for (final p in list) {
      db.execute(
        'INSERT INTO campaign_players (campaign_id, player_id, character_name, character_sheet) VALUES (?, ?, ?, ?)',
        [campaignId, p.playerId, p.characterName, p.characterSheet],
      );
    }
  }

  List<CampaignPlayer> campaignPlayers(int campaignId) => db
      .select(
        'SELECT cp.*, p.name AS player_name FROM campaign_players cp JOIN players p ON p.id = cp.player_id '
        'WHERE cp.campaign_id = ? ORDER BY p.name',
        [campaignId],
      )
      .map((r) => CampaignPlayer(
            playerId: r['player_id'] as int,
            playerName: r['player_name'] as String,
            characterName: (r['character_name'] as String?) ?? '',
            characterSheet: (r['character_sheet'] as String?) ?? '',
          ))
      .toList();

  List<Campaign> campaignsForPlayer(int playerId) => db
      .select(
        'SELECT c.* FROM campaigns c JOIN campaign_players cp ON cp.campaign_id = c.id '
        'WHERE cp.player_id = ? ORDER BY c.theme, c.updated_at DESC',
        [playerId],
      )
      .map(Campaign.fromRow)
      .toList();

  List<String> themes() => db
      .select('SELECT DISTINCT theme FROM campaigns ORDER BY theme COLLATE NOCASE')
      .map((r) => r['theme'] as String)
      .toList();

  List<Campaign> campaignsForTheme(String theme) => db
      .select('SELECT * FROM campaigns WHERE theme = ? ORDER BY updated_at DESC', [theme])
      .map(Campaign.fromRow)
      .toList();

  // --------------------------------------------------------------- sessions
  List<GameSession> sessions(int campaignId) => db
      .select('SELECT * FROM sessions WHERE campaign_id = ? ORDER BY number', [campaignId])
      .map(GameSession.fromRow)
      .toList();

  GameSession? lastSession(int campaignId) {
    final r = db.select('SELECT * FROM sessions WHERE campaign_id = ? ORDER BY number DESC LIMIT 1', [campaignId]);
    return r.isEmpty ? null : GameSession.fromRow(r.first);
  }

  GameSession startSession(int campaignId) {
    final last = lastSession(campaignId);
    final s = GameSession(campaignId: campaignId, number: (last?.number ?? 0) + 1);
    db.execute(
      'INSERT INTO sessions (campaign_id, number, started_at) VALUES (?, ?, ?)',
      [campaignId, s.number, s.startedAt.toIso8601String()],
    );
    s.id = db.lastInsertRowId;
    return s;
  }

  void endSession(GameSession s, String summary) {
    s.endedAt = DateTime.now();
    s.summary = summary;
    db.execute(
      'UPDATE sessions SET ended_at = ?, summary = ? WHERE id = ?',
      [s.endedAt!.toIso8601String(), summary, s.id],
    );
  }

  // --------------------------------------------------------------- messages
  ChatMessage addMessage(ChatMessage m) {
    db.execute(
      'INSERT INTO messages (campaign_id, session_id, role, speaker, content, thinking, ts) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [m.campaignId, m.sessionId, m.role.name, m.speaker, m.content, m.thinking, m.ts.toIso8601String()],
    );
    m.id = db.lastInsertRowId;
    db.execute('UPDATE campaigns SET updated_at = ? WHERE id = ?', [_now(), m.campaignId]);
    return m;
  }

  void updateMessage(ChatMessage m) => db.execute(
        'UPDATE messages SET content = ?, thinking = ?, speaker = ? WHERE id = ?',
        [m.content, m.thinking, m.speaker, m.id],
      );

  void deleteMessage(int id) => db.execute('DELETE FROM messages WHERE id = ?', [id]);

  List<ChatMessage> messagesForSession(int sessionId) => db
      .select('SELECT * FROM messages WHERE session_id = ? ORDER BY id', [sessionId])
      .map(ChatMessage.fromRow)
      .toList();

  List<ChatMessage> recentMessages(int campaignId, {int limit = 40}) => db
      .select('SELECT * FROM messages WHERE campaign_id = ? ORDER BY id DESC LIMIT ?', [campaignId, limit])
      .map(ChatMessage.fromRow)
      .toList()
      .reversed
      .toList();

  int messageCount(int campaignId) =>
      db.select('SELECT COUNT(*) AS n FROM messages WHERE campaign_id = ?', [campaignId]).first['n'] as int;

  // ------------------------------------------------------------------- npcs
  List<Npc> npcs(int campaignId) => db
      .select('SELECT * FROM npcs WHERE campaign_id = ? ORDER BY name COLLATE NOCASE', [campaignId])
      .map(Npc.fromRow)
      .toList();

  Npc? npcByName(int campaignId, String name) {
    final r = db.select('SELECT * FROM npcs WHERE campaign_id = ? AND name = ? COLLATE NOCASE', [campaignId, name]);
    return r.isEmpty ? null : Npc.fromRow(r.first);
  }

  Npc upsertNpc(Npc n) {
    final existing = npcByName(n.campaignId, n.name);
    if (existing != null) {
      n.id = existing.id;
      db.execute(
        'UPDATE npcs SET description = ?, voice_hint = ?, voice = ?, goal = ? WHERE id = ?',
        [
          n.description.isEmpty ? existing.description : n.description,
          n.voiceHint.isEmpty ? existing.voiceHint : n.voiceHint,
          n.voice.encode(),
          n.goal.isEmpty ? existing.goal : n.goal,
          n.id,
        ],
      );
      n
        ..attitude = existing.attitude
        ..knows = existing.knows
        ..lastSeen = existing.lastSeen
        ..goal = n.goal.isEmpty ? existing.goal : n.goal;
      return n;
    }
    db.execute(
      'INSERT INTO npcs (campaign_id, name, description, voice_hint, voice, goal, attitude, knows, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [n.campaignId, n.name, n.description, n.voiceHint, n.voice.encode(), n.goal, n.attitude, jsonEncode(n.knows), n.lastSeen],
    );
    n.id = db.lastInsertRowId;
    return n;
  }

  /// Guarda lo que cambia durante la partida: objetivo, actitud y recuerdos.
  void updateNpcState(Npc n) => db.execute(
        'UPDATE npcs SET goal = ?, attitude = ?, knows = ?, last_seen = ? WHERE id = ?',
        [n.goal, n.attitude.clamp(-3, 3), jsonEncode(n.knows), n.lastSeen, n.id],
      );

  void deleteNpc(int id) => db.execute('DELETE FROM npcs WHERE id = ?', [id]);

  // ------------------------------------------------------------------ graph
  static String normalize(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñç';
    const to = 'aaaaeeeeiiiioooouuuunc';
    final lower = s.toLowerCase().trim();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString().replaceAll(RegExp(r'\s+'), ' ');
  }

  Entity upsertEntity(int campaignId, String name, {String type = 'otro', String description = ''}) {
    final norm = normalize(name);
    final r = db.select('SELECT * FROM entities WHERE campaign_id = ? AND norm = ?', [campaignId, norm]);
    if (r.isNotEmpty) {
      final e = Entity.fromRow(r.first);
      var changed = false;
      if (description.isNotEmpty && !e.description.contains(description)) {
        e.description = e.description.isEmpty ? description : '${e.description} $description';
        if (e.description.length > 1200) e.description = e.description.substring(e.description.length - 1200);
        changed = true;
      }
      if (type != 'otro' && e.type == 'otro') {
        e.type = type;
        changed = true;
      }
      if (changed) {
        db.execute('UPDATE entities SET description = ?, type = ? WHERE id = ?', [e.description, e.type, e.id]);
      }
      return e;
    }
    db.execute(
      'INSERT INTO entities (campaign_id, name, norm, type, description) VALUES (?, ?, ?, ?, ?)',
      [campaignId, name.trim(), norm, type, description],
    );
    return Entity(id: db.lastInsertRowId, campaignId: campaignId, name: name.trim(), type: type, description: description);
  }

  void updateEntity(Entity e) => db.execute(
        'UPDATE entities SET name = ?, norm = ?, type = ?, description = ? WHERE id = ?',
        [e.name, normalize(e.name), e.type, e.description, e.id],
      );

  void deleteEntity(int id) => db.execute('DELETE FROM entities WHERE id = ?', [id]);

  List<Entity> entities(int campaignId) => db
      .select('SELECT * FROM entities WHERE campaign_id = ? ORDER BY type, name COLLATE NOCASE', [campaignId])
      .map(Entity.fromRow)
      .toList();

  /// Añade un hecho. Si ya existía pero había caducado, vuelve a ser cierto.
  /// Devuelve el id de la relación (o null si no es válida).
  int? addRelation(int campaignId, int sourceId, String relation, int targetId, {int session = 0}) {
    if (sourceId == targetId || relation.trim().isEmpty) return null;
    final r = db.select(
      'SELECT id, ended FROM relations WHERE campaign_id = ? AND source_id = ? AND relation = ? AND target_id = ?',
      [campaignId, sourceId, relation.trim(), targetId],
    );
    if (r.isNotEmpty) {
      final id = r.first['id'] as int;
      if (r.first['ended'] == 1) {
        db.execute('UPDATE relations SET ended = 0, since_session = ?, until_session = 0 WHERE id = ?', [session, id]);
      }
      return id;
    }
    db.execute(
      'INSERT INTO relations (campaign_id, source_id, relation, target_id, since_session) VALUES (?, ?, ?, ?, ?)',
      [campaignId, sourceId, relation.trim(), targetId, session],
    );
    return db.lastInsertRowId;
  }

  /// Marca un hecho como pasado: ya no es cierto, pero se recuerda que lo fue.
  void endRelation(int id, {int session = 0}) =>
      db.execute('UPDATE relations SET ended = 1, until_session = ? WHERE id = ? AND ended = 0', [session, id]);

  void reopenRelation(int id) => db.execute('UPDATE relations SET ended = 0, until_session = 0 WHERE id = ?', [id]);

  void deleteRelation(int id) => db.execute('DELETE FROM relations WHERE id = ?', [id]);

  /// Hechos del grafo. [ended]: null = todos, false = vigentes, true = pasados.
  List<Relation> relations(int campaignId, {Iterable<int>? touching, bool? ended}) {
    var sql = 'SELECT r.*, s.name AS sname, t.name AS tname FROM relations r '
        'JOIN entities s ON s.id = r.source_id JOIN entities t ON t.id = r.target_id WHERE r.campaign_id = ?';
    final args = <Object?>[campaignId];
    if (ended != null) sql += ' AND r.ended = ${ended ? 1 : 0}';
    if (touching != null) {
      final ids = touching.toList();
      if (ids.isEmpty) return const [];
      final q = List.filled(ids.length, '?').join(',');
      sql += ' AND (r.source_id IN ($q) OR r.target_id IN ($q))';
      args
        ..addAll(ids)
        ..addAll(ids);
    }
    return db
        .select(sql, args)
        .map((r) => Relation(
              id: r['id'] as int,
              campaignId: campaignId,
              sourceId: r['source_id'] as int,
              relation: r['relation'] as String,
              targetId: r['target_id'] as int,
              sourceName: r['sname'] as String,
              targetName: r['tname'] as String,
              ended: r['ended'] == 1,
              sinceSession: (r['since_session'] as int?) ?? 0,
              untilSession: (r['until_session'] as int?) ?? 0,
            ))
        .toList();
  }

  // ------------------------------------------------------- estado de juego
  List<CharacterState> charStates(int campaignId) => db
      .select('SELECT * FROM char_states WHERE campaign_id = ? ORDER BY id', [campaignId])
      .map((r) => CharacterState.fromJson(campaignId, r['name'] as String, _json(r['data'] as String?), id: r['id'] as int))
      .toList();

  CharacterState? charState(int campaignId, String name) {
    final r = db.select('SELECT * FROM char_states WHERE campaign_id = ? AND norm = ?', [campaignId, normalize(name)]);
    if (r.isEmpty) return null;
    return CharacterState.fromJson(campaignId, r.first['name'] as String, _json(r.first['data'] as String?), id: r.first['id'] as int);
  }

  CharacterState saveCharState(CharacterState c) {
    final data = jsonEncode(c.toJson());
    if (c.id != null) {
      db.execute('UPDATE char_states SET name = ?, norm = ?, data = ? WHERE id = ?', [c.name, normalize(c.name), data, c.id]);
    } else {
      db.execute(
        'INSERT INTO char_states (campaign_id, name, norm, data) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(campaign_id, norm) DO UPDATE SET data = excluded.data, name = excluded.name',
        [c.campaignId, c.name, normalize(c.name), data],
      );
      c.id = db.select('SELECT id FROM char_states WHERE campaign_id = ? AND norm = ?', [c.campaignId, normalize(c.name)]).first['id'] as int;
    }
    return c;
  }

  void deleteCharState(int id) => db.execute('DELETE FROM char_states WHERE id = ?', [id]);

  static Map<String, dynamic> _json(String? s) {
    if (s == null || s.isEmpty) return {};
    try {
      final v = jsonDecode(s);
      return v is Map ? v.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  // ----------------------------------------------------- recuerdos fijados
  List<PinnedMemory> pins(int campaignId) => db
      .select('SELECT * FROM pins WHERE campaign_id = ? ORDER BY id', [campaignId])
      .map(PinnedMemory.fromRow)
      .toList();

  PinnedMemory addPin(PinnedMemory p) {
    db.execute('INSERT INTO pins (campaign_id, text, created_at) VALUES (?, ?, ?)',
        [p.campaignId, p.text, p.createdAt.toIso8601String()]);
    p.id = db.lastInsertRowId;
    return p;
  }

  void updatePin(PinnedMemory p) => db.execute('UPDATE pins SET text = ? WHERE id = ?', [p.text, p.id]);
  void deletePin(int id) => db.execute('DELETE FROM pins WHERE id = ?', [id]);

  // ------------------------------------------------------ asuntos pendientes
  List<PlotThread> plotThreads(int campaignId, {bool? open}) => db
      .select(
        'SELECT * FROM plot_threads WHERE campaign_id = ?${open == null ? '' : ' AND open = ${open ? 1 : 0}'} ORDER BY open DESC, id',
        [campaignId],
      )
      .map(PlotThread.fromRow)
      .toList();

  /// Añade un asunto si no hay ya uno abierto igual. Devuelve null si existía.
  PlotThread? addPlotThread(PlotThread t) {
    final norm = normalize(t.text);
    if (norm.isEmpty) return null;
    final dup = db.select('SELECT id FROM plot_threads WHERE campaign_id = ? AND norm = ? AND open = 1', [t.campaignId, norm]);
    if (dup.isNotEmpty) return null;
    db.execute(
      'INSERT INTO plot_threads (campaign_id, kind, text, norm, open, session, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [t.campaignId, t.kind, t.text, norm, t.open ? 1 : 0, t.session, t.createdAt.toIso8601String()],
    );
    t.id = db.lastInsertRowId;
    return t;
  }

  void updatePlotThread(PlotThread t) => db.execute(
        'UPDATE plot_threads SET kind = ?, text = ?, norm = ?, open = ? WHERE id = ?',
        [t.kind, t.text, normalize(t.text), t.open ? 1 : 0, t.id],
      );

  void deletePlotThread(int id) => db.execute('DELETE FROM plot_threads WHERE id = ?', [id]);

  // ---------------------------------------------------------- relojes del mundo
  List<WorldClock> clocks(int campaignId, {bool onlyActive = false}) => db
      .select('SELECT * FROM world_clocks WHERE campaign_id = ?${onlyActive ? ' AND active = 1' : ''} ORDER BY id', [campaignId])
      .map(WorldClock.fromRow)
      .toList();

  WorldClock saveClock(WorldClock c) {
    if (c.id == null) {
      db.execute(
        'INSERT INTO world_clocks (campaign_id, name, owner, segments, filled, consequence, active, stance) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [c.campaignId, c.name, c.owner, c.segments, c.filled, c.consequence, c.active ? 1 : 0, c.stance],
      );
      c.id = db.lastInsertRowId;
    } else {
      db.execute(
        'UPDATE world_clocks SET name = ?, owner = ?, segments = ?, filled = ?, consequence = ?, active = ?, stance = ? WHERE id = ?',
        [c.name, c.owner, c.segments, c.filled, c.consequence, c.active ? 1 : 0, c.stance, c.id],
      );
    }
    return c;
  }

  void deleteClock(int id) => db.execute('DELETE FROM world_clocks WHERE id = ?', [id]);

  // ------------------------------------------------------------------ chunks
  static Uint8List encodeVector(List<double> v) => Float32List.fromList(v).buffer.asUint8List();
  static List<double> decodeVector(Uint8List b) =>
      Float32List.view(Uint8List.fromList(b).buffer, 0, b.lengthInBytes ~/ 4).toList();

  LoreChunk addChunk(LoreChunk c) {
    db.execute(
      'INSERT INTO chunks (campaign_id, source, text, embedding) VALUES (?, ?, ?, ?)',
      [c.campaignId, c.source, c.text, c.embedding == null ? null : encodeVector(c.embedding!)],
    );
    c.id = db.lastInsertRowId;
    return c;
  }

  void setChunkEmbedding(int id, List<double> v) =>
      db.execute('UPDATE chunks SET embedding = ? WHERE id = ?', [encodeVector(v), id]);

  List<LoreChunk> chunks(int campaignId) => db
      .select('SELECT * FROM chunks WHERE campaign_id = ?', [campaignId])
      .map((r) => LoreChunk(
            id: r['id'] as int,
            campaignId: campaignId,
            source: r['source'] as String,
            text: r['text'] as String,
            embedding: r['embedding'] == null ? null : decodeVector(r['embedding'] as Uint8List),
          ))
      .toList();

  int chunkCount(int campaignId, {bool onlyMissingEmbedding = false}) => db.select(
        'SELECT COUNT(*) AS n FROM chunks WHERE campaign_id = ?${onlyMissingEmbedding ? ' AND embedding IS NULL' : ''}',
        [campaignId],
      ).first['n'] as int;

  // ----------------------------------------------------------- documentación
  DocumentRecord addDocument(DocumentRecord d) {
    db.execute(
      'INSERT INTO documents (campaign_id, title, path, kind, chars, added_at) VALUES (?, ?, ?, ?, ?, ?)',
      [d.campaignId, d.title, _store(d.path), d.kind, d.chars, d.addedAt.toIso8601String()],
    );
    d.id = db.lastInsertRowId;
    return d;
  }

  /// Todos los documentos, o los que ve una campaña (los globales y los suyos).
  List<DocumentRecord> documents({int? campaignId, bool all = true}) => db
      .select(
        'SELECT d.*, (SELECT COUNT(*) FROM doc_chunks c WHERE c.doc_id = d.id) AS n, '
        '(SELECT COUNT(*) FROM doc_chunks c WHERE c.doc_id = d.id AND c.embedding IS NULL) AS pending '
        'FROM documents d ${all ? '' : 'WHERE d.campaign_id IS NULL OR d.campaign_id = ?'} ORDER BY d.added_at DESC',
        all ? const [] : [campaignId],
      )
      .map((r) => DocumentRecord.fromRow(r, path: _resolve(r['path'] as String)))
      .toList();

  void deleteDocument(int id) => db.execute('DELETE FROM documents WHERE id = ?', [id]);

  void addDocChunks(int docId, List<String> texts, List<List<double>?> embeddings) {
    final st = db.prepare('INSERT INTO doc_chunks (doc_id, text, embedding) VALUES (?, ?, ?)');
    final own = db.autocommit; // si ya hay una transacción abierta, se usa esa
    if (own) db.execute('BEGIN');
    try {
      for (var i = 0; i < texts.length; i++) {
        final e = i < embeddings.length ? embeddings[i] : null;
        st.execute([docId, texts[i], e == null ? null : encodeVector(e)]);
      }
      if (own) db.execute('COMMIT');
    } catch (_) {
      if (own) db.execute('ROLLBACK');
      rethrow;
    } finally {
      st.close();
    }
  }

  /// Fragmentos de documentación visibles para una campaña (null = sólo los globales),
  /// con el formato de la memoria RAG.
  List<LoreChunk> docChunks(int? campaignId, {bool onlyMissingEmbedding = false}) => db
      .select(
        'SELECT c.id, c.text, c.embedding, d.title FROM doc_chunks c JOIN documents d ON d.id = c.doc_id '
        'WHERE (d.campaign_id IS NULL OR d.campaign_id = ?)${onlyMissingEmbedding ? ' AND c.embedding IS NULL' : ''}',
        [campaignId ?? -1],
      )
      .map((r) => LoreChunk(
            id: r['id'] as int,
            campaignId: campaignId ?? 0,
            source: 'doc · ${r['title']}',
            text: r['text'] as String,
            embedding: r['embedding'] == null ? null : decodeVector(r['embedding'] as Uint8List),
          ))
      .toList();

  List<LoreChunk> allDocChunksMissingEmbedding() => db
      .select('SELECT id, text FROM doc_chunks WHERE embedding IS NULL')
      .map((r) => LoreChunk(id: r['id'] as int, campaignId: 0, source: 'doc', text: r['text'] as String))
      .toList();

  void setDocChunkEmbedding(int id, List<double> v) =>
      db.execute('UPDATE doc_chunks SET embedding = ? WHERE id = ?', [encodeVector(v), id]);

  // ------------------------------------------------------------------- music
  List<Situation> situations() =>
      db.select('SELECT * FROM situations ORDER BY sort_order, id').map(Situation.fromRow).toList();

  Situation addSituation(String name, String icon) {
    final maxOrder = db.select('SELECT COALESCE(MAX(sort_order), 0) AS m FROM situations').first['m'] as int;
    db.execute('INSERT OR IGNORE INTO situations (name, icon, sort_order) VALUES (?, ?, ?)', [name, icon, maxOrder + 1]);
    return Situation.fromRow(db.select('SELECT * FROM situations WHERE name = ?', [name]).first);
  }

  void updateSituation(Situation s) =>
      db.execute('UPDATE situations SET name = ?, icon = ? WHERE id = ?', [s.name, s.icon, s.id]);

  void deleteSituation(int id) => db.execute('DELETE FROM situations WHERE id = ?', [id]);

  List<Track> tracks({int? situationId}) => (situationId == null
          ? db.select('SELECT * FROM tracks ORDER BY title COLLATE NOCASE')
          : db.select('SELECT * FROM tracks WHERE situation_id = ? ORDER BY title COLLATE NOCASE', [situationId]))
      .map(Track.fromRow)
      .toList();

  Track addTrack(Track t) {
    final existing = db.select('SELECT * FROM tracks WHERE path = ?', [t.path]);
    if (existing.isNotEmpty) return Track.fromRow(existing.first);
    db.execute('INSERT INTO tracks (path, title, situation_id, volume) VALUES (?, ?, ?, ?)', [t.path, t.title, t.situationId, t.volume]);
    t.id = db.lastInsertRowId;
    return t;
  }

  void updateTrack(Track t) => db.execute(
        'UPDATE tracks SET path = ?, title = ?, situation_id = ?, volume = ? WHERE id = ?',
        [t.path, t.title, t.situationId, t.volume, t.id],
      );

  void deleteTrack(int id) => db.execute('DELETE FROM tracks WHERE id = ?', [id]);

  // -------------------------------------------------------------------- maps
  MapRecord addMap(MapRecord m) {
    db.execute(
      'INSERT INTO maps (campaign_id, title, kind, seed, image_path, key_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [m.campaignId, m.title, m.kind, m.seed, _store(m.imagePath), m.keyJson, m.createdAt.toIso8601String()],
    );
    m.id = db.lastInsertRowId;
    return m;
  }

  void updateMapKey(int id, String keyJson) => db.execute('UPDATE maps SET key_json = ? WHERE id = ?', [keyJson, id]);

  List<MapRecord> maps({int? campaignId}) => (campaignId == null
          ? db.select('SELECT * FROM maps ORDER BY id DESC')
          : db.select('SELECT * FROM maps WHERE campaign_id = ? ORDER BY id DESC', [campaignId]))
      .map(MapRecord.fromRow)
      .map((m) => m..imagePath = _resolve(m.imagePath))
      .toList();

  void deleteMap(int id) => db.execute('DELETE FROM maps WHERE id = ?', [id]);
}
