import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import '../maps/dungeon_generator.dart';

/// Abre un mapa a pantalla completa (modo inmersivo, zoom y desplazamiento).
Future<void> openMapFullscreen(BuildContext context, MapRecord map) {
  return Navigator.push(
    context,
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => MapViewer(map: map)),
  );
}

class MapViewer extends StatefulWidget {
  const MapViewer({super.key, required this.map});
  final MapRecord map;

  @override
  State<MapViewer> createState() => _MapViewerState();
}

class _MapViewerState extends State<MapViewer> {
  bool _chrome = true;
  final _ctrl = TransformationController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.map.roomKey;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _chrome = !_chrome),
            onDoubleTap: () => _ctrl.value = Matrix4.identity(),
            child: InteractiveViewer(
              transformationController: _ctrl,
              minScale: 0.3,
              maxScale: 8,
              boundaryMargin: const EdgeInsets.all(200),
              child: Center(child: Image.file(File(widget.map.imagePath), filterQuality: FilterQuality.medium)),
            ),
          ),
        ),
        if (_chrome)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                color: Colors.black54,
                child: Row(children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  Expanded(child: Text(widget.map.title, style: Theme.of(context).textTheme.titleLarge)),
                  if (key.isNotEmpty)
                    IconButton(
                      tooltip: 'Leyenda de salas',
                      icon: const Icon(Icons.list_alt),
                      onPressed: () => _showKey(key),
                    ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  void _showKey(List<Map<String, dynamic>> key) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, sc) => ListView(controller: sc, children: [
          for (final r in key)
            ListTile(
              leading: CircleAvatar(child: Text('${r['n']}')),
              title: Text('${r['title']}'),
              subtitle: (r['text'] ?? '').toString().isEmpty ? null : Text('${r['text']}'),
            ),
        ]),
      ),
    );
  }
}

/// Diálogo para generar un mapa a mano.
Future<MapRecord?> showCreateMapDialog(BuildContext context, {Campaign? campaign}) async {
  final s = context.read<AppServices>();
  final title = TextEditingController(text: 'Mazmorra sin nombre');
  var kind = 'mazmorra';
  var rooms = 12.0;
  var describe = s.llm.isReady;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Generar mapa'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Título')),
          const SizedBox(height: 12),
          // Cinco tipos no caben en una fila en el móvil: fichas que saltan de línea.
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in DungeonGenerator.kinds.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: kind == e.key,
                onSelected: (_) => setD(() {
                  if (title.text == '${DungeonGenerator.kinds[kind]} sin nombre') title.text = '${e.value} sin nombre';
                  kind = e.key;
                }),
              ),
          ]),
          if (kind == 'mazmorra')
            Row(children: [
              const Text('Salas'),
              Expanded(
                child: Slider(value: rooms, min: 4, max: 24, divisions: 20, label: '${rooms.round()}', onChanged: (v) => setD(() => rooms = v)),
              ),
            ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(kind == 'pueblo' ? 'Describir lugares con IA' : 'Describir salas con IA'),
            value: describe,
            onChanged: s.llm.isReady ? (v) => setD(() => describe = v) : null,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Generar')),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  return s.maps.create(
    kind: kind,
    title: title.text.trim().isEmpty ? 'Mapa' : title.text.trim(),
    campaign: campaign,
    rooms: rooms.round(),
    describeWithAi: describe,
  );
}
