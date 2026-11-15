import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import '../core/scenes.dart';
import '../images/image_library.dart';
import 'widgets/image_widgets.dart';

/// Abre la galería como página (desde la mesa de juego).
Future<void> openGallery(BuildContext context, int campaignId) => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('Imágenes')), body: GalleryScreen(campaignId: campaignId)),
      ),
    );

/// Imágenes de apoyo de la campaña: las escenas de la historia y el retrato
/// y el cuerpo entero de cada PJ y PNJ. Desde aquí se ponen a mano, se
/// buscan las escenas que faltan y se genera lo que falte.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool _planning = false;

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _plan(ImageLibrary lib, Campaign c) async {
    setState(() => _planning = true);
    try {
      final n = await lib.planScenes(c);
      _snack(n == 0 ? 'No falta ninguna escena por apuntar' : 'Se han añadido $n escenas que faltaban');
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  Future<void> _generateAll(ImageLibrary lib, Campaign c) async {
    final why = lib.engineProblem;
    if (why != null) return _snack(why);
    final n = await lib.generateMissing(c);
    if (lib.lastError == null) _snack('Generadas $n imágenes');
  }

  Future<void> _addScene(ImageLibrary lib, Campaign c) async {
    final title = TextEditingController();
    final desc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva escena'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Título o lugar')),
          const SizedBox(height: 8),
          TextField(controller: desc, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Qué se ve (opcional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Añadir')),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      lib.ensureScene(c.id!, title.text, description: desc.text);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<ImageLibrary>();
    final s = context.read<AppServices>();
    final c = s.db.campaign(widget.campaignId);
    if (c == null) return const Center(child: Text('Campaña no encontrada'));
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final scenes = lib.scenes(c.id!);
    final people = lib.subjects(c);
    final missing = lib.missing(c);
    final problem = lib.engineProblem;
    final pinned = lib.pinned(c);

    Widget title(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(text, style: t.titleMedium?.copyWith(color: scheme.primary)),
        );

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        // ------------------------------------------------ estado y acciones
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(problem == null ? Icons.auto_awesome : Icons.info_outline, color: problem == null ? Colors.green : null),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(problem == null
                      ? 'Generador listo: ${lib.engine!.label}'
                      : '$problem. Mientras tanto puedes poner cada imagen a mano.'),
                ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                  icon: _planning
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.travel_explore),
                  label: const Text('Buscar escenas que faltan'),
                  onPressed: _planning ? null : () => _plan(lib, c),
                ),
                if (lib.busy)
                  OutlinedButton.icon(icon: const Icon(Icons.stop), label: const Text('Detener'), onPressed: lib.cancel)
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.brush),
                    label: Text(missing.isEmpty ? 'No falta ninguna imagen' : 'Generar las ${missing.length} que faltan'),
                    onPressed: missing.isEmpty || problem != null ? null : () => _generateAll(lib, c),
                  ),
                if (pinned != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.push_pin_outlined),
                    label: Text('Dejar de mostrar «${pinned.subject}» en la mesa'),
                    onPressed: () => lib.pin(c, null),
                  ),
              ]),
              if (lib.busy) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: lib.total <= 1 ? null : lib.done / lib.total),
                const SizedBox(height: 4),
                Text('${lib.current}… (${lib.done + 1} de ${lib.total})', style: t.bodySmall),
              ],
              if (lib.lastError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(child: Text(lib.lastError!, style: TextStyle(color: scheme.error))),
                    IconButton(icon: const Icon(Icons.close, size: 18), onPressed: lib.clearError),
                  ]),
                ),
            ]),
          ),
        ),

        // ----------------------------------------------------------- escenas
        Row(children: [
          Expanded(child: title('Escenas (${scenes.length})')),
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 12),
            child: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Añadir'), onPressed: () => _addScene(lib, c)),
          ),
        ]),
        if (scenes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Aún no hay escenas. Pulsa «Buscar escenas que faltan» para apuntar los lugares y momentos de '
                'la historia; durante la partida, cada lugar nuevo se añade solo.'),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LayoutBuilder(builder: (context, box) {
            final cols = (box.maxWidth / 260).floor().clamp(1, 6);
            final w = (box.maxWidth - (cols - 1) * 8) / cols;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in scenes) SizedBox(width: w, child: _sceneCard(lib, c, r, w, pinned?.id == r.id)),
            ]);
          }),
        ),

        // -------------------------------------------------------- personajes
        title('Personajes (${people.length})'),
        if (people.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Esta campaña aún no tiene personajes.')),
        for (final person in people)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CharacterImages(campaign: c, name: person.name, description: person.description, size: 84),
            title: Text(person.name),
            subtitle: Text(
              '${person.player ? 'Personaje jugador' : 'PNJ'}${person.description.isEmpty ? '' : ' · ${person.description}'}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _sceneCard(ImageLibrary lib, Campaign c, ImageRecord r, double w, bool pinned) {
    final kind = Scenes.byId(r.scene);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(children: [
          ImageSlot(
            campaign: c,
            kind: ImageRecord.sceneKind,
            subject: r.subject,
            width: w,
            height: w * 2 / 3,
            showLabel: false,
          ),
          if (pinned) const Positioned(right: 6, top: 6, child: Icon(Icons.push_pin, color: Colors.white, shadows: [Shadow(blurRadius: 4)])),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${kind == null ? '' : '${kind.icon} '}${r.subject}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  r.missing ? 'Falta la imagen${r.description.isEmpty ? '' : ' · ${r.description}'}' : (r.description.isEmpty ? r.origin : r.description),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            IconButton(
              tooltip: 'Borrar la escena',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => lib.remove(r, forget: true),
            ),
          ]),
        ),
      ]),
    );
  }
}
