import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../ai/llm.dart';
import '../core/db.dart';
import '../core/models.dart';
import 'dungeon_generator.dart';
import 'map_renderer.dart';

/// Crea mapas (imagen PNG + leyenda de salas) y los guarda en la biblioteca.
class MapService extends ChangeNotifier {
  MapService(this.db, this.llm, this.mapsDir);
  final AppDatabase db;
  final TextGenerator llm;
  final String mapsDir;

  bool busy = false;

  Future<MapRecord> create({
    required String kind,
    required String title,
    Campaign? campaign,
    int? seed,
    int rooms = 12,
    bool describeWithAi = true,
  }) async {
    busy = true;
    notifyListeners();
    try {
      final k = DungeonGenerator.normalizeKind(kind);
      final s = seed ?? DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
      final map = DungeonGenerator.generate(kind: k, seed: s, rooms: k == 'cueva' ? (rooms / 2).ceil() : rooms);
      final png = await MapRenderer.renderPng(map, title);
      Directory(mapsDir).createSync(recursive: true);
      final safe = title.replaceAll(RegExp(r'[^\w\- ]', unicode: true), '').replaceAll(' ', '_');
      final file = File(p.join(mapsDir, '${safe}_$s.png'));
      await file.writeAsBytes(png);

      var key = <Map<String, dynamic>>[
        for (final r in map.rooms) {'n': r.number, 'title': 'Sala ${r.number}', 'text': ''},
      ];
      if (describeWithAi && llm.isReady) {
        key = await _describe(map, title, k, campaign) ?? key;
      }
      final rec = db.addMap(MapRecord(
        campaignId: campaign?.id,
        title: title,
        kind: k,
        seed: s,
        imagePath: file.path,
        keyJson: jsonEncode(key),
      ));
      return rec;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>?> _describe(DungeonMap map, String title, String kind, Campaign? c) async {
    final links = map.links.map((l) => '${map.rooms[l.$1].number}-${map.rooms[l.$2].number}').join(', ');
    try {
      final r = await llm.json(
        [
          const LlmMessage.system(
            'Eres un diseñador de aventuras de rol. Escribes leyendas de mapas: cada sala con un título evocador y '
            '2-3 frases (qué se ve, qué peligro o tesoro hay, qué pista contiene). En español.',
          ),
          LlmMessage.user(
            'Mapa: "$title" (tipo $kind) con ${map.rooms.length} salas numeradas. Conexiones: $links. '
            'La sala 1 es la entrada y la ${map.rooms.length} la más profunda.'
            '${c == null ? '' : '\nCampaña: ${c.title}. ${c.premise}\nLugar actual: ${c.location}'}',
          ),
        ],
        schema: {
          'type': 'object',
          'properties': {
            'rooms': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'n': {'type': 'integer'},
                  'title': {'type': 'string'},
                  'text': {'type': 'string'},
                },
                'required': ['n', 'title', 'text'],
              },
            },
          },
          'required': ['rooms'],
        },
        maxTokens: 1800,
        temperature: 0.8,
      );
      final rooms = (r['rooms'] as List?)?.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      return (rooms == null || rooms.isEmpty) ? null : rooms;
    } catch (e) {
      debugPrint('Leyenda del mapa: $e');
      return null;
    }
  }

  void delete(MapRecord m) {
    try {
      File(m.imagePath).deleteSync();
    } catch (_) {}
    db.deleteMap(m.id!);
    notifyListeners();
  }
}
