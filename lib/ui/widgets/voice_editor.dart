import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../voice/voice_packs.dart';
import '../../voice/voice_service.dart';

/// Editor de un perfil de voz (motor, voz, tono, velocidad) con botón de prueba.
class VoiceEditor extends StatelessWidget {
  const VoiceEditor({super.key, required this.voice, required this.onChanged, this.sample = 'Saludos, viajeros. ¿Qué os trae por aquí?'});
  final VoiceProfile voice;
  final ValueChanged<VoiceProfile> onChanged;
  final String sample;

  @override
  Widget build(BuildContext context) {
    final vs = context.watch<VoiceService>();
    final packs = context.watch<VoicePackManager>();
    final v = voice;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'system', label: Text('Sistema'), icon: Icon(Icons.record_voice_over)),
          ButtonSegment(value: 'neural', label: Text('Neuronal local'), icon: Icon(Icons.memory)),
        ],
        selected: {v.engine},
        onSelectionChanged: (s) => onChanged(v.copyWith(engine: s.first)),
      ),
      const SizedBox(height: 8),
      if (v.engine == 'system') ...[
        if (vs.systemVoices.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: vs.systemVoices.any((e) => e['name'] == v.systemVoice) ? v.systemVoice : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Voz del sistema'),
            items: [
              for (final sv in vs.systemVoices)
                DropdownMenuItem(value: sv['name'], child: Text('${sv['name']} (${sv['locale']})', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (name) {
              final sv = vs.systemVoices.firstWhere((e) => e['name'] == name);
              onChanged(v.copyWith(systemVoice: sv['name'], systemLocale: sv['locale']));
            },
          )
        else
          Text(vs.systemAvailable ? 'No se encontraron voces en español; se usará la predeterminada.' : 'TTS del sistema no disponible en esta plataforma.'),
        _slider('Tono', v.pitch, 0.5, 2.0, (x) => onChanged(v.copyWith(pitch: x))),
        _slider('Velocidad', v.rate, 0.2, 0.9, (x) => onChanged(v.copyWith(rate: x))),
      ] else ...[
        if (packs.installed.isEmpty)
          const Text('No hay voces neuronales instaladas. Descárgalas en Ajustes › Voces.')
        else ...[
          DropdownButtonFormField<String>(
            initialValue: packs.byId(v.neuralPack) != null ? v.neuralPack : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Paquete de voces'),
            items: [for (final p in packs.installed) DropdownMenuItem(value: p.id, child: Text(_label(p.id)))],
            onChanged: (id) => onChanged(v.copyWith(neuralPack: id)),
          ),
          if ((packs.byId(v.neuralPack)?.numSpeakers ?? 1) > 1)
            _slider(
              'Hablante nº ${v.speakerId}',
              v.speakerId.toDouble(),
              0,
              (packs.byId(v.neuralPack)!.numSpeakers - 1).toDouble(),
              (x) => onChanged(v.copyWith(speakerId: x.round())),
              divisions: packs.byId(v.neuralPack)!.numSpeakers - 1,
            ),
          _slider('Velocidad', v.speed, 0.6, 1.6, (x) => onChanged(v.copyWith(speed: x))),
        ],
      ],
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          icon: Icon(vs.speaking ? Icons.stop : Icons.play_arrow),
          label: Text(vs.speaking ? 'Parar' : 'Probar voz'),
          onPressed: () => vs.speaking ? vs.stop() : vs.speakAll([SpeechLine(sample, v)]),
        ),
      ),
    ]);
  }

  static String _label(String id) => voicePackCatalog.where((e) => e.id == id).firstOrNull?.label ?? id;

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged, {int? divisions}) {
    return Row(children: [
      SizedBox(width: 110, child: Text(label)),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ),
      SizedBox(width: 40, child: Text(divisions != null ? '' : value.toStringAsFixed(2))),
    ]);
  }
}
