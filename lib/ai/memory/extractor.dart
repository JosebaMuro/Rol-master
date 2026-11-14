import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import '../../core/models.dart';
import '../llm.dart';
import 'graph.dart';

/// Lo que ha aprendido el archivista en un turno.
class ExtractionResult {
  int facts = 0;
  int ended = 0;
  final List<String> notes = [];
}

/// Tras cada turno, pide a la IA que extraiga hechos nuevos (entidades y
/// relaciones), los que han dejado de ser ciertos, los asuntos pendientes y
/// cómo cambian los PNJ.
class MemoryExtractor {
  MemoryExtractor(this.db, this.llm, this.graph);
  final AppDatabase db;
  final TextGenerator llm;
  final KnowledgeGraph graph;

  static const _triple = {
    'type': 'object',
    'properties': {
      'source': {'type': 'string'},
      'relation': {'type': 'string'},
      'target': {'type': 'string'},
    },
    'required': ['source', 'relation', 'target'],
  };

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
      'relations': {'type': 'array', 'items': _triple},
      'ended_relations': {'type': 'array', 'items': _triple},
      'threads_opened': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'kind': {'type': 'string', 'enum': PlotThread.kinds},
            'text': {'type': 'string'},
          },
          'required': ['kind', 'text'],
        },
      },
      'threads_closed': {'type': 'array', 'items': {'type': 'integer'}},
      'npcs': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'attitude_change': {'type': 'integer', 'minimum': -2, 'maximum': 2},
            'goal': {'type': 'string'},
            'learned': {'type': 'string'},
          },
          'required': ['name', 'attitude_change', 'goal', 'learned'],
        },
      },
    },
    'required': ['entities', 'relations', 'ended_relations', 'threads_opened', 'threads_closed', 'npcs'],
  };

  Future<ExtractionResult> extract(
    int campaignId,
    String playerText,
    String gmText, {
    int session = 0,
    int messageId = 0,
    Iterable<String> present = const [],
  }) async {
    final out = ExtractionResult();
    if (!llm.isReady) return out;
    final open = db.plotThreads(campaignId, open: true);
    final presentNpcs = [for (final n in present) db.npcByName(campaignId, n)].whereType<Npc>().toList();
    try {
      final r = await llm.json(
        [
          const LlmMessage.system(
            'Eres el archivista de una partida de rol. Del último intercambio extraes, sin inventar nada:\n'
            '- entities y relations: hechos NUEVOS y concretos para un grafo de conocimiento. Nombres propios tal y '
            'como aparecen. Relaciones con verbos cortos en español ("está en", "odia a", "posee", "busca", '
            '"es aliado de", "murió en"). Descripciones de una frase.\n'
            '- ended_relations: hechos que ERAN ciertos y han dejado de serlo (alguien se marchó, perdió o entregó '
            'algo, rompió una alianza, murió).\n'
            '- threads_opened: promesas, deudas, amenazas, misiones o pistas NUEVAS que quedan pendientes.\n'
            '- threads_closed: números de los asuntos pendientes que se han cumplido o resuelto.\n'
            '- npcs: para cada PNJ que intervino, attitude_change hacia el grupo (de -2 a 2, 0 si nada cambió), '
            'su objetivo si se ha revelado o cambiado ("" si no) y learned: lo que ha visto u oído en persona '
            'en una frase ("" si nada).\n'
            'Si no hay nada nuevo devuelve listas vacías.',
          ),
          LlmMessage.user(
            '${open.isEmpty ? '' : 'ASUNTOS PENDIENTES:\n${[for (var i = 0; i < open.length; i++) '${i + 1}. ${open[i].text}'].join('\n')}\n\n'}'
            '${presentNpcs.isEmpty ? '' : 'PNJ QUE INTERVIENEN: ${presentNpcs.map((n) => n.name).join(', ')}\n\n'}'
            'JUGADORES: $playerText\n\nDIRECTOR: $gmText',
          ),
        ],
        schema: schema,
        maxTokens: 900,
        temperature: 0.2,
      );
      for (final e in _maps(r['entities'])) {
        final name = _s(e['name']);
        if (name.isEmpty || name.length > 60) continue;
        graph.addEntity(campaignId, name, type: _s(e['type']).isEmpty ? 'otro' : _s(e['type']), description: _s(e['description']));
        out.facts++;
      }
      for (final rel in _maps(r['ended_relations'])) {
        if (graph.endFact(campaignId, _s(rel['source']), _s(rel['relation']), _s(rel['target']), session: session)) {
          out.ended++;
          out.notes.add('Ya no: ${_s(rel['source'])} ${_s(rel['relation'])} ${_s(rel['target'])}');
        }
      }
      for (final rel in _maps(r['relations'])) {
        graph.addFact(campaignId, _s(rel['source']), _s(rel['relation']), _s(rel['target']), session: session);
        out.facts++;
      }
      for (final n in (r['threads_closed'] as List? ?? const [])) {
        final i = (n is num ? n.toInt() : int.tryParse('$n') ?? 0) - 1;
        if (i < 0 || i >= open.length || !open[i].open) continue;
        open[i].open = false;
        db.updatePlotThread(open[i]);
        out.notes.add('${open[i].icon} Resuelto: ${open[i].text}');
      }
      for (final t in _maps(r['threads_opened'])) {
        final text = _s(t['text']);
        if (text.isEmpty || text.length > 200) continue;
        final kind = PlotThread.kinds.contains(_s(t['kind'])) ? _s(t['kind']) : 'pendiente';
        final added = db.addPlotThread(PlotThread(campaignId: campaignId, kind: kind, text: text, session: session));
        if (added != null) out.notes.add('${added.icon} Nuevo ${added.kind}: ${added.text}');
      }
      for (final u in _maps(r['npcs'])) {
        final npc = db.npcByName(campaignId, _s(u['name']));
        if (npc == null) continue;
        var changed = false;
        final delta = (u['attitude_change'] is num ? (u['attitude_change'] as num).toInt() : 0).clamp(-2, 2);
        if (delta != 0) {
          final before = npc.attitude;
          npc.attitude = (npc.attitude + delta).clamp(-3, 3);
          if (npc.attitude != before) {
            changed = true;
            out.notes.add('${npc.name} ahora es ${npc.attitudeName} con el grupo');
          }
        }
        final goal = _s(u['goal']);
        if (goal.isNotEmpty && goal.length < 200 && goal != npc.goal) {
          npc.goal = goal;
          changed = true;
        }
        final learned = _s(u['learned']);
        if (learned.isNotEmpty && learned.length < 240) {
          npc.knows = [...npc.knows, session > 0 ? 'S$session: $learned' : learned];
          if (npc.knows.length > 12) npc.knows = npc.knows.sublist(npc.knows.length - 12);
          changed = true;
        }
        if (changed) db.updateNpcState(npc);
      }
    } catch (e) {
      debugPrint('Extractor de memoria: $e');
    }
    // Quién estaba presente se registra aunque la IA no devuelva nada.
    for (final npc in presentNpcs) {
      final fresh = db.npcByName(campaignId, npc.name);
      if (fresh != null && messageId > 0) {
        fresh.lastSeen = messageId;
        db.updateNpcState(fresh);
      }
    }
    return out;
  }

  static String _s(Object? v) => (v ?? '').toString().trim();
  static Iterable<Map> _maps(Object? v) => v is List ? v.whereType<Map>() : const [];
}
