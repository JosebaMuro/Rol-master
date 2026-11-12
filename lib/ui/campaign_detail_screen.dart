import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import 'graph_screen.dart';
import 'logs_screen.dart';
import 'npc_voices_screen.dart';
import 'play_screen.dart';

class CampaignDetailScreen extends StatefulWidget {
  const CampaignDetailScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  State<CampaignDetailScreen> createState() => _CampaignDetailScreenState();
}

class _CampaignDetailScreenState extends State<CampaignDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final c = s.db.campaign(widget.campaignId);
    if (c == null) return const Scaffold(body: Center(child: Text('Campaña no encontrada')));
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.title),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'delete') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Borrar campaña?'),
                      content: const Text('Se borrarán sesiones, PNJ, memoria y mapas de esta campaña.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    s.db.deleteCampaign(c.id!);
                    Navigator.pop(context);
                  }
                } else if (v == 'export') {
                  final path = await s.logs.exportCampaign(c);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exportado a $path')));
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'export', child: Text('Exportar registro (Markdown)')),
                PopupMenuItem(value: 'delete', child: Text('Borrar campaña')),
              ],
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Historia'),
            Tab(text: 'PNJ y voces'),
            Tab(text: 'Grafo'),
            Tab(text: 'Sesiones'),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.play_arrow),
          label: Text(s.db.lastSession(c.id!) == null ? 'Empezar partida' : 'Continuar partida'),
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayScreen(campaignId: c.id!)));
            setState(() {});
          },
        ),
        body: TabBarView(children: [
          _BibleTab(campaign: c),
          NpcVoicesScreen(campaignId: c.id!),
          GraphScreen(campaignId: c.id!),
          SessionsList(campaign: c),
        ]),
      ),
    );
  }
}

class _BibleTab extends StatelessWidget {
  const _BibleTab({required this.campaign});
  final Campaign campaign;

  @override
  Widget build(BuildContext context) {
    final c = campaign;
    final b = c.bible;
    final t = Theme.of(context).textTheme;
    Widget section(String title, Widget child) => Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 6),
            child,
          ]),
        );
    List<String> strings(Object? v) => v is List ? v.map((e) => '$e').toList() : const [];
    final villain = b['villain'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        Text('${c.theme} · ${c.tone}', style: t.bodySmall),
        if (c.premise.isNotEmpty) section('Premisa', Text(c.premise)),
        if ((b['hook'] ?? '').toString().isNotEmpty) section('Gancho', Text('${b['hook']}')),
        if (c.setting.isNotEmpty) section('Ambientación', Text(c.setting)),
        if (c.location.isNotEmpty) section('Ubicación actual', Text(c.location)),
        if (c.acts.isNotEmpty)
          section(
            'Actos',
            Column(children: [
              for (var i = 0; i < c.acts.length; i++)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: i == c.currentAct ? Theme.of(context).colorScheme.primary : null,
                      child: Text('${i + 1}'),
                    ),
                    title: Text('${c.acts[i]['title']}'),
                    subtitle: Text('${c.acts[i]['summary']}\nObjetivo: ${c.acts[i]['goal']}\nGiro: ${c.acts[i]['twist']}'),
                  ),
                ),
            ]),
          ),
        if (villain is Map)
          section('Antagonista', Text('${villain['name']}: ${villain['motivation']}\nPlan: ${villain['plan']}')),
        if (strings(b['secrets']).isNotEmpty)
          section('Secretos (sólo para el máster)', Text(strings(b['secrets']).map((e) => '• $e').join('\n'))),
        if (strings(b['clues']).isNotEmpty) section('Pistas', Text(strings(b['clues']).map((e) => '• $e').join('\n'))),
        if (strings(b['endings']).isNotEmpty)
          section('Finales posibles', Text(strings(b['endings']).map((e) => '• $e').join('\n'))),
        if (c.memory.isNotEmpty) section('Memoria del director', Text(c.memory)),
      ],
    );
  }
}
