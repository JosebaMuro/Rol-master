import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import '../llm.dart';
import 'graph.dart';

/// Tras cada turno, pide a la IA que extraiga hechos nuevos (entidades y
/// relaciones) para alimentar el grafo de conocimiento.
class MemoryExtractor {
  MemoryExtractor(this.db, this.llm, this.graph);
  final AppDatabase db;
  final TextGenerator llm;
  final KnowledgeGraph graph;

  static const schema = {
    'type': 'object',
    'properties': {
      'entities': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'type': {
              'type': 'string',
              'enum': ['personaje', 'pnj', 'lugar', 'facción', 'objeto', 'misión', 'criatura', 'evento', 'otro'],
            },
            'description': {'type': 'string'},
          },
          'required': ['name', 'type', 'description'],
        },
      },
      'relations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'source': {'type': 'string'},
            'relation': {'type': 'string'},
            'target': {'type': 'string'},
          },
          'required': ['source', 'relation', 'target'],
        },
      },
    },
    'required': ['entities', 'relations'],
  };

  Future<int> extract(int campaignId, String playerText, String gmText) async {
    if (!llm.isReady) return 0;
    try {
      final r = await llm.json(
        [
          const LlmMessage.system(
            'Eres el archivista de una partida de rol. Extraes hechos NUEVOS y concretos del último intercambio '
            'para un grafo de conocimiento. Usa nombres propios tal y como aparecen. Las relaciones son verbos '
            'cortos en español ("está en", "odia a", "posee", "busca", "es aliado de", "murió en"). '
            'Las descripciones son de una frase. Si no hay nada nuevo devuelve listas vacías.',
          ),
          LlmMessage.user('JUGADORES: $playerText\n\nDIRECTOR: $gmText'),
        ],
        schema: schema,
        maxTokens: 700,
        temperature: 0.2,
      );
      var n = 0;
      for (final e in (r['entities'] as List? ?? const []).whereType<Map>()) {
        final name = (e['name'] ?? '').toString().trim();
        if (name.isEmpty || name.length > 60) continue;
        graph.addEntity(campaignId, name,
            type: (e['type'] ?? 'otro').toString(), description: (e['description'] ?? '').toString());
        n++;
      }
      for (final rel in (r['relations'] as List? ?? const []).whereType<Map>()) {
        graph.addFact(
          campaignId,
          (rel['source'] ?? '').toString(),
          (rel['relation'] ?? '').toString(),
          (rel['target'] ?? '').toString(),
        );
        n++;
      }
      return n;
    } catch (e) {
      debugPrint('Extractor de memoria: $e');
      return 0;
    }
  }
}
