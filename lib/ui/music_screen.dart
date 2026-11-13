import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import '../music/music_service.dart';
import 'widgets/file_utils.dart';
import 'widgets/music_bar.dart';

/// Biblioteca musical organizada por situaciones.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  int? _filter; // null = todas, -1 = sin asignar

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final music = context.watch<MusicService>();
    final situations = s.db.situations();
    var tracks = s.db.tracks();
    if (_filter == -1) {
      tracks = tracks.where((t) => t.situationId == null).toList();
    } else if (_filter != null) {
      tracks = tracks.where((t) => t.situationId == _filter).toList();
    }
    final names = {for (final x in situations) x.id: x};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Música'),
        actions: [
          IconButton(tooltip: 'Situaciones', icon: const Icon(Icons.tune), onPressed: () => _editSituations(s)),
        ],
      ),
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.small(
          heroTag: 'folder',
          tooltip: 'Importar carpeta (subcarpetas = situaciones)',
          onPressed: () => _addFolder(music),
          child: const Icon(Icons.create_new_folder),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.extended(
          heroTag: 'files',
          icon: const Icon(Icons.library_add),
          label: const Text('Añadir pistas'),
          onPressed: () => _addFiles(s, music),
        ),
      ]),
      body: Column(children: [
        const MusicBar(),
        SizedBox(
          height: 52,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), children: [
            _chip('Todas', _filter == null, () => setState(() => _filter = null)),
            _chip('Sin situación', _filter == -1, () => setState(() => _filter = -1)),
            for (final x in situations) _chip('${x.icon} ${x.name}', _filter == x.id, () => setState(() => _filter = x.id)),
          ]),
        ),
        Expanded(
          child: tracks.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Añade tus pistas (mp3, ogg, wav, flac…) y asígnalas a situaciones. '
                      'Si importas una carpeta con subcarpetas llamadas como las situaciones '
                      '(Combate, Taberna, Misterio…), se asignan solas.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 140),
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final sit = names[t.situationId];
                    final playingThis = music.currentTrack?.id == t.id && music.playing;
                    return ListTile(
                      leading: IconButton(
                        icon: Icon(playingThis ? Icons.pause_circle : Icons.play_circle),
                        onPressed: () => playingThis ? music.pause() : music.playTrack(t, situation: sit),
                      ),
                      title: Text(t.title),
                      subtitle: Text(sit == null ? 'Sin situación' : '${sit.icon} ${sit.name}'),
                      trailing: PopupMenuButton<int>(
                        tooltip: 'Asignar situación',
                        icon: const Icon(Icons.label),
                        onSelected: (v) {
                          if (v == -2) {
                            music.removeTrack(t);
                          } else {
                            music.assign(t, v == -1 ? null : v);
                          }
                        },
                        itemBuilder: (_) => [
                          for (final x in situations) PopupMenuItem(value: x.id, child: Text('${x.icon} ${x.name}')),
                          const PopupMenuItem(value: -1, child: Text('Sin situación')),
                          const PopupMenuDivider(),
                          const PopupMenuItem(value: -2, child: Text('Quitar de la biblioteca (borra la copia)')),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
      );

  Future<void> _addFiles(AppServices s, MusicService music) async {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty) return;
    final paths = <String>[];
    for (final f in files) {
      final path = await localPathFor(f, s.dataRoot.tmp);
      if (path != null) paths.add(path);
    }
    final sid = (_filter != null && _filter! > 0) ? _filter : null;
    final added = await music.addFiles(paths, situationId: sid);
    for (final path in paths) {
      if (p.isWithin(s.dataRoot.tmp, path)) File(path).deleteSync();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${added.length} pistas añadidas')));
    }
  }

  Future<void> _addFolder(MusicService music) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    try {
      final n = await music.addFolder(dir);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n pistas importadas')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo leer la carpeta ($e). En Android usa «Añadir pistas».')),
        );
      }
    }
  }

  Future<void> _editSituations(AppServices s) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final list = s.db.situations();
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Situaciones', style: Theme.of(ctx).textTheme.titleLarge),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final x in list)
                  ListTile(
                    leading: Text(x.icon, style: const TextStyle(fontSize: 22)),
                    title: Text(x.name),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        s.db.deleteSituation(x.id!);
                        setS(() {});
                      },
                    ),
                    onTap: () async {
                      final r = await _situationDialog(x);
                      if (r != null) {
                        s.db.updateSituation(r);
                        setS(() {});
                      }
                    },
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Nueva situación'),
                onPressed: () async {
                  final r = await _situationDialog(Situation(name: '', icon: '🎵'));
                  if (r != null && r.name.isNotEmpty) {
                    s.db.addSituation(r.name, r.icon);
                    setS(() {});
                  }
                },
              ),
            ),
          ]),
        );
      }),
    );
    setState(() {});
  }

  Future<Situation?> _situationDialog(Situation x) async {
    final name = TextEditingController(text: x.name);
    final icon = TextEditingController(text: x.icon);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Situación'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
          TextField(controller: icon, decoration: const InputDecoration(labelText: 'Icono (emoji)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return null;
    return Situation(id: x.id, name: name.text.trim(), icon: icon.text.trim().isEmpty ? '🎵' : icon.text.trim(), sortOrder: x.sortOrder);
  }
}
