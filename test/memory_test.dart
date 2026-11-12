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
