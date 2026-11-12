import '../../core/db.dart';
import '../../core/models.dart';

/// Grafo de conocimiento de la campaña: personajes, lugares, facciones,
/// objetos y misiones, unidos por relaciones ("odia a", "está en"...).
/// El director lo consulta para no contradecirse y lo actualiza tras cada
/// turno.
class KnowledgeGraph {
  KnowledgeGraph(this.db);
  final AppDatabase db;

  static const types = ['personaje', 'pnj', 'lugar', 'facción', 'objeto', 'misión', 'criatura', 'evento', 'otro'];

  Entity addEntity(int campaignId, String name, {String type = 'otro', String description = ''}) =>
      db.upsertEntity(campaignId, name, type: _normType(type), description: description);

  void addFact(int campaignId, String source, String relation, String target,
      {String sourceType = 'otro', String targetType = 'otro'}) {
    if (source.trim().isEmpty || target.trim().isEmpty || relation.trim().isEmpty) return;
    final s = addEntity(campaignId, source, type: sourceType);
    final t = addEntity(campaignId, target, type: targetType);
    db.addRelation(campaignId, s.id!, relation, t.id!);
  }

  String _normType(String t) {
    final n = AppDatabase.normalize(t);
    for (final k in types) {
      if (AppDatabase.normalize(k) == n) return k;
    }
    if (n.contains('person') || n.contains('heroe') || n.contains('jugador')) return 'personaje';
    if (n.contains('npc') || n.contains('pnj')) return 'pnj';
    if (n.contains('lug') || n.contains('ciudad') || n.contains('region')) return 'lugar';
    if (n.contains('faccion') || n.contains('gremio') || n.contains('orden')) return 'facción';
    if (n.contains('obj') || n.contains('arma') || n.contains('artefacto')) return 'objeto';
    if (n.contains('mision') || n.contains('quest')) return 'misión';
    if (n.contains('monstruo') || n.contains('criatura') || n.contains('bestia')) return 'criatura';
    return 'otro';
  }

  /// Entidades mencionadas en [text] (por nombre completo o por una palabra
  /// distintiva del nombre).
  List<Entity> mentionedIn(int campaignId, String text) {
    final norm = AppDatabase.normalize(text);
    final words = norm.split(RegExp(r'[^a-z0-9]+')).toSet();
    final out = <Entity>[];
    for (final e in db.entities(campaignId)) {
      final en = AppDatabase.normalize(e.name);
      if (en.length > 2 && norm.contains(en)) {
        out.add(e);
        continue;
      }
      final parts = en.split(' ').where((p) => p.length > 3 && !_generic.contains(p));
      if (parts.any(words.contains)) out.add(e);
    }
    return out;
  }

  /// Contexto textual para el prompt: entidades relevantes y sus relaciones
  /// a uno o dos saltos.
  String contextFor(int campaignId, String text, {int maxFacts = 30, int hops = 2}) {
    final seeds = mentionedIn(campaignId, text);
    if (seeds.isEmpty) return '';
    final all = {for (final e in db.entities(campaignId)) e.id!: e};
    final visited = <int>{for (final e in seeds) e.id!};
    var frontier = visited.toSet();
    final facts = <Relation>[];
    for (var h = 0; h < hops && frontier.isNotEmpty; h++) {
      final rels = db.relations(campaignId, touching: frontier);
      final next = <int>{};
      for (final r in rels) {
        if (!facts.any((f) => f.id == r.id)) facts.add(r);
        for (final id in [r.sourceId, r.targetId]) {
          if (visited.add(id)) next.add(id);
        }
      }
      frontier = next;
    }
    final b = StringBuffer();
    for (final e in seeds.take(12)) {
      b.writeln('- ${e.name} (${e.type})${e.description.isEmpty ? '' : ': ${_short(e.description, 220)}'}');
    }
    final extra = visited.difference({for (final e in seeds) e.id!}).take(8);
    for (final id in extra) {
      final e = all[id];
      if (e != null && e.description.isNotEmpty) b.writeln('- ${e.name} (${e.type}): ${_short(e.description, 140)}');
    }
    if (facts.isNotEmpty) {
      b.writeln('Relaciones conocidas:');
      for (final r in facts.take(maxFacts)) {
        b.writeln('- ${r.sourceName} → ${r.relation} → ${r.targetName}');
      }
    }
    return b.toString().trim();
  }

  static String _short(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static const _generic = {'senor', 'senora', 'dama', 'lord', 'rey', 'reina', 'gran', 'viejo', 'vieja', 'capitan'};
}
