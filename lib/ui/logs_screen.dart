import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import 'widgets/rich_message.dart';

/// Registro de todas las partidas, organizado por jugador y por tema.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Registro de partidas'),
          bottom: const TabBar(tabs: [Tab(text: 'Por jugador'), Tab(text: 'Por tema')]),
        ),
        body: TabBarView(children: [
          ListView(children: [
            for (final p in s.db.players())
              _Group(title: p.name, icon: Icons.person, campaigns: s.db.campaignsForPlayer(p.id!), showTheme: true),
            if (s.db.players().isEmpty) const _Empty(),
          ]),
          ListView(children: [
            for (final t in s.db.themes())
              _Group(title: t, icon: Icons.category, campaigns: s.db.campaignsForTheme(t)),
            if (s.db.themes().isEmpty) const _Empty(),
          ]),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.all(32), child: Text('Todavía no hay partidas registradas.', textAlign: TextAlign.center));
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.icon, required this.campaigns, this.showTheme = false});
  final String title;
  final IconData icon;
  final List<Campaign> campaigns;
  final bool showTheme;

  @override
  Widget build(BuildContext context) {
    final byTheme = <String, List<Campaign>>{};
    for (final c in campaigns) {
      byTheme.putIfAbsent(showTheme ? c.theme : '', () => []).add(c);
    }
    return Card(
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text('${campaigns.length} campañas'),
        children: [
          for (final e in byTheme.entries) ...[
            if (e.key.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(alignment: Alignment.centerLeft, child: Text(e.key, style: Theme.of(context).textTheme.labelLarge)),
              ),
            for (final c in e.value) SessionsList(campaign: c, compact: true),
          ],
        ],
      ),
    );
  }
}

/// Lista de sesiones de una campaña con acceso al registro de cada una.
class SessionsList extends StatelessWidget {
  const SessionsList({super.key, required this.campaign, this.compact = false});
  final Campaign campaign;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final sessions = s.db.sessions(campaign.id!);
    final tiles = [
      for (final ses in sessions.reversed)
        ListTile(
          leading: CircleAvatar(child: Text('${ses.number}')),
          title: Text(compact ? '${campaign.title} · Sesión ${ses.number}' : 'Sesión ${ses.number}'),
          subtitle: Text(
            ses.summary.isEmpty ? _date(ses.startedAt) + (ses.endedAt == null ? ' · en curso' : '') : ses.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LogReaderScreen(campaign: campaign, session: ses)),
          ),
        ),
    ];
    if (compact) {
      return Column(children: [
        ...tiles,
        ListTile(
          leading: const Icon(Icons.question_answer),
          title: Text('Preguntar sobre «${campaign.title}»'),
          onTap: () => askLogsDialog(context, campaign),
        ),
      ]);
    }
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      ListTile(
        leading: const Icon(Icons.question_answer),
        title: const Text('Preguntar a la IA sobre partidas anteriores'),
        subtitle: const Text('«¿Qué nos dijo el herrero en la sesión 2?»'),
        onTap: () => askLogsDialog(context, campaign),
      ),
      ...tiles,
      if (sessions.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Aún no se ha jugado ninguna sesión.')),
    ]);
  }

  static String _date(DateTime d) => '${d.day}/${d.month}/${d.year}';
}

Future<void> askLogsDialog(BuildContext context, Campaign c) async {
  final s = context.read<AppServices>();
  if (!s.llm.isReady) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Carga un modelo en Ajustes')));
    return;
  }
  final q = TextEditingController();
  final question = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Pregunta sobre «${c.title}»'),
      content: TextField(controller: q, autofocus: true, maxLines: 3),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, q.text), child: const Text('Preguntar')),
      ],
    ),
  );
  if (question == null || question.trim().isEmpty || !context.mounted) return;
  final answer = ValueNotifier('');
  final stream = s.director().askAboutLogs(c, question);
  final sub = stream.listen((t) => answer.value += t);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(question),
      content: ValueListenableBuilder(
        valueListenable: answer,
        builder: (_, v, _) => SingleChildScrollView(child: v.isEmpty ? const LinearProgressIndicator() : Text(v)),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
    ),
  );
  await sub.cancel();
}

class LogReaderScreen extends StatelessWidget {
  const LogReaderScreen({super.key, required this.campaign, required this.session});
  final Campaign campaign;
  final GameSession session;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final msgs = s.db.messagesForSession(session.id!);
    return Scaffold(
      appBar: AppBar(
        title: Text('${campaign.title} · Sesión ${session.number}'),
        actions: [
          IconButton(
            tooltip: 'Guardar como Markdown',
            icon: const Icon(Icons.save_alt),
            onPressed: () async {
              final paths = await s.logs.writeSession(campaign, session);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Guardado en ${paths.first}')));
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (session.summary.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Resumen', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(session.summary),
              ]),
            ),
          ),
        for (final m in msgs) MessageBubble(message: m),
      ]),
    );
  }
}
