import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';
import '../core/story_package.dart';
import 'campaign_detail_screen.dart';
import 'new_campaign_screen.dart';

class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({super.key});

  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final campaigns = s.db.campaigns();
    return Scaffold(
      appBar: AppBar(title: const Text('Campañas'), actions: [
        IconButton(
          tooltip: 'Importar historia (.rolpack)',
          icon: const Icon(Icons.file_open),
          onPressed: () => _import(s),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Nueva campaña'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const NewCampaignScreen()));
          setState(() {});
        },
      ),
      body: campaigns.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Aún no hay campañas.\nPulsa «Nueva campaña» y la IA inventará una historia completa para tu grupo.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 96, top: 8),
              children: [for (final c in campaigns) _tile(context, s, c)],
            ),
    );
  }

  Future<void> _import(AppServices s) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await FilePicker.pickFile(dialogTitle: 'Importar historia');
      if (f == null) return;
      final bytes = f.path != null && File(f.path!).existsSync()
          ? await File(f.path!).readAsBytes()
          : await f.xFile.readAsBytes();
      final c = StoryPackage.import(s.db, bytes, mapsDir: s.dataRoot.maps);
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(SnackBar(content: Text('Historia «${c.title}» importada')));
      await Navigator.push(context, MaterialPageRoute(builder: (_) => CampaignDetailScreen(campaignId: c.id!)));
      if (mounted) setState(() {});
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('No se pudo importar: $e')));
    }
  }

  Widget _tile(BuildContext context, AppServices s, Campaign c) {
    final players = s.db.campaignPlayers(c.id!);
    final sessions = s.db.sessions(c.id!);
    final act = c.acts.isEmpty ? '' : ' · Acto ${c.currentAct + 1}/${c.acts.length}';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(c.title, style: Theme.of(context).textTheme.titleLarge),
        subtitle: Text(
          '${c.theme}$act · ${sessions.length} sesiones\n'
          '${players.map((p) => p.characterName.isEmpty ? p.playerName : '${p.playerName} (${p.characterName})').join(', ')}',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => CampaignDetailScreen(campaignId: c.id!)));
          setState(() {});
        },
      ),
    );
  }
}
