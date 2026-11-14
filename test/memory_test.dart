import 'package:director_de_rol/ai/director.dart';
import 'package:director_de_rol/ai/memory/graph.dart';
import 'package:director_de_rol/ai/memory/rag.dart';
import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late AppDatabase db;
  late int cid;

  setUp(() {
    db = AppDatabase.memory();
    cid = db.insertCampaign(Campaign(title: 'Prueba', theme: 'Fantasía')).id!;
  });

  tearDown(() => db.close());

  group('RAG', () {
    test('divide textos largos en fragmentos', () {
      final text = List.generate(40, (i) => 'Frase número $i sobre el dragón rojo.').join(' ');
      final parts = RagMemory.split(text, size: 200);
      expect(parts.length, greaterThan(3));
      expect(parts.every((p) => p.length <= 400), isTrue);
    });

    test('búsqueda léxica (sin embeddings) encuentra el recuerdo correcto', () async {
      final rag = RagMemory(db, FakeLlm());
      await rag.addText(cid, 'lore', 'El herrero Gorm forjó la espada Albor en las forjas de Kadun.');
      await rag.addText(cid, 'lore', 'La reina Isolde gobierna desde el palacio de cristal.');
      await rag.addText(cid, 'lore', 'Los lobos del bosque Umbrío atacan de noche.');
      final hits = await rag.search(cid, '¿Quién forjó la espada Albor?');
      expect(hits.first.chunk.text, contains('Gorm'));
    });

    test('búsqueda híbrida con embeddings guarda y usa vectores', () async {
      final rag = RagMemory(db, FakeLlm(embeddings: true));
      await rag.addText(cid, 'lore', 'zzzz zzzz zzzz');
      await rag.addText(cid, 'lore', 'aaaa bbbb aaaa');
      expect(db.chunks(cid).every((c) => c.embedding != null && c.embedding!.length == 26), isTrue);
      final hits = await rag.search(cid, 'aaaa', k: 1);
      expect(hits.single.chunk.text, contains('aaaa'));
    });

    test('los textos nuevos entran en el índice ya montado sin reconstruirlo', () async {
      final rag = RagMemory(db, FakeLlm());
      await rag.addText(cid, 'lore', 'La reina Isolde gobierna desde el palacio de cristal.');
      expect((await rag.search(cid, 'Isolde')).single.chunk.text, contains('Isolde'));
      await rag.addText(cid, 'sesión', 'El herrero Gorm forjó la espada Albor.');
      final hits = await rag.search(cid, 'herrero Gorm');
      expect(hits.first.chunk.text, contains('Gorm'));
      expect(hits.where((h) => h.chunk.text.contains('Gorm')).length, 1);
    });

    test('una búsqueda de turno calcula un solo embedding y da hueco a la documentación', () async {
      final llm = FakeLlm(embeddings: true);
      final rag = RagMemory(db, llm);
      for (var i = 0; i < 6; i++) {
        await rag.addText(cid, 'sesión', 'Los lobos aullaron en la noche número $i.');
      }
      final docId = db.addDocument(DocumentRecord(title: 'Reglas', path: 'r.pdf', kind: 'pdf')).id!;
      db.addDocChunks(
        docId,
        ['Los lobos tienen 11 puntos de vida.'],
        [await llm.embed('Los lobos tienen 11 puntos de vida.')],
      );
      rag.invalidateAll();
      final hits = await rag.searchForTurn(cid, 'atacamos a los lobos', k: 5, kDocs: 3);
      expect(llm.queryEmbeds, ['atacamos a los lobos']);
      expect(hits.any((h) => h.chunk.source == 'doc · Reglas'), isTrue);
      expect(hits.map((h) => h.chunk.text).toSet().length, hits.length);
    });

    test('índices grandes se montan en segundo plano y encuentran lo mismo', () async {
      final llm = FakeLlm(embeddings: true);
      for (var i = 0; i < 200; i++) {
        final t = i == 137 ? 'El dragón Vermithrax duerme bajo la montaña.' : 'Crónica $i del camino al norte.';
        db.addChunk(LoreChunk(campaignId: cid, source: 'lore', text: t, embedding: await llm.embed(t)));
      }
      final hits = await RagMemory(db, llm).search(cid, 'dragón Vermithrax', k: 1);
      expect(hits.single.chunk.text, contains('Vermithrax'));
    });

    test('recorta los vectores de 768 dimensiones a 256 y los normaliza', () {
      final v = RagIndex.prepare(List.generate(768, (i) => i < 256 ? 2.0 : 9.0));
      expect(v.length, 256);
      expect(v.fold<double>(0, (a, x) => a + x * x), closeTo(1, 1e-5));
      expect(RagIndex.prepare([3, 4]), [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)]);
    });

    test('la consulta del turno se queda con el final de la narración', () {
      final q = Director.ragQuery('Abro la puerta', ['Abro la puerta', '${'x' * 1000} El pasillo huele a azufre.']);
      expect(q, startsWith('Abro la puerta\n'));
      expect(q, endsWith('huele a azufre.'));
      expect(q.length, lessThan(320));
    });

    test('vectores se codifican y decodifican sin pérdida relevante', () {
      final v = [0.5, -1.25, 3.0];
      expect(AppDatabase.decodeVector(AppDatabase.encodeVector(v)), v);
      expect(RagMemory.cosine([1, 0], [1, 0]), closeTo(1, 1e-9));
    });
  });

  group('Grafo', () {
    test('añade hechos sin duplicar entidades (ignora tildes y mayúsculas)', () {
      final g = KnowledgeGraph(db);
      g.addFact(cid, 'Lady Morwen', 'odia a', 'Orden del Alba', sourceType: 'pnj', targetType: 'facción');
      g.addFact(cid, 'lady morwen', 'vive en', 'Cripta de los Reyes');
      g.addFact(cid, 'Lady Morwen', 'odia a', 'Orden del Alba');
      expect(db.entities(cid).length, 3);
      expect(db.relations(cid).length, 2);
    });

    test('recupera contexto a dos saltos de lo mencionado', () {
      final g = KnowledgeGraph(db);
      g.addEntity(cid, 'Bran', type: 'pnj', description: 'Tabernero espía');
      g.addFact(cid, 'Bran', 'trabaja para', 'Lady Morwen');
      g.addFact(cid, 'Lady Morwen', 'esconde', 'Corona de Ceniza');
      final ctx = g.contextFor(cid, 'Preguntamos a Bran por el anillo');
      expect(ctx, contains('Bran'));
      expect(ctx, contains('trabaja para'));
      expect(ctx, contains('Corona de Ceniza'));
    });

    test('no devuelve nada si no se menciona ninguna entidad', () {
      KnowledgeGraph(db).addEntity(cid, 'Bran');
      expect(KnowledgeGraph(db).contextFor(cid, 'Miramos el cielo'), isEmpty);
    });
  });
}
