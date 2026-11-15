import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models.dart';
import '../../core/scenes.dart';
import '../../core/settings.dart';
import '../../images/image_library.dart';
import '../gallery_screen.dart';
import '../map_viewer.dart';
import 'file_utils.dart';
import 'image_widgets.dart';

/// Clave en la biblia para fijar una escena a mano (se ignora la automática).
const pinnedSceneKey = '_escenaFija';

/// Escena que se muestra: la fijada a mano o la que dedujo el director.
SceneKind? currentScene(Campaign c) =>
    Scenes.byId(c.bible[pinnedSceneKey] as String?) ??
    Scenes.byId(c.bible[Scenes.bibleKey] as String?) ??
    (c.location.isEmpty ? null : Scenes.detect(c.location));

/// Elige una imagen y la guarda como fondo de [scene] dentro de la carpeta portable.
Future<bool> pickSceneBackground(BuildContext context, SceneKind scene) async {
  final s = context.read<AppServices>();
  final f = await FilePicker.pickFile(type: FileType.image, dialogTitle: 'Fondo para ${scene.name}');
  if (f == null) return false;
  final src = await localPathFor(f, s.dataRoot.tmp);
  if (src == null) return false;
  final dest = p.join(s.dataRoot.backgrounds, '${scene.id}_${DateTime.now().millisecondsSinceEpoch}${p.extension(src).toLowerCase()}');
  await File(src).copy(dest);
  if (p.isWithin(s.dataRoot.tmp, src)) {
    try {
      File(src).deleteSync();
    } catch (_) {}
  }
  _deleteOld(s, scene);
  s.settings.setSceneBackground(scene.id, s.dataRoot.toStored(dest));
  return true;
}

void removeSceneBackground(AppServices s, SceneKind scene) {
  _deleteOld(s, scene);
  s.settings.setSceneBackground(scene.id, '');
}

