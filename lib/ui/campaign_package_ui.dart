import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../core/models.dart';
import '../core/story_package.dart';
import '../logs/log_service.dart';

/// Diálogos para exportar e importar campañas completas (`.rolpack`) en
/// Windows y Android.

String _mb(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 100 * 1024 * 1024 ? 1 : 0)} MB';

/// En Android no se puede escribir a un fichero elegido por el usuario sin
/// pasar los bytes en memoria: por encima de esto sólo se deja la copia en
/// la carpeta de exportaciones.
const _androidCopyLimit = 300 * 1024 * 1024;

Future<void> exportCampaignPackage(BuildContext context, AppServices s, Campaign c) async {
  final sizes = StoryPackage.estimateSizes(s.db, c.id!, root: s.dataRoot, settings: s.settings);
  final opts = await showDialog<PackageOptions>(context: context, builder: (_) => _ExportDialog(sizes: sizes));
  if (opts == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final safe = LogService.safe(c.title);
  final name = '$safe${opts.progress ? '' : ' (sin jugar)'}.${StoryPackage.extension}';
  final local = p.join(s.dataRoot.exports, name);
  final done = _showBusy(context, 'Empaquetando la campaña…');
  int size;
  try {
    size = await StoryPackage.exportToFile(s.db, c.id!, local, options: opts, root: s.dataRoot, settings: s.settings);
  } catch (e) {
    done();
    messenger.showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
    return;
  }
  done();

  // Además de la copia en la carpeta de datos, donde elija el usuario.
  String? chosen;
  try {
    if (Platform.isAndroid) {
      if (size <= _androidCopyLimit) {
        final uri = await FilePicker.saveFile(
          fileName: name,
          bytes: await File(local).readAsBytes(),
          dialogTitle: 'Guardar campaña',
        );
        chosen = uri?.toString();
      }
    } else {
      // En escritorio el diálogo devuelve una ruta: se copia el fichero tal cual.
      final uri = await FilePicker.saveFile(fileName: name, bytes: Uint8List(0), dialogTitle: 'Guardar campaña');
      if (uri != null && uri.scheme == 'file') {
        final dest = uri.toFilePath();
        if (!p.equals(dest, local)) await File(local).copy(dest);
        chosen = dest;
      }
    }
  } catch (_) {}
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 8),
    content: Text(
      chosen != null
          ? 'Campaña exportada (${_mb(size)}) a $chosen'
          : 'Campaña exportada (${_mb(size)}) a $local${Platform.isAndroid && size > _androidCopyLimit ? '\nEs grande: cópiala por USB desde esa carpeta.' : ''}',
    ),
  ));
}

/// Pide un `.rolpack`, enseña lo que trae y lo importa. Devuelve la campaña
/// nueva (o null si se cancela o falla).
Future<Campaign?> importCampaignPackage(BuildContext context, AppServices s) async {
  final messenger = ScaffoldMessenger.of(context);
  String? path;
  File? temp;
  try {
    final f = await FilePicker.pickFile(dialogTitle: 'Importar campaña (.${StoryPackage.extension})');
    if (f == null) return null;
    if (f.path != null && File(f.path!).existsSync()) {
      path = f.path!;
    } else {
      // Sin ruta (algunos proveedores de Android): se copia a la carpeta temporal.
      temp = File(p.join(s.dataRoot.tmp, 'importar_${DateTime.now().millisecondsSinceEpoch}.${StoryPackage.extension}'));
      final sink = temp.openWrite();
      await sink.addStream(f.xFile.openRead());
      await sink.close();
      path = temp.path;
    }

    final summary = StoryPackage.peekFile(path);
    if (!context.mounted) return null;
    final opts = await showDialog<ImportOptions>(context: context, builder: (_) => _ImportDialog(summary: summary));
    if (opts == null || !context.mounted) return null;

    final done = _showBusy(context, 'Importando «${summary.title}»…');
    ImportReport report;
    try {
      report = await StoryPackage.importFile(s.db, path, root: s.dataRoot, settings: s.settings, options: opts);
    } finally {
      done();
    }
    final c = report.campaign;

    // Registros en Markdown por jugador y tema, como si se hubiera jugado aquí.
    for (final session in s.db.sessions(c.id!)) {
      try {
        await s.logs.writeSession(c, session);
      } catch (_) {}
    }
    // Memoria RAG, documentación, música y voces nuevas.
    s.rag.invalidate(c.id!);
    s.rag.invalidateAll();
    s.music.changed();
    await s.voicePacks.refresh();
    if (report.needsReembed && s.llm.canEmbed) {
      s.rag.backfill(c.id!).ignore();
      s.docs.backfill().ignore();
    }

    if (context.mounted) {
      await showDialog<void>(context: context, builder: (_) => _ReportDialog(report: report, summary: summary));
    }
    return c;
  } on FormatException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('No se pudo importar: $e')));
  } finally {
    try {
      if (temp != null && temp.existsSync()) temp.deleteSync();
    } catch (_) {}
  }
  return null;
}

