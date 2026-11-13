import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';

/// Exporta e importa historias completas en un único fichero `.rolpack`
/// (un ZIP con `historia.json` y las imágenes de los mapas).
///
/// Incluye la biblia de campaña, jugadores y personajes, PNJ con sus voces,
/// grafo de conocimiento, memoria RAG y mapas. Con [includeProgress] también
/// van las sesiones jugadas, los registros y la memoria del director; sin él
/// se exporta sólo la historia, lista para que otro grupo la empiece de cero.
class StoryPackage {
  static const format = 'director-de-rol/historia';
  static const version = 1;
  static const extension = 'rolpack';
  static const _memoryPointerKey = '_memoryUpTo';

  static Uint8List export(AppDatabase db, int campaignId, {bool includeProgress = true}) {
    final c = db.campaign(campaignId)!;
    final archive = Archive();
    final bible = Map<String, dynamic>.from(c.bible);
    if (!includeProgress) bible.remove(_memoryPointerKey);

    final maps = <Map<String, dynamic>>[];
    for (final m in db.maps(campaignId: campaignId)) {
      final f = File(m.imagePath);
      String? image;
      if (f.existsSync()) {
        image = 'mapas/${m.id}_${p.basename(m.imagePath)}';
        archive.addFile(ArchiveFile.bytes(image, f.readAsBytesSync()));
      }
      maps.add({
        'title': m.title,
        'kind': m.kind,
        'seed': m.seed,
        'key': m.roomKey,
        'createdAt': m.createdAt.toIso8601String(),
        'image': image,
      });
    }

    final json = <String, dynamic>{
      'format': format,
      'version': version,
      'exportedAt': DateTime.now().toIso8601String(),
      'includesProgress': includeProgress,
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
        for (final n in db.npcs(campaignId))
          {'name': n.name, 'description': n.description, 'voiceHint': n.voiceHint, 'voice': n.voice.toJson()},
      ],
      'entities': [
        for (final e in db.entities(campaignId)) {'name': e.name, 'type': e.type, 'description': e.description},
      ],
      'relations': [
        for (final r in db.relations(campaignId)) {'source': r.sourceName, 'relation': r.relation, 'target': r.targetName},
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
    };
    archive.addFile(ArchiveFile.string('historia.json', const JsonEncoder.withIndent(' ').convert(json)));
    return ZipEncoder().encodeBytes(archive);
  }

  /// Lee la cabecera de un paquete sin importarlo (para mostrar qué contiene).
  static Map<String, dynamic> peek(Uint8List bytes) => _read(bytes).$1;

  static (Map<String, dynamic>, Archive) _read(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final f = archive.findFile('historia.json');
    if (f == null) throw const FormatException('El fichero no es una historia de Director de Rol');
    final json = (jsonDecode(utf8.decode(f.content)) as Map).cast<String, dynamic>();
    if (json['format'] != format) throw const FormatException('Formato de historia desconocido');
    if ((json['version'] as num? ?? 0) > version) {
      throw const FormatException('La historia es de una versión más nueva de la app');
    }
    return (json, archive);
  }

  /// Importa la historia como una campaña nueva. Devuelve la campaña creada.
  static Campaign import(AppDatabase db, Uint8List bytes, {required String mapsDir}) {
    final (json, archive) = _read(bytes);
    final cj = (json['campaign'] as Map).cast<String, dynamic>();
    final existing = db.campaigns().map((c) => c.title).toSet();
    var title = (cj['title'] ?? 'Historia importada').toString();
    if (existing.contains(title)) title = '$title (importada)';

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
        ));
      }
      for (final e in _maps(json['entities'])) {
        db.upsertEntity(id, (e['name'] ?? '').toString(),
            type: (e['type'] ?? 'otro').toString(), description: (e['description'] ?? '').toString());
      }
      for (final r in _maps(json['relations'])) {
        final s = db.upsertEntity(id, (r['source'] ?? '').toString());
        final t = db.upsertEntity(id, (r['target'] ?? '').toString());
        db.addRelation(id, s.id!, (r['relation'] ?? '').toString(), t.id!);
      }
      for (final ch in _maps(json['chunks'])) {
        final emb = ch['embedding'];
        db.addChunk(LoreChunk(
          campaignId: id,
          source: (ch['source'] ?? '').toString(),
          text: (ch['text'] ?? '').toString(),
          embedding: emb is String ? AppDatabase.decodeVector(base64Decode(emb)) : null,
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
        final dest = p.join(mapsDir, 'importado_${DateTime.now().microsecondsSinceEpoch}_${p.basename(image as String)}');
        File(dest).writeAsBytesSync(file.content);
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
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      db.deleteCampaign(id);
      rethrow;
    }
    return db.campaign(id)!;
  }

  static Iterable<Map<String, dynamic>> _maps(Object? v) =>
      v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()) : const [];
}
