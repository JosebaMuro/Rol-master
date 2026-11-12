import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/models.dart';
import '../../music/music_service.dart';

/// Menú de situaciones: el usuario elige qué música suena.
Future<void> showSituationMenu(BuildContext context, {String? suggested}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _SituationMenu(suggested: suggested),
  );
}

class _SituationMenu extends StatelessWidget {
  const _SituationMenu({this.suggested});
  final String? suggested;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final music = context.watch<MusicService>();
    final situations = s.db.situations();
    final suggestedSituation = suggested == null ? null : music.situationByName(suggested!);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('¿Qué música suena?', style: Theme.of(context).textTheme.titleLarge),
          if (suggestedSituation != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('La IA sugiere: ${suggestedSituation.icon} ${suggestedSituation.name}'),
            ),
          const SizedBox(height: 12),
          Flexible(
            child: GridView.extent(
              shrinkWrap: true,
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.4,
              children: [
                for (final sit in situations) _tile(context, s, music, sit, sit.id == suggestedSituation?.id),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.volume_down),
            Expanded(child: Slider(value: s.settings.musicVolume, onChanged: music.setVolume)),
            TextButton.icon(
              icon: const Icon(Icons.stop),
              label: const Text('Silencio'),
              onPressed: () {
                music.stop();
                Navigator.pop(context);
              },
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _tile(BuildContext context, AppServices s, MusicService music, Situation sit, bool suggested) {
    final count = s.db.tracks(situationId: sit.id).length;
    final active = music.currentSituation?.id == sit.id && music.playing;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.primaryContainer : (suggested ? scheme.secondaryContainer : scheme.surfaceContainerHigh),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: count == 0
            ? () => ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('No hay pistas en «${sit.name}». Añádelas en la pestaña Música.')),
                )
            : () {
                music.playSituation(sit);
                Navigator.pop(context);
              },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(sit.icon, style: const TextStyle(fontSize: 28)),
            Text(sit.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('$count pistas', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}

/// Mini reproductor que aparece en la pantalla de partida.
class MusicBar extends StatelessWidget {
  const MusicBar({super.key, this.suggestion, this.onDismissSuggestion});
  final String? suggestion;
  final VoidCallback? onDismissSuggestion;

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicService>();
    final sug = suggestion == null ? null : music.situationByName(suggestion!);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: [
          IconButton(
            tooltip: 'Elegir música por situación',
            icon: const Icon(Icons.queue_music),
            onPressed: () => showSituationMenu(context, suggested: suggestion),
          ),
          Expanded(
            child: Text(
              music.currentTrack == null
                  ? 'Sin música'
                  : '${music.currentSituation?.icon ?? '🎵'} ${music.currentSituation?.name ?? ''} · ${music.currentTrack!.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (sug != null && sug.id != music.currentSituation?.id)
            ActionChip(
              avatar: Text(sug.icon),
              label: Text('¿${sug.name}?'),
              tooltip: 'La IA sugiere esta música. Pulsa para ponerla.',
              onPressed: () {
                music.playSituation(sug);
                onDismissSuggestion?.call();
              },
            ),
          if (music.currentTrack != null) ...[
            IconButton(
              icon: Icon(music.playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => music.playing ? music.pause() : music.resume(),
            ),
            IconButton(icon: const Icon(Icons.skip_next), onPressed: music.skip),
          ],
        ]),
      ),
    );
  }
}