void Function() _showBusy(BuildContext context, String text) {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    ),
  );
  return () => nav.pop();
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.sizes});
  final Map<String, int> sizes;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  var progress = true, music = true, backgrounds = true, voiceModels = false, globalDocs = true;

  int _size(String k) => widget.sizes[k] ?? 0;

  Widget _switch(String title, String subtitle, bool value, ValueChanged<bool> onChanged, {bool enabled = true}) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(subtitle),
        value: value && enabled,
        onChanged: enabled ? (v) => setState(() => onChanged(v)) : null,
      );

  @override
  Widget build(BuildContext context) {
    final total = _size('mapas') +
        _size('documentos') +
        (music ? _size('musica') : 0) +
        (backgrounds ? _size('fondos') : 0) +
        (voiceModels ? _size('voces') : 0);
    return AlertDialog(
      title: const Text('Exportar campaña'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Siempre van la historia, los personajes, los PNJ con sus voces, el grafo, '
            'la memoria RAG con sus vectores, la documentación de la campaña y los mapas.',
          ),
          const SizedBox(height: 8),
          _switch('Partidas jugadas', 'Sesiones, registros, fichas y memoria del director. Sin esto, la historia queda sin empezar.',
              progress, (v) => progress = v),
          _switch('Música', _size('musica') == 0 ? 'La biblioteca está vacía' : 'Biblioteca por situaciones · ${_mb(_size('musica'))}',
              music, (v) => music = v, enabled: _size('musica') > 0),
          _switch('Fondos de escena', _size('fondos') == 0 ? 'No hay fondos puestos' : _mb(_size('fondos')), backgrounds,
              (v) => backgrounds = v, enabled: _size('fondos') > 0),
          _switch('Documentación general', 'Los documentos comunes que la IA también consulta', globalDocs, (v) => globalDocs = v),
          _switch(
            'Modelos de voz neuronal',
            _size('voces') == 0
                ? 'La campaña no usa voces neuronales instaladas'
                : '${_mb(_size('voces'))}. Sin ellos, el otro equipo los descarga desde Ajustes.',
            voiceModels,
            (v) => voiceModels = v,
            enabled: _size('voces') > 0,
          ),
          const SizedBox(height: 8),
          Text('Tamaño aproximado: ${_mb(total)} · El modelo de IA no se incluye.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            PackageOptions(
              progress: progress,
              music: music && _size('musica') > 0,
              backgrounds: backgrounds && _size('fondos') > 0,
              voiceModels: voiceModels && _size('voces') > 0,
              globalDocs: globalDocs,
            ),
          ),
          child: const Text('Exportar'),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.summary});
  final PackageSummary summary;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  var music = true, backgrounds = true, replaceBackgrounds = false, voiceModels = true, narrator = true, globalDocs = true;

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final lines = <String>[
      if (s.theme.isNotEmpty) 'Tema: ${s.theme}',
      '${s.players} jugadores · ${s.npcs} PNJ · ${s.maps} mapas',
      s.includesProgress ? '${s.sessions} sesiones jugadas' : 'Historia sin empezar',
      '${s.loreChunks} recuerdos en la memoria · ${s.documents} documentos',
      if (s.chatModel.isNotEmpty) 'Se jugó con el modelo ${s.chatModel}',
    ];
    Widget sw(String title, bool value, ValueChanged<bool> onChanged, {String? subtitle}) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          value: value,
          onChanged: (v) => setState(() => onChanged(v)),
        );
    return AlertDialog(
      title: Text('Importar «${s.title}»'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in lines) Text(l),
          const SizedBox(height: 8),
          if (s.tracks > 0) sw('Añadir su música (${s.tracks} pistas)', music, (v) => music = v),
          if (s.backgrounds > 0) ...[
            sw('Usar sus fondos de escena (${s.backgrounds})', backgrounds, (v) => backgrounds = v),
            if (backgrounds)
              sw('Reemplazar los fondos que ya tengo', replaceBackgrounds, (v) => replaceBackgrounds = v,
                  subtitle: 'Si no, sólo se rellenan los tipos de escena sin fondo'),
          ],
          if (s.includedVoicePacks > 0)
            sw('Instalar las voces neuronales incluidas (${s.includedVoicePacks})', voiceModels, (v) => voiceModels = v),
          if (s.hasNarrator)
            sw('Usar la voz de narrador de la campaña', narrator, (v) => narrator = v,
                subtitle: 'Cambia el narrador en Ajustes'),
          sw('Añadir la documentación general que traiga', globalDocs, (v) => globalDocs = v),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            ImportOptions(
              music: music,
              backgrounds: backgrounds,
              replaceBackgrounds: replaceBackgrounds,
              voiceModels: voiceModels,
              narrator: narrator,
              globalDocs: globalDocs,
            ),
          ),
          child: const Text('Importar'),
        ),
      ],
    );
  }
}

class _ReportDialog extends StatelessWidget {
  const _ReportDialog({required this.report, required this.summary});
  final ImportReport report;
  final PackageSummary summary;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final lines = <String>[
      'Campaña «${r.campaign.title}» creada.',
      if (r.tracks > 0 || r.tracksSkipped > 0)
        'Música: ${r.tracks} pistas añadidas${r.tracksSkipped > 0 ? ' (${r.tracksSkipped} ya estaban)' : ''}.',
      if (r.backgrounds > 0) 'Fondos de escena: ${r.backgrounds}.',
      if (r.documents > 0) 'Documentación: ${r.documents} documentos.',
      if (r.installedVoices.isNotEmpty) 'Voces instaladas: ${r.installedVoices.join(', ')}.',
      if (r.narratorApplied) 'Narrador: se usa el de la campaña.',
      if (r.missingVoices.isNotEmpty)
        'Faltan voces neuronales: ${r.missingVoices.join(', ')}. Descárgalas en Ajustes › Voces; mientras, esos personajes usan la voz del sistema.',
      if (r.needsReembed)
        'La memoria se creó con otro modelo de embeddings: se recalcula en segundo plano (mientras, busca por palabras).',
      if (r.chatModel.isNotEmpty) 'Se jugó con ${r.chatModel}; aquí se usará el modelo que tengas cargado.',
      ...r.warnings,
    ];
    return AlertDialog(
      title: const Text('Campaña importada'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l))],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Vale'))],
    );
  }
}
