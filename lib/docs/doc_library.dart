import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../ai/llm.dart';
import '../ai/memory/rag.dart';
import '../core/db.dart';
import '../core/models.dart';
import '../core/portable.dart';
import 'doc_extractor.dart';

/// Estado de un documento que se está aprendiendo.
class DocJob {
  DocJob(this.name);
  final String name;
  String step = 'Leyendo…';
  double? progress;
  String? error;
}

/// Biblioteca de documentación: reglamentos, ambientación, apuntes… La IA la
/// "aprende" troceándola en su memoria (RAG): el director consulta los
/// fragmentos relevantes en cada turno, al crear campañas y al responder
/// preguntas. Una copia del documento se guarda en `datos/documentos`.
class DocLibrary extends ChangeNotifier {
  DocLibrary(this.db, this.rag, this.llm, this.root);
  final AppDatabase db;
  final RagMemory rag;
  final TextGenerator llm;
  final DataRoot root;

  final List<DocJob> jobs = [];
  bool _backfilling = false;

  /// Aprende un documento. [campaignId] null = para todas las campañas.
  Future<DocumentRecord?> learn(String path, {int? campaignId, String? title}) async {
    final job = DocJob(title ?? p.basename(path));
    jobs.add(job);
    notifyListeners();
    try {
      if (!DocExtractor.supports(path)) throw const FormatException('Formato no admitido');
      final text = await Isolate.run(() => DocExtractor.extractFile(path));
      if (text.trim().length < 20) {
        throw const FormatException('No se encontró texto (¿es un PDF escaneado como imagen?)');
      }
      job.step = 'Troceando…';
      notifyListeners();
      final pieces = RagMemory.split(text, size: 900, overlap: 150);

      final embeddings = <List<double>?>[];
      if (llm.canEmbed) {
        job.step = 'Aprendiendo…';
        for (var i = 0; i < pieces.length; i++) {
          embeddings.add(await llm.embed(pieces[i]));
          if (i % 4 == 0 || i == pieces.length - 1) {
            job.progress = (i + 1) / pieces.length;
            notifyListeners();
          }
        }
      }

      final stored = await root.adopt(path, root.documents);
      final doc = db.addDocument(DocumentRecord(
        campaignId: campaignId,
        title: p.basenameWithoutExtension(title ?? path),
        path: stored,
        kind: DocExtractor.kindOf(path),
        chars: text.length,
      ));
      db.addDocChunks(doc.id!, pieces, embeddings);
      rag.invalidateAll();
      jobs.remove(job);
      notifyListeners();
      return doc;
    } catch (e) {
      job
        ..error = e is FormatException ? e.message : '$e'
        ..progress = null;
      notifyListeners();
      return null;
    }
  }

  void dismiss(DocJob job) {
    jobs.remove(job);
    notifyListeners();
  }

  /// Aprende todos los documentos admitidos de una carpeta (y subcarpetas).
  Future<int> learnFolder(String dir, {int? campaignId}) async {
    var n = 0;
    final files = Directory(dir).listSync(recursive: true).whereType<File>().where((f) => DocExtractor.supports(f.path)).toList();
    for (final f in files) {
      if (await learn(f.path, campaignId: campaignId) != null) n++;
    }
    return n;
  }

  void remove(DocumentRecord d) {
    db.deleteDocument(d.id!);
    final f = File(d.path);
    if (p.isWithin(root.documents, d.path) && f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    rag.invalidateAll();
    notifyListeners();
  }

  int get pendingEmbeddings => db.allDocChunksMissingEmbedding().length;

  /// Calcula la memoria semántica de los documentos aprendidos sin ella
  /// (p. ej. si se activó el modelo de embeddings después).
  Future<int> backfill() async {
    if (_backfilling || !llm.canEmbed) return 0;
    _backfilling = true;
    final job = DocJob('Memoria semántica de la documentación')..step = 'Aprendiendo…';
    jobs.add(job);
    notifyListeners();
    var n = 0;
    try {
      final todo = db.allDocChunksMissingEmbedding();
      for (var i = 0; i < todo.length; i++) {
        final v = await llm.embed(todo[i].text);
        if (v != null) {
          db.setDocChunkEmbedding(todo[i].id!, v);
          n++;
        }
        if (i % 4 == 0) {
          job.progress = (i + 1) / todo.length;
          notifyListeners();
        }
      }
    } finally {
      _backfilling = false;
      jobs.remove(job);
      rag.invalidateAll();
      notifyListeners();
    }
    return n;
  }

  /// Responde una pregunta usando sólo la documentación.
  Stream<String> ask(String question, {int? campaignId}) async* {
    final hits = await rag.searchDocs(question, campaignId: campaignId, k: 8);
    if (hits.isEmpty) {
      yield 'No encuentro nada sobre eso en la documentación.';
      return;
    }
    final ctx = hits.map((h) => '[${h.chunk.source.replaceFirst('doc · ', '')}]\n${h.chunk.text}').join('\n\n');
    await for (final ch in llm.chat(
      [
        const LlmMessage.system(
          'Respondes en español usando sólo los fragmentos de documentación dados. '
          'Cita entre corchetes el documento de donde sale cada dato. Si no está, dilo.',
        ),
        LlmMessage.user('Documentación:\n$ctx\n\nPregunta: $question'),
      ],
      temperature: 0.2,
      maxTokens: 700,
    )) {
      if (ch.text.isNotEmpty) yield ch.text;
    }
  }

  /// Contexto de documentación para crear una campaña nueva (sólo la global).
  Future<String> referenceFor(String query, {int k = 6}) async {
    final hits = await rag.searchDocs(query, k: k);
    return hits.map((h) => '- (${h.chunk.source.replaceFirst('doc · ', '')}) ${h.chunk.text}').join('\n');
  }
}
