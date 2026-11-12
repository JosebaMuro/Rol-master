import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../maps/map_service.dart';
import 'map_viewer.dart';

class MapsScreen extends StatelessWidget {
  const MapsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final service = context.watch<MapService>();
    final maps = s.db.maps();
    final campaigns = {for (final c in s.db.campaigns()) c.id: c.title};
    return Scaffold(
      appBar: AppBar(title: const Text('Mapas')),
      floatingActionButton: FloatingActionButton.extended(
        icon: service.busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_location_alt),
        label: const Text('Generar mapa'),
        onPressed: service.busy
            ? null
            : () async {
                final rec = await showCreateMapDialog(context);
                if (rec != null && context.mounted) openMapFullscreen(context, rec);
              },
      ),
      body: maps.isEmpty
          ? const Center(child: Text('Genera mazmorras, criptas y cuevas.\nTambién aparecen solas cuando la IA las pide en partida.', textAlign: TextAlign.center))
          : GridView.extent(
              maxCrossAxisExtent: 320,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.2,
              children: [
                for (final m in maps)
                  Card(
                    clipBehavior: Clip.antiAlias,
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      onTap: () => openMapFullscreen(context, m),
                      onLongPress: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('¿Borrar «${m.title}»?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
                            ],
                          ),
                        );
                        if (ok == true) service.delete(m);
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: File(m.imagePath).existsSync()
                              ? Image.file(File(m.imagePath), fit: BoxFit.cover, cacheWidth: 640)
                              : const Icon(Icons.broken_image),
                        ),
                        ListTile(
                          dense: true,
                          title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${m.kind}${m.campaignId != null ? ' · ${campaigns[m.campaignId] ?? ''}' : ''}'),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