void _deleteOld(AppServices s, SceneKind scene) {
  final old = s.settings.sceneBackground(scene.id);
  if (old.isEmpty) return;
  final path = s.dataRoot.resolve(old);
  if (p.isWithin(s.dataRoot.backgrounds, path)) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

/// Imagen de fondo de una escena, o null si no tiene.
File? sceneBackgroundFile(AppServices s, String sceneId) {
  final stored = s.settings.sceneBackground(sceneId);
  if (stored.isEmpty) return null;
  final f = File(s.dataRoot.resolve(stored));
  return f.existsSync() ? f : null;
}

/// Panel gráfico superior de la partida: fondo de la escena actual o el mapa.
class ScenePanel extends StatelessWidget {
  const ScenePanel({
    super.key,
    required this.campaign,
    required this.onCampaignChanged,
    this.map,
    this.showMap = false,
    this.onToggleMap,
    this.overlay,
  });

  final Campaign campaign;
  final VoidCallback onCampaignChanged;
  final MapRecord? map;
  final bool showMap;
  final VoidCallback? onToggleMap;
  /// Algo que se pinta encima, abajo (p. ej. quién está hablando).
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    context.watch<AppSettings>(); // repinta al cambiar un fondo
    final lib = context.watch<ImageLibrary>(); // …o al llegar una imagen generada
    final s = context.read<AppServices>();
    final scheme = Theme.of(context).colorScheme;
    final scene = currentScene(campaign);
    final pinned = Scenes.byId(campaign.bible[pinnedSceneKey] as String?) != null;
    // Qué se enseña: la imagen fijada a mano, la de este lugar de la
    // historia o, si no hay, el fondo genérico del tipo de escena.
    final shown = lib.pinned(campaign) ?? lib.sceneFor(campaign);
    final shownFile = ImageLibrary.fileFor(shown);
    final fixedImage = lib.pinned(campaign) != null;
    final kindBg = scene == null ? null : sceneBackgroundFile(s, scene.id);
    final bg = shownFile ?? kindBg;
    final pending = campaign.location.isEmpty || shownFile != null ? null : lib.find(campaign.id!, ImageRecord.sceneKind, campaign.location);
    final drawing = lib.busy && pending != null && lib.current.endsWith(' de ${pending.subject}');
    final mapFile = map == null ? null : File(map!.imagePath);
    final viewingMap = showMap && mapFile != null && mapFile.existsSync();

    Widget content;
    if (viewingMap) {
      content = GestureDetector(
        onTap: () => openMapFullscreen(context, map!),
        child: Container(
          color: const Color(0xFF1B1712),
          child: InteractiveViewer(child: Image.file(mapFile, fit: BoxFit.contain, width: double.infinity)),
        ),
      );
    } else if (bg != null) {
      // Los personajes (retrato, cuerpo entero) se ven enteros; las escenas llenan el panel.
      final whole = shown != null && !shown.isScene;
      content = GestureDetector(
        onTap: shownFile == null ? null : () => openImageFullscreen(context, shownFile, title: shown!.subject),
        child: Container(
          color: const Color(0xFF1B1712),
          child: Image.file(
            bg,
            key: ValueKey(bg.path),
            fit: whole ? BoxFit.contain : BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, _, _) => _placeholder(context, scene),
          ),
        ),
      );
    } else {
      content = _placeholder(context, scene);
    }

    return ClipRect(
      child: Stack(fit: StackFit.expand, children: [
        AnimatedSwitcher(duration: const Duration(milliseconds: 600), child: KeyedSubtree(key: ValueKey('${viewingMap}_${bg?.path}_${scene?.id}'), child: content)),
        // Degradado para que se lean los rótulos sobre cualquier imagen.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x66000000), Color(0x00000000), Color(0x00000000), Color(0x99000000)],
                stops: [0, 0.25, 0.6, 1],
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 8,
          right: 120,
          child: Text(
            [
              if (fixedImage) '📌 ${shown!.subject}',
              if (scene != null) '${scene.icon} ${scene.name}${pinned ? ' 📌' : ''}',
              if (campaign.location.isNotEmpty) campaign.location,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)]),
          ),
        ),
        Positioned(
          right: 4,
          top: 0,
          child: Row(children: [
            if (mapFile != null)
              IconButton(
                tooltip: viewingMap ? 'Ver la escena' : 'Ver el mapa',
                color: Colors.white,
                icon: Icon(viewingMap ? Icons.landscape : Icons.map),
                onPressed: onToggleMap,
              ),
            PopupMenuButton<String>(
              tooltip: 'Escena y fondo',
              iconColor: Colors.white,
              icon: const Icon(Icons.wallpaper),
              onSelected: (v) => _onMenu(context, s, scene, v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'gallery', child: Text('Galería de imágenes…')),
                if (fixedImage) const PopupMenuItem(value: 'unpin', child: Text('Dejar de mostrar la imagen fijada')),
                if (campaign.location.isNotEmpty) ...[
                  PopupMenuItem(value: 'genplace', child: Text(shownFile == null || fixedImage ? 'Generar imagen de este lugar' : 'Generar otra imagen de este lugar')),
                  const PopupMenuItem(value: 'pickplace', child: Text('Elegir imagen para este lugar…')),
                ],
                const PopupMenuDivider(),
                if (scene != null) ...[
                  PopupMenuItem(value: 'pick', child: Text('Elegir fondo genérico de ${scene.name}')),
                  if (kindBg != null) PopupMenuItem(value: 'remove', child: Text('Quitar fondo genérico de ${scene.name}')),
                  const PopupMenuDivider(),
                ],
                PopupMenuItem(
                  value: 'auto',
                  child: Row(children: [
                    Icon(pinned ? Icons.radio_button_unchecked : Icons.radio_button_checked, size: 18),
                    const SizedBox(width: 8),
                    const Text('Cambiar sola según el lugar'),
                  ]),
                ),
                for (final k in Scenes.kinds)
                  PopupMenuItem(
                    value: 'pin:${k.id}',
                    child: Row(children: [
                      Icon(pinned && scene?.id == k.id ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                      const SizedBox(width: 8),
                      Text('Fijar ${k.icon} ${k.name}'),
                      if (sceneBackgroundFile(s, k.id) != null) ...[const Spacer(), const Icon(Icons.image, size: 16)],
                    ]),
                  ),
              ],
            ),
          ]),
        ),
        if (drawing)
          const Positioned(
            right: 12,
            top: 48,
            child: Chip(
              avatar: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              label: Text('Dibujando la escena…'),
            ),
          ),
        if (overlay != null) Positioned(left: 0, right: 0, bottom: 0, child: overlay!),
        if (!viewingMap && scene != null && bg == null)
          Positioned(
            left: 0,
            right: 0,
            bottom: overlay == null ? 12 : 56,
            child: Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
                icon: const Icon(Icons.add_photo_alternate),
                label: Text('Poner imagen de fondo para ${scene.name}'),
                onPressed: () => _onMenu(context, s, scene, 'pick'),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _placeholder(BuildContext context, SceneKind? scene) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHighest, scheme.primaryContainer],
        ),
      ),
      alignment: Alignment.center,
      child: Text(scene?.icon ?? '🎲', style: const TextStyle(fontSize: 72)),
    );
  }

  Future<void> _onMenu(BuildContext context, AppServices s, SceneKind? scene, String v) async {
    if (v == 'gallery') {
      await openGallery(context, campaign.id!);
      onCampaignChanged();
    } else if (v == 'unpin') {
      s.images.pin(campaign, null);
      onCampaignChanged();
    } else if (v == 'genplace') {
      final rec = s.images.ensureScene(campaign.id!, campaign.location, scene: scene?.id ?? '');
      await generateImage(context, campaign, rec, fresh: !rec.missing);
    } else if (v == 'pickplace') {
      await pickImageFor(context, campaign.id!, ImageRecord.sceneKind, campaign.location);
    } else if (v == 'pick' && scene != null) {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await pickSceneBackground(context, scene);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('No se pudo usar la imagen: $e')));
      }
    } else if (v == 'remove' && scene != null) {
      removeSceneBackground(s, scene);
    } else if (v == 'auto') {
      campaign.bible.remove(pinnedSceneKey);
      s.db.updateCampaign(campaign);
      onCampaignChanged();
    } else if (v.startsWith('pin:')) {
      campaign.bible[pinnedSceneKey] = v.substring(4);
      s.db.updateCampaign(campaign);
      onCampaignChanged();
    }
  }
}
