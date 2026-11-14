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

  /// Relaciones de ubicación: alguien sólo está en un sitio a la vez.
  static const _whereabouts = {
    'esta en', 'se encuentra en', 'se esconde en', 'esta preso en', 'esta encerrado en', 'se aloja en',
    'se dirige a', 'viaja a', 'huyo a', 'esta atrapado en', 'acampa en',
  };

  /// Relaciones de posesión: un objeto sólo lo tiene uno a la vez.
  static const _ownership = {'posee', 'tiene', 'lleva', 'porta', 'custodia', 'guarda', 'robo'};

  /// Relaciones que significan que alguien ha muerto o desaparecido.
  static final _deathRe = RegExp(r'^(murio|ha muerto|muere|fue asesinad[oa]|fue destruid[oa]|desaparecio)');

  static String _rel(String r) => AppDatabase.normalize(r);

  /// Añade un hecho y caduca los que ya no pueden ser ciertos a la vez:
  /// si Bran «está en» el puerto, deja de estar en la taberna; si Kael
  /// «posee» el anillo, ya no lo posee Mira; si alguien muere, deja de
  /// estar en cualquier sitio.
  void addFact(int campaignId, String source, String relation, String target,
      {String sourceType = 'otro', String targetType = 'otro', int session = 0}) {
    if (source.trim().isEmpty || target.trim().isEmpty || relation.trim().isEmpty) return;
    final s = addEntity(campaignId, source, type: sourceType);
    final t = addEntity(campaignId, target, type: targetType);
    final id = db.addRelation(campaignId, s.id!, relation, t.id!, session: session);
    if (id == null) return;
    final r = _rel(relation);
    final current = db.relations(campaignId, touching: {s.id!, t.id!}, ended: false).where((x) => x.id != id);
    for (final old in current) {
      final o = _rel(old.relation);
      final sameSource = old.sourceId == s.id;
      final conflict = (sameSource && _whereabouts.contains(r) && _whereabouts.contains(o) && old.targetId != t.id) ||
          (old.targetId == t.id && !sameSource && _ownership.contains(r) && _ownership.contains(o)) ||
          (sameSource && _deathRe.hasMatch(r) && _whereabouts.contains(o));
      if (conflict) db.endRelation(old.id!, session: session);
    }
  }

  /// El hecho deja de ser cierto. Devuelve true si se encontró.
  bool endFact(int campaignId, String source, String relation, String target, {int session = 0}) {
    final sn = AppDatabase.normalize(source), tn = AppDatabase.normalize(target), rn = _rel(relation);
    if (sn.isEmpty || tn.isEmpty) return false;
    var found = false;
    for (final r in db.relations(campaignId, ended: false)) {
      if (AppDatabase.normalize(r.sourceName) == sn &&
          AppDatabase.normalize(r.targetName) == tn &&
          (rn.isEmpty || _rel(r.relation) == rn || _rel(r.relation).contains(rn) || rn.contains(_rel(r.relation)))) {
        db.endRelation(r.id!, session: session);
        found = true;
      }
    }
    return found;
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
      final rels = db.relations(campaignId, touching: frontier, ended: false);
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
      b.writeln('Relaciones vigentes:');
      for (final r in facts.take(maxFacts)) {
        b.writeln('- ${r.sourceName} → ${r.relation} → ${r.targetName}');
      }
    }
    // Lo que fue cierto y ya no lo es, para no resucitarlo por error.
    final past = db.relations(campaignId, touching: {for (final e in seeds) e.id!}, ended: true);
    if (past.isNotEmpty) {
      b.writeln('Ya NO es cierto (pasado):');
      for (final r in past.reversed.take(8)) {
        b.writeln('- ${r.sourceName} ${r.relation} ${r.targetName}${r.untilSession > 0 ? ' (hasta la sesión ${r.untilSession})' : ''}');
      }
    }
    return b.toString().trim();
  }

  static String _short(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static const _generic = {'senor', 'senora', 'dama', 'lord', 'rey', 'reina', 'gran', 'viejo', 'vieja', 'capitan'};
}
