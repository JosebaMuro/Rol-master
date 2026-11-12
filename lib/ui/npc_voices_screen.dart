import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import 'widgets/voice_editor.dart';

/// Lista de PNJ de la campaña con la voz asignada a cada uno.
class NpcVoicesScreen extends StatefulWidget {
  const NpcVoicesScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  State<NpcVoicesScreen> createState() => _NpcVoicesScreenState();
}

class _NpcVoicesScreenState extends State<NpcVoicesScreen> {
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final npcs = s.db.npcs(widget.campaignId);
    return ListView(
      padding: const EdgeInsets.only(bottom: 96, top: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Expanded(
              child: Text('Cada PNJ habla con su propia voz. La IA las asigna según género y edad; puedes ajustarlas.'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.shuffle),
              label: const Text('Reasignar todas'),
              onPressed: () {
                for (final n in npcs) {
                  n.voice = s.voices.assign(widget.campaignId, n.name, n.voiceHint);
                  s.db.upsertNpc(n);
                }
                setState(() {});
              },
            ),
          ]),
        ),
        for (final n in npcs)
          Card(
            child: ExpansionTile(
              leading: CircleAvatar(child: Text(n.name.characters.first)),
              title: Text(n.name),
              subtitle: Text(
                [n.description, if (n.voiceHint.isNotEmpty) 'Voz: ${n.voiceHint}'].where((e) => e.isNotEmpty).join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                VoiceEditor(
                  voice: n.voice,
                  sample: 'Soy ${n.name}. ${n.description.split('.').first}.',
                  onChanged: (v) {
                    n.voice = v;
                    s.db.upsertNpc(n);
                    setState(() {});
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Quitar PNJ'),
                    onPressed: () {
                      s.db.deleteNpc(n.id!);
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Añadir PNJ'),
            onPressed: () async {
              final ctrl = TextEditingController();
              final hint = TextEditingController();
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Nuevo PNJ'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Nombre')),
                    const SizedBox(height: 8),
                    TextField(controller: hint, decoration: const InputDecoration(labelText: 'Voz (p. ej. "anciana, ronca")')),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Añadir')),
                  ],
                ),
              );
              if (ok == true && ctrl.text.trim().isNotEmpty) {
                s.db.upsertNpc(Npc(
                  campaignId: widget.campaignId,
                  name: ctrl.text.trim(),
                  voiceHint: hint.text.trim(),
                  voice: s.voices.assign(widget.campaignId, ctrl.text.trim(), hint.text.trim()),
                ));
                s.graph.addEntity(widget.campaignId, ctrl.text.trim(), type: 'pnj');
                setState(() {});
              }
            },
          ),
        ),
      ],
    );
  }
}
