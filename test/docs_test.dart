import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:director_de_rol/ai/memory/rag.dart';
import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:director_de_rol/core/portable.dart';
import 'package:director_de_rol/core/story_package.dart';
import 'package:director_de_rol/docs/doc_extractor.dart';
import 'package:director_de_rol/docs/doc_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'fakes.dart';

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((k, v) => a.addFile(ArchiveFile.string(k, v)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(a));
}

Uint8List _pdf(List<String> pages) {
  final doc = PdfDocument();
  for (final t in pages) {
    doc.pages.add().graphics.drawString(t, PdfStandardFont(PdfFontFamily.helvetica, 12),
        bounds: const Rect.fromLTWH(0, 0, 500, 700));
  }
  final bytes = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return bytes;
}

void main() {
  group('extracción de texto', () {
    test('PDF de varias páginas', () {
      final t = DocExtractor.extract(_pdf(['Reglas de combate', 'Tirada de iniciativa con d20']), 'pdf');
      expect(t, contains('Reglas de combate'));
      expect(t, contains('iniciativa con d20'));
    });

    test('Word (.docx) por párrafos', () {
      final docx = _zip({
        'word/document.xml': '<w:document><w:body><w:p><w:r><w:t>Los elfos de Lirien</w:t></w:r></w:p>'
            '<w:p><w:r><w:t xml:space="preserve">odian a los </w:t></w:r><w:r><w:t>enanos &amp; orcos.</w:t></w:r></w:p></w:body></w:document>',
      });
      expect(DocExtractor.extract(docx, 'docx'), 'Los elfos de Lirien\nodian a los enanos & orcos.');
    });

    test('EPUB en el orden del índice', () {
      final epub = _zip({
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/libro.opf"/></rootfiles></container>',
        'OEBPS/libro.opf': '<package><manifest><item id="b" href="b.xhtml"/><item id="a" href="a.xhtml"/></manifest>'
            '<spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
        'OEBPS/a.xhtml': '<html><head><title>x</title></head><body><p>Capítulo uno.</p></body></html>',
        'OEBPS/b.xhtml': '<html><body><p>Capítulo dos.</p></body></html>',
      });
      expect(DocExtractor.extract(epub, 'epub'), 'Capítulo uno.\n\nCapítulo dos.');
    });

    test('HTML, RTF y texto en Latin-1', () {
      expect(DocExtractor.extract(utf8.encode('<p>Hola<br>mundo</p><script>x()</script>'), 'html'), 'Hola\nmundo');
      expect(DocExtractor.extract(utf8.encode(r"{\rtf1\ansi {\fonttbl x} Drag\'f3n\par rojo}"), 'rtf'), contains('Dragón\nrojo'));
      expect(DocExtractor.extract(Uint8List.fromList(latin1.encode('Señor de la guerra')), 'txt'), 'Señor de la guerra');
    });
  });

  group('biblioteca', () {
    late Directory tmp;
    late DataRoot root;
    late AppDatabase db;
    late RagMemory rag;
    late DocLibrary lib;
    late int c1, c2;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('docs_');
      root = DataRoot(p.join(tmp.path, 'datos'));
      db = AppDatabase.memory(root: root);
      final llm = FakeLlm(embeddings: true, replies: ['Se tira d20 [Reglas].']);
      rag = RagMemory(db, llm);
      lib = DocLibrary(db, rag, llm, root);
      c1 = db.insertCampaign(Campaign(title: 'Uno', theme: 'Fantasía')).id!;
      c2 = db.insertCampaign(Campaign(title: 'Dos', theme: 'Fantasía')).id!;
    });

    tearDown(() {
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('aprende un PDF, lo copia a la carpeta portable y el director lo encuentra', () async {
      final f = File(p.join(tmp.path, 'Reglas.pdf'))
        ..writeAsBytesSync(_pdf(['La iniciativa se decide con una tirada de d20 más la destreza.']));
      final doc = await lib.learn(f.path);
      expect(doc, isNotNull);
      expect(lib.jobs, isEmpty);
      final stored = db.documents().single;
      expect(stored.title, 'Reglas');
      expect(stored.chunks, greaterThan(0));
      expect(stored.pendingEmbeddings, 0);
      expect(p.isWithin(root.documents, stored.path), isTrue);

      final hits = await rag.search(c1, '¿cómo se decide la iniciativa?');
      expect(hits.first.chunk.source, 'doc · Reglas');
      expect(await lib.ask('iniciativa').join(), contains('d20'));
    });

    test('la documentación de una campaña no la ve otra; olvidar la quita', () async {
      final f = File(p.join(tmp.path, 'secretos.md'))..writeAsStringSync('El conde Varo es en realidad un vampiro milenario.');
      await lib.learn(f.path, campaignId: c1);
      expect((await rag.search(c1, 'conde Varo vampiro')).first.chunk.source, 'doc · secretos');
      expect((await rag.search(c2, 'conde Varo vampiro')).where((h) => h.chunk.source.startsWith('doc')), isEmpty);

      final bytes = StoryPackage.export(db, c1);
      final imported = StoryPackage.import(db, bytes, mapsDir: root.maps);
      expect(db.documents().where((d) => d.campaignId == imported.id).single.chunks, 1);

      lib.remove(db.documents().firstWhere((d) => d.campaignId == c1));
      expect((await rag.search(c1, 'conde Varo vampiro')).where((h) => h.chunk.source.startsWith('doc')), isEmpty);
    });

    test('avisa si el documento no tiene texto', () async {
      final f = File(p.join(tmp.path, 'vacio.pdf'))..writeAsBytesSync(_pdf(['']));
      expect(await lib.learn(f.path), isNull);
      expect(lib.jobs.single.error, contains('No se encontró texto'));
      expect(db.documents(), isEmpty);
    });
  });
}
