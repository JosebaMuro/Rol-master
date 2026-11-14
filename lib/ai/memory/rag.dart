import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' show ResultSet;

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
/// búsqueda es híbrida (coseno + BM25); si no, sólo BM25 léxico, así funciona
/// también sin descargar nada extra.
///
/// Para que cada turno sea rápido, los fragmentos viven en índices en memoria
/// (vectores normalizados en `Float32List` e índice invertido para BM25) que se
/// construyen una sola vez, fuera del hilo de la interfaz, y se amplían al
/// añadir texto en vez de reconstruirse.
class RagMemory {
  RagMemory(this.db, this.llm);
  final AppDatabase db;
  final TextGenerator llm;

  /// EmbeddingGemma (768 dimensiones) está entrenado con Matryoshka: sus
  /// primeras 256 dimensiones, renormalizadas, conservan casi toda la calidad
  /// y comparan tres veces más rápido. En la base de datos se guarda el vector
  /// completo, así que se puede cambiar sin recalcular nada.
  static const matryoshkaFrom = 768;
  static const matryoshkaDims = 256;

  /// Recuerdos de partida, por campaña.
  final Map<int, Future<RagIndex>> _memory = {};

  /// Documentación visible, por campaña (-1 = sólo la global).
  final Map<int, Future<RagIndex>> _docs = {};

  void invalidate(int campaignId) => _memory.remove(campaignId);

  /// Tras añadir o quitar documentación, que afecta a todas las campañas.
  void invalidateAll() => _docs.clear();

  Future<RagIndex> _memoryIndex(int campaignId) => _memory[campaignId] ??= _build(
    () => db.db.select('SELECT id, source, text, embedding FROM chunks WHERE campaign_id = ?', [campaignId]),
    campaignId,
  );

  Future<RagIndex> _docIndex(int? campaignId) => _docs[campaignId ?? -1] ??= _build(
    () => db.db.select(
      'SELECT c.id, \'doc · \' || d.title AS source, c.text, c.embedding FROM doc_chunks c '
      'JOIN documents d ON d.id = c.doc_id WHERE (d.campaign_id IS NULL OR d.campaign_id = ?)',
      [campaignId ?? -1],
    ),
    campaignId ?? 0,
  );

  /// Lee las filas en este hilo (SQLite es rápido) y monta el índice en otro
  /// isolate: tokenizar y normalizar vectores es lo que cuesta.
  Future<RagIndex> _build(ResultSet Function() rows, int campaignId) async {
    final ids = <int>[], sources = <String>[], texts = <String>[];
    final blobs = <Uint8List?>[];
    for (final r in rows()) {
      ids.add(r['id'] as int);
      sources.add(r['source'] as String);
      texts.add(r['text'] as String);
      blobs.add(r['embedding'] as Uint8List?);
    }
    if (ids.length < 64) return RagIndex.build(campaignId, ids, sources, texts, blobs);
    return _buildInBackground(campaignId, ids, sources, texts, blobs);
  }

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
      final c = db.addChunk(LoreChunk(campaignId: campaignId, source: source, text: piece, embedding: emb));
      // Si el índice ya existe (leyó la base de datos antes de esta inserción)
      // se amplía; si no, se montará con todo al buscar.
      final index = _memory[campaignId];
      if (index != null) (await index).add(c.id!, source, piece, emb);
      n++;
    }
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

  /// Prepara la consulta una vez (un solo embedding) para usarla en varias
  /// búsquedas.
  Future<RagQuery> query(String text) async {
    final trimmed = text.trim();
    final v = trimmed.isEmpty ? null : await llm.embed(trimmed, query: true);
    return RagQuery(tokenize(trimmed).toSet(), v == null ? null : RagIndex.prepare(v));
  }

  /// Memoria de la campaña más la documentación que ve (global y propia).
  Future<List<RagHit>> search(int campaignId, String query, {int k = 5}) async =>
      searchWith(campaignId, await this.query(query), k: k);

  Future<List<RagHit>> searchWith(int campaignId, RagQuery q, {int k = 5}) async {
    if (q.isEmpty) return const [];
    final hits = [...(await _memoryIndex(campaignId)).search(q, k), ...(await _docIndex(campaignId)).search(q, k)]
      ..sort((a, b) => b.score.compareTo(a.score));
    return hits.take(k).toList();
  }

  /// Busca sólo en la documentación (global, o global + la de [campaignId]).
  Future<List<RagHit>> searchDocs(String query, {int? campaignId, int k = 6}) async =>
      searchDocsWith(await this.query(query), campaignId: campaignId, k: k);

  Future<List<RagHit>> searchDocsWith(RagQuery q, {int? campaignId, int k = 6}) async =>
      q.isEmpty ? const [] : (await _docIndex(campaignId)).search(q, k);

  /// Búsqueda de cada turno: lo mejor de memoria + documentación y, además,
  /// un hueco propio para la documentación (reglas, ambientación). Un solo
  /// embedding de consulta para todo.
  Future<List<RagHit>> searchForTurn(int campaignId, String query, {int k = 5, int kDocs = 3}) async {
    final q = await this.query(query);
    final hits = await searchWith(campaignId, q, k: k);
    final seen = hits.map((h) => h.chunk.text).toSet();
    hits.addAll(
      (await searchDocsWith(q, campaignId: campaignId, k: k + kDocs)).where((h) => seen.add(h.chunk.text)).take(kDocs),
    );
    return hits;
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

  static List<String> tokenize(String s) =>
      AppDatabase.normalize(s).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2 && !_stop.contains(w)).toList();

  static const _stop = {
    'que',
    'los',
    'las',
    'del',
    'una',
    'uno',
    'con',
    'por',
    'para',
    'como',
    'pero',
    'sus',
    'mas',
    'muy',
    'este',
    'esta',
    'esto',
    'ese',
    'esa',
    'eso',
    'hay',
    'fue',
    'ser',
    'son',
    'era',
    'han',
    'has',
    'sin',
    'sobre',
    'entre',
    'cuando',
    'donde',
    'tambien',
    'porque',
    'todo',
    'todos',
    'nos',
    'les',
    'lo',
    'le',
    'the',
    'and',
    'you',
    'qué',
    'aqui',
    'alli',
    'ante',
    'tras',
    'hacia',
    'hasta',
    'desde',
    'mientras',
  };
}

