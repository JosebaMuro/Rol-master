import 'dart:math' as math;

import '../../core/db.dart';
import '../../core/models.dart';
import '../llm.dart';

class RagHit {
  RagHit(this.chunk, this.score);
  final LoreChunk chunk;
  final double score;
}

/// Memoria por recuperación (RAG). Guarda fragmentos de lore, de la biblia de
/// campaña y de lo ocurrido en partida. Si hay modelo de embeddings, la
/// búsqueda es semántica (coseno); si no, usa BM25 léxico, así funciona
/// también sin descargar nada extra.
class RagMemory {
  RagMemory(this.db, this.llm);
  final AppDatabase db;
  final TextGenerator llm;

  final Map<int, List<LoreChunk>> _cache = {};

  void invalidate(int campaignId) => _cache.remove(campaignId);

  /// Tras añadir o quitar documentación, que afecta a todas las campañas.
  void invalidateAll() => _cache.clear();

  /// Memoria de la campaña más la documentación que ve (global y propia).
  List<LoreChunk> _chunks(int campaignId) => _cache[campaignId] ??= [...db.chunks(campaignId), ...db.docChunks(campaignId)];

  /// Divide un texto largo en fragmentos de ~[size] caracteres respetando
  /// párrafos y frases.
  static List<String> split(String text, {int size = 700, int overlap = 120}) {
    final clean = text.replaceAll('\r', '').trim();
    if (clean.isEmpty) return const [];
    if (clean.length <= size) return [clean];
    final paras = clean.split(RegExp(r'\n\s*\n'));
    final out = <String>[];
    final buf = StringBuffer();
    void emit() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
      if (s.length > overlap) buf.write('${s.substring(s.length - overlap)} ');
    }

    for (final p in paras) {
      if (buf.length + p.length > size && buf.isNotEmpty) emit();
      if (p.length > size) {
        for (final sentence in p.split(RegExp(r'(?<=[.!?…])\s+'))) {
          if (buf.length + sentence.length > size && buf.isNotEmpty) emit();
          buf.write('$sentence ');
        }
      } else {
        buf.write('$p\n\n');
      }
    }
    final last = buf.toString().trim();
    if (last.isNotEmpty && (out.isEmpty || !out.last.endsWith(last))) out.add(last);
    return out;
  }

  Future<int> addText(int campaignId, String source, String text) async {
    var n = 0;
    for (final piece in split(text)) {
      final emb = await llm.embed(piece);
      db.addChunk(LoreChunk(campaignId: campaignId, source: source, text: piece, embedding: emb));
      n++;
    }
    invalidate(campaignId);
    return n;
  }

  /// Calcula embeddings pendientes (p. ej. tras cargar el modelo de
  /// embeddings en una campaña que ya tenía memoria léxica).
  Future<int> backfill(int campaignId) async {
    if (!llm.canEmbed) return 0;
    var n = 0;
    for (final c in db.chunks(campaignId).where((c) => c.embedding == null)) {
      final v = await llm.embed(c.text);
      if (v != null) {
        db.setChunkEmbedding(c.id!, v);
        n++;
      }
    }
    invalidate(campaignId);
    return n;
  }

  Future<List<RagHit>> search(int campaignId, String query, {int k = 5}) => searchIn(_chunks(campaignId), query, k: k);

  /// Busca sólo en la documentación (global, o global + la de [campaignId]).
  Future<List<RagHit>> searchDocs(String query, {int? campaignId, int k = 6}) =>
      searchIn(db.docChunks(campaignId), query, k: k);

  Future<List<RagHit>> searchIn(List<LoreChunk> all, String query, {int k = 5}) async {
    if (all.isEmpty || query.trim().isEmpty) return const [];
    final qv = await llm.embed(query, query: true);
    final lexical = _bm25(all, query);
    final hits = <RagHit>[];
    for (var i = 0; i < all.length; i++) {
      final c = all[i];
      var score = lexical[i];
      if (qv != null && c.embedding != null && c.embedding!.length == qv.length) {
        // Mezcla híbrida: semántica + léxica normalizada.
        score = 0.75 * cosine(qv, c.embedding!) + 0.25 * score;
      }
      hits.add(RagHit(c, score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.where((h) => h.score > 0.05).take(k).toList();
  }

  static double cosine(List<double> a, List<double> b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  static List<String> tokenize(String s) => AppDatabase.normalize(s)
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_stop.contains(w))
      .toList();

  /// BM25 normalizado a [0, 1].
  static List<double> _bm25(List<LoreChunk> docs, String query) {
    final q = tokenize(query).toSet();
    if (q.isEmpty) return List.filled(docs.length, 0);
    final toks = [for (final d in docs) tokenize(d.text)];
    final avg = toks.fold<int>(0, (a, t) => a + t.length) / math.max(1, toks.length);
    final df = <String, int>{};
    for (final t in toks) {
      for (final w in t.toSet()) {
        if (q.contains(w)) df[w] = (df[w] ?? 0) + 1;
      }
    }
    const k1 = 1.4, b = 0.75;
    final scores = <double>[];
    for (final t in toks) {
      final tf = <String, int>{};
      for (final w in t) {
        if (q.contains(w)) tf[w] = (tf[w] ?? 0) + 1;
      }
      var s = 0.0;
      tf.forEach((w, f) {
        final idf = math.log(1 + (docs.length - df[w]! + 0.5) / (df[w]! + 0.5));
        s += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * t.length / math.max(1, avg)));
      });
      scores.add(s);
    }
    final mx = scores.fold<double>(0, math.max);
    return mx == 0 ? scores : [for (final s in scores) s / mx];
  }

  static const _stop = {
    'que', 'los', 'las', 'del', 'una', 'uno', 'con', 'por', 'para', 'como', 'pero', 'sus', 'mas', 'muy',
    'este', 'esta', 'esto', 'ese', 'esa', 'eso', 'hay', 'fue', 'ser', 'son', 'era', 'han', 'has', 'sin',
    'sobre', 'entre', 'cuando', 'donde', 'tambien', 'porque', 'todo', 'todos', 'nos', 'les', 'lo', 'le',
    'the', 'and', 'you', 'qué', 'aqui', 'alli', 'ante', 'tras', 'hacia', 'hasta', 'desde', 'mientras',
  };
}
