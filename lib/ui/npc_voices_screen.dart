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

String _attitudeEmoji(int a) => switch (a) {
      <= -3 => '⚔️',
      -2 => '😠',
      -1 => '🤨',
      0 => '😐',
      1 => '🙂',
      2 => '😊',
      _ => '🤝',
    };

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
              child: Text('Cada PNJ tiene su voz, su objetivo y su actitud hacia el grupo, y sólo sabe lo que ha presenciado. La IA los actualiza al jugar; puedes ajustarlos.'),
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
                [
                  '${_attitudeEmoji(n.attitude)} ${n.attitudeName}${n.goal.isEmpty ? '' : ' · quiere: ${n.goal}'}',
                  n.description,
                  if (n.voiceHint.isNotEmpty) 'Voz: ${n.voiceHint}',
                ].where((e) => e.isNotEmpty).join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                // Actitud hacia el grupo.
                Row(children: [
                  const Text('Actitud'),
                  Expanded(
                    child: Slider(
                      value: n.attitude.toDouble().clamp(-3, 3),
                      min: -3,
                      max: 3,
                      divisions: 6,
                      label: n.attitudeName,
                      onChanged: (v) {
                        n.attitude = v.round();
                        s.db.updateNpcState(n);
                        setState(() {});
                      },
                    ),
                  ),
                  SizedBox(width: 90, child: Text('${_attitudeEmoji(n.attitude)} ${n.attitudeName}')),
                ]),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.flag_outlined),
                  title: Text(n.goal.isEmpty ? 'Sin objetivo conocido (toca para escribirlo)' : 'Quiere: ${n.goal}'),
                  onTap: () async {
                    final ctrl = TextEditingController(text: n.goal);
                    final v = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Objetivo de ${n.name}'),
                        content: TextField(controller: ctrl, autofocus: true, maxLines: 3),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
                        ],
                      ),
                    );
                    if (v != null) {
                      n.goal = v.trim();
                      s.db.updateNpcState(n);
                      setState(() {});
                    }
                  },
                ),
                if (n.knows.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    leading: const Icon(Icons.visibility_outlined),
                    title: Text('Lo que ha presenciado (${n.knows.length})'),
                    children: [
                      for (final k in n.knows.reversed)
                        ListTile(
                          dense: true,
                          title: Text(k),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              n.knows.remove(k);
                              s.db.updateNpcState(n);
                              setState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
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