/// Función de nivel superior para que el isolate no arrastre la base de datos.
Future<RagIndex> _buildInBackground(
  int campaignId,
  List<int> ids,
  List<String> sources,
  List<String> texts,
  List<Uint8List?> blobs,
) => Isolate.run(() => RagIndex.build(campaignId, ids, sources, texts, blobs));

/// Consulta preparada: palabras para BM25 y vector normalizado (puede faltar).
class RagQuery {
  RagQuery(this.terms, this.vector);
  final Set<String> terms;
  final Float32List? vector;
  bool get isEmpty => terms.isEmpty && vector == null;
}

/// Índice en memoria de un conjunto de fragmentos.
class RagIndex {
  RagIndex._(this.campaignId);
  final int campaignId;

  final _ids = <int>[];
  final _sources = <String>[];
  final _texts = <String>[];
  final _vectors = <Float32List?>[];
  final _lengths = <int>[];
  var _totalLength = 0;

  /// palabra → [doc, frecuencia, doc, frecuencia, …]
  final _postings = <String, List<int>>{};

  int get length => _ids.length;

  static RagIndex build(
    int campaignId,
    List<int> ids,
    List<String> sources,
    List<String> texts,
    List<Uint8List?> blobs,
  ) {
    final index = RagIndex._(campaignId);
    for (var i = 0; i < ids.length; i++) {
      final b = blobs[i];
      index._add(
        ids[i],
        sources[i],
        texts[i],
        b == null ? null : prepare(Float32List.view(Uint8List.fromList(b).buffer, 0, b.lengthInBytes ~/ 4)),
      );
    }
    return index;
  }

  void add(int id, String source, String text, List<double>? embedding) =>
      _add(id, source, text, embedding == null ? null : prepare(embedding));

  void _add(int id, String source, String text, Float32List? vector) {
    final doc = _ids.length;
    _ids.add(id);
    _sources.add(source);
    _texts.add(text);
    _vectors.add(vector);
    final tokens = RagMemory.tokenize(text);
    _lengths.add(tokens.length);
    _totalLength += tokens.length;
    final tf = <String, int>{};
    for (final w in tokens) {
      tf[w] = (tf[w] ?? 0) + 1;
    }
    tf.forEach((w, f) => (_postings[w] ??= []).addAll([doc, f]));
  }

  /// Recorta (Matryoshka) y normaliza a longitud 1, así el coseno es un
  /// producto escalar.
  static Float32List prepare(List<double> v) {
    final dims = v.length == RagMemory.matryoshkaFrom ? RagMemory.matryoshkaDims : v.length;
    final out = Float32List(dims);
    var norm = 0.0;
    for (var i = 0; i < dims; i++) {
      out[i] = v[i];
      norm += v[i] * v[i];
    }
    if (norm > 0) {
      final inv = 1 / math.sqrt(norm);
      for (var i = 0; i < dims; i++) {
        out[i] *= inv;
      }
    }
    return out;
  }

  List<RagHit> search(RagQuery q, int k) {
    final n = _ids.length;
    if (n == 0 || q.isEmpty) return const [];

    // BM25 sólo sobre los documentos que contienen alguna palabra de la consulta.
    final lexical = Float64List(n);
    const k1 = 1.4, b = 0.75;
    final avg = _totalLength / n;
    var maxLex = 0.0;
    for (final w in q.terms) {
      final p = _postings[w];
      if (p == null) continue;
      final df = p.length ~/ 2;
      final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
      for (var i = 0; i < p.length; i += 2) {
        final d = p[i], f = p[i + 1];
        lexical[d] += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * _lengths[d] / math.max(1, avg)));
      }
    }
    for (final s in lexical) {
      if (s > maxLex) maxLex = s;
    }

    final qv = q.vector;
    final hits = <(int, double)>[];
    for (var d = 0; d < n; d++) {
      var score = maxLex == 0 ? 0.0 : lexical[d] / maxLex;
      final v = _vectors[d];
      if (qv != null && v != null && v.length == qv.length) {
        var dot = 0.0;
        for (var i = 0; i < v.length; i++) {
          dot += v[i] * qv[i];
        }
        // Mezcla híbrida: semántica + léxica normalizada.
        score = 0.75 * dot + 0.25 * score;
      }
      if (score > 0.05) hits.add((d, score));
    }
    hits.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (d, score) in hits.take(k))
        RagHit(LoreChunk(id: _ids[d], campaignId: campaignId, source: _sources[d], text: _texts[d]), score),
    ];
  }
}
