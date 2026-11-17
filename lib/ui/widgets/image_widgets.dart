import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models.dart';
import '../../images/image_library.dart';
import 'file_utils.dart';

/// Abre una imagen a pantalla completa (zoom y desplazamiento).
Future<void> openImageFullscreen(BuildContext context, File file, {String title = ''}) => Navigator.push(
      context,
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ImageViewer(file: file, title: title)),
    );

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.file, required this.title});
  final File file;
  final String title;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _chrome = !_chrome),
            onDoubleTap: () => _ctrl.value = Matrix4.identity(),
            child: InteractiveViewer(
              transformationController: _ctrl,
              minScale: 0.5,
              maxScale: 8,
              child: Center(child: Image.file(widget.file, filterQuality: FilterQuality.medium)),
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
                  Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Deja elegir un fichero de imagen y lo guarda como la imagen de ese tipo
/// y sujeto. Devuelve true si se ha puesto.
Future<bool> pickImageFor(BuildContext context, int campaignId, String kind, String subject) async {
  final s = context.read<AppServices>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final f = await FilePicker.pickFile(type: FileType.image, dialogTitle: '${ImageRecord.kindNames[kind]} de $subject');
    if (f == null) return false;
    final src = await localPathFor(f, s.dataRoot.tmp);
    if (src == null) return false;
    await s.images.setFromFile(campaignId, kind, subject, src);
    if (p.isWithin(s.dataRoot.tmp, src)) {
      try {
        File(src).deleteSync();
      } catch (_) {}
    }
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('No se pudo usar la imagen: $e')));
    return false;
  }
}

/// Edita la descripción con la que se dibuja una imagen.
Future<void> editImageDescription(BuildContext context, ImageRecord r) async {
  final s = context.read<AppServices>();
  final ctrl = TextEditingController(text: r.description);
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Qué se ve: ${r.subject}'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(helperText: 'Aspecto, ropa, lugar, luz… El generador dibuja a partir de esto.', helperMaxLines: 2),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
      ],
    ),
  );
  if (v != null) s.images.updateDescription(r, v);
}

/// Lanza la generación de una imagen y avisa si no se puede.
Future<void> generateImage(BuildContext context, Campaign c, ImageRecord r, {bool fresh = false}) async {
  final s = context.read<AppServices>();
  final messenger = ScaffoldMessenger.of(context);
  final why = s.images.engineProblem;
  if (why != null) {
    messenger.showSnackBar(SnackBar(content: Text(why)));
    return;
  }
  if (s.images.busy) {
    messenger.showSnackBar(const SnackBar(content: Text('Ya se está generando otra imagen: espera a que termine')));
    return;
  }
  final n = await s.images.generateOne(c, r, fresh: fresh);
  if (n == 0 && s.images.lastError != null) {
    messenger.showSnackBar(SnackBar(content: Text(s.images.lastError!), duration: const Duration(seconds: 8)));
  }
}

/// Miniatura de una imagen de apoyo (o el hueco para ponerla) con su menú:
/// ver, elegir de un fichero, generar, describir y quitar.
class ImageSlot extends StatelessWidget {
  const ImageSlot({
    super.key,
    required this.campaign,
    required this.kind,
    required this.subject,
    this.description = '',
    this.width = 96,
    this.height = 96,
    this.showLabel = true,
  });

  final Campaign campaign;
  final String kind;
  final String subject;

  /// Descripción inicial si aún no hay registro (la ficha o la del PNJ).
  final String description;
  final double width;
  final double height;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<ImageLibrary>();
    final scheme = Theme.of(context).colorScheme;
    final rec = lib.find(campaign.id!, kind, subject);
    final file = ImageLibrary.fileFor(rec);
    final label = ImageRecord.kindNames[kind]!;
    final drawing = lib.busy && lib.current == '$label de $subject';

    ImageRecord record() =>
        rec ??
        ImageRecord(
          campaignId: campaign.id!,
          kind: kind,
          subject: subject,
          description: description.isNotEmpty || kind == ImageRecord.sceneKind ? description : lib.descriptionOf(campaign, subject),
        );

    Future<void> onMenu(String v) async {
      switch (v) {
        case 'view':
          if (file != null) await openImageFullscreen(context, file, title: '$subject · $label');
        case 'pick':
          await pickImageFor(context, campaign.id!, kind, subject);
        case 'generate':
          await generateImage(context, campaign, record(), fresh: file != null);
        case 'describe':
          final r = record();
          if (r.id == null) context.read<AppServices>().db.saveImage(r);
          await editImageDescription(context, r);
        case 'show':
          if (rec != null) lib.pin(campaign, rec);
        case 'remove':
          if (rec != null) lib.remove(rec);
      }
    }

    return PopupMenuButton<String>(
      tooltip: '$label de $subject',
      onSelected: onMenu,
      itemBuilder: (_) => [
        if (file != null) const PopupMenuItem(value: 'view', child: Text('Ver a pantalla completa')),
        if (file != null) const PopupMenuItem(value: 'show', child: Text('Mostrar en la mesa')),
        PopupMenuItem(value: 'pick', child: Text(file == null ? 'Elegir una imagen…' : 'Cambiar por otra imagen…')),
        PopupMenuItem(value: 'generate', child: Text(file == null ? 'Generar' : 'Generar otra distinta')),
        const PopupMenuItem(value: 'describe', child: Text('Describir qué se ve…')),
        if (file != null) const PopupMenuItem(value: 'remove', child: Text('Quitar imagen')),
      ],
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(fit: StackFit.expand, children: [
              if (file != null)
                Image.file(file, key: ValueKey(file.path), fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.broken_image))
              else
                Container(
                  color: scheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    kind == ImageRecord.portrait
                        ? Icons.face
                        : kind == ImageRecord.fullBody
                            ? Icons.accessibility_new
                            : Icons.landscape,
                    size: 32,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (drawing) Container(color: Colors.black45, alignment: Alignment.center, child: const CircularProgressIndicator()),
            ]),
          ),
        ),
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
      ]),
    );
  }
}

/// Retrato y cuerpo entero de un personaje (PJ o PNJ), uno junto al otro.
class CharacterImages extends StatelessWidget {
  const CharacterImages({super.key, required this.campaign, required this.name, this.description = '', this.size = 96});
  final Campaign campaign;
  final String name;
  final String description;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      ImageSlot(campaign: campaign, kind: ImageRecord.portrait, subject: name, description: description, width: size, height: size),
      const SizedBox(width: 8),
      ImageSlot(campaign: campaign, kind: ImageRecord.fullBody, subject: name, description: description, width: size * 2 / 3, height: size),
    ]);
  }
}

/// Avatar redondo con el retrato del personaje (o su inicial si no tiene).
class PortraitAvatar extends StatelessWidget {
  const PortraitAvatar({super.key, required this.campaignId, required this.name, this.radius = 20});
  final int campaignId;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final file = context.watch<ImageLibrary>().fileOf(campaignId, ImageRecord.portrait, name);
    if (file != null) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(file));
    }
    return CircleAvatar(radius: radius, child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()));
  }
}
