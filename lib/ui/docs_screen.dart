import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../ai/llama_service.dart';
import '../app_services.dart';
import '../core/models.dart';
import '../docs/doc_extractor.dart';
import '../docs/doc_library.dart';
import 'widgets/file_utils.dart';

/// Documentación que la IA aprende: reglamentos, ambientación, apuntes…
class DocsScreen extends StatefulWidget {
  const DocsScreen({super.key});

  @override
  State<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends State<DocsScreen> {
  final _question = TextEditingController();
  String _answer = '';
  bool _asking = false;
  int? _askScope; // null = sólo documentación global

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final lib = context.watch<DocLibrary>();
    final llm = context.watch<LlamaService>();
    final docs = s.db.documents();
    final campaigns = {for (final c in s.db.campaigns()) c.id!: c.title};
    final pending = docs.fold<int>(0, (a, d) => a + d.pendingEmbeddings);
    return Scaffold(
      appBar: AppBar(title: const Text('Documentación'), actions: [
        if (pending > 0 && llm.canEmbed)
          IconButton(
            tooltip: 'Completar memoria semántica ($pending fragmentos)',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: lib.backfill,
          ),
        if (!Platform.isAndroid)
          IconButton(tooltip: 'Aprender una carpeta entera', icon: const Icon(Icons.create_new_folder), onPressed: () => _addFolder(s)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.note_add),
        label: const Text('Añadir documentos'),
        onPressed: () => _addFiles(s),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Dale a la IA reglamentos, ambientaciones, módulos o tus apuntes (PDF, Word, EPUB, ODT, HTML, RTF, '
            'TXT, Markdown…). Los trocea y los guarda en su memoria: el director los consulta en cada turno, al '
            'crear campañas nuevas y al responder preguntas. Funciona sin Internet.',
          ),
        ),
        if (!llm.canEmbed)
          const ListTile(
            dense: true,
            leading: Icon(Icons.info_outline),
            title: Text('Consejo: activa la memoria semántica en Ajustes para que entienda también las preguntas '
                'dichas con otras palabras. Sin ella busca por palabras clave.'),
          ),
        for (final job in lib.jobs) _jobTile(lib, job),
        _askCard(s, llm, campaigns),
        if (docs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Aún no hay documentación.', textAlign: TextAlign.center)),
          ),
        for (final d in docs) _docTile(s, lib, d, campaigns),
      ]),
    );
  }

  Widget _jobTile(DocLibrary lib, DocJob job) => ListTile(
        leading: job.error == null
            ? SizedBox(width: 28, height: 28, child: CircularProgressIndicator(value: job.progress))
            : Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        title: Text(job.name),
        subtitle: Text(job.error ?? '${job.step}${job.progress == null ? '' : ' ${(job.progress! * 100).round()} %'}'),
        trailing: job.error == null ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => lib.dismiss(job)),
      );

  Widget _askCard(AppServices s, LlamaService llm, Map<int, String> campaigns) => Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pregúntale a la documentación', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (campaigns.isNotEmpty)
              DropdownButton<int?>(
                isExpanded: true,
                value: campaigns.containsKey(_askScope) ? _askScope : null,
                items: [
                  const DropdownMenuItem(value: null, child: Text('Documentación para todas las campañas')),
                  for (final e in campaigns.entries) DropdownMenuItem(value: e.key, child: Text('Incluir la de «${e.value}»')),
                ],
                onChanged: (v) => setState(() => _askScope = v),
              ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _question,
                  decoration: const InputDecoration(hintText: '¿Cómo funciona el combate a distancia?', isDense: true),
                  onSubmitted: (_) => _ask(s, llm),
                ),
              ),
              IconButton.filled(
                icon: _asking
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                onPressed: _asking || !llm.isReady ? null : () => _ask(s, llm),
              ),
            ]),
            if (!llm.isReady) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Carga un modelo de IA en Ajustes para preguntar.')),
            if (_answer.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(_answer)),
          ]),
        ),
      );

  Widget _docTile(AppServices s, DocLibrary lib, DocumentRecord d, Map<int, String> campaigns) {
    final scope = d.campaignId == null ? 'Todas las campañas' : 'Sólo «${campaigns[d.campaignId] ?? '?'}»';
    final kb = d.chars ~/ 1000;
    return ListTile(
      leading: Icon(switch (d.kind) {
        'pdf' => Icons.picture_as_pdf,
        'epub' => Icons.menu_book,
        'docx' || 'odt' || 'rtf' => Icons.description,
        _ => Icons.article,
      }),
      title: Text(d.title),
      subtitle: Text('$scope · ${d.chunks} fragmentos · ${kb > 0 ? '$kb mil caracteres' : '${d.chars} caracteres'}'
          '${d.pendingEmbeddings > 0 && d.pendingEmbeddings < d.chunks ? ' · ${d.pendingEmbeddings} sin memoria semántica' : ''}'),
      trailing: IconButton(
        tooltip: 'Olvidar',
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('¿Olvidar «${d.title}»?'),
              content: const Text('La IA dejará de usar este documento y se borrará su copia.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Olvidar')),
              ],
            ),
          );
          if (ok == true) lib.remove(d);
        },
      ),
    );
  }

  /// Pregunta a quién sirve la documentación. Devuelve (cancelado, campaignId).
  Future<(bool, int?)> _chooseScope(AppServices s) async {
    final campaigns = s.db.campaigns();
    if (campaigns.isEmpty) return (false, null);
    final r = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Para qué campañas?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const ListTile(leading: Icon(Icons.public), title: Text('Todas'), subtitle: Text('Reglas, ambientación general…')),
          ),
          for (final c in campaigns)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: ListTile(leading: const Icon(Icons.auto_stories), title: Text('Sólo «${c.title}»')),
            ),
        ],
      ),
    );
    if (r == null) return (true, null);
    return (false, r == -1 ? null : r);
  }

  Future<void> _addFiles(AppServices s) async {
    final files = await FilePicker.pickFiles(dialogTitle: 'Documentación para la IA');
    if (files.isEmpty || !mounted) return;
    final ok = files.where((f) => DocExtractor.supports(f.name)).toList();
    final skipped = files.length - ok.length;
    if (ok.isEmpty) {
      _snack('Formato no admitido. Usa ${DocExtractor.extensions.join(', ')}.');
      return;
    }
    final (cancel, campaignId) = await _chooseScope(s);
    if (cancel) return;
    var n = 0;
    for (final f in ok) {
      final path = await localPathFor(f, s.dataRoot.tmp);
      if (path == null) continue;
      if (await s.docs.learn(path, campaignId: campaignId, title: f.name) != null) n++;
      if (p.isWithin(s.dataRoot.tmp, path)) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }
    _snack('$n documento${n == 1 ? '' : 's'} aprendido${n == 1 ? '' : 's'}${skipped > 0 ? ' ($skipped con formato no admitido)' : ''}');
  }

  Future<void> _addFolder(AppServices s) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Carpeta de documentación');
    if (dir == null || !mounted) return;
    final (cancel, campaignId) = await _chooseScope(s);
    if (cancel) return;
    final n = await s.docs.learnFolder(dir, campaignId: campaignId);
    _snack('$n documentos aprendidos');
  }

  Future<void> _ask(AppServices s, LlamaService llm) async {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _asking = true;
      _answer = '';
    });
    try {
      await for (final t in s.docs.ask(q, campaignId: _askScope)) {
        if (!mounted) return;
        setState(() => _answer += t);
      }
    } catch (e) {
      if (mounted) setState(() => _answer = 'Error: $e');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }
}
