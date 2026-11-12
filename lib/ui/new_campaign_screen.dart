import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ai/llama_service.dart';
import '../app_services.dart';
import '../core/models.dart';
import 'campaign_detail_screen.dart';

class _PlayerRow {
  final player = TextEditingController();
  final character = TextEditingController();
  final sheet = TextEditingController();
}

class NewCampaignScreen extends StatefulWidget {
  const NewCampaignScreen({super.key});

  @override
  State<NewCampaignScreen> createState() => _NewCampaignScreenState();
}

class _NewCampaignScreenState extends State<NewCampaignScreen> {
  static const themes = [
    'Fantasía épica',
    'Fantasía oscura',
    'Terror cósmico',
    'Ciencia ficción',
    'Cyberpunk',
    'Piratas',
    'Western',
    'Misterio / detectives',
    'Postapocalíptico',
    'Mitología',
  ];
  static const tones = ['Épico', 'Oscuro y adulto', 'Aventura ligera', 'Intriga política', 'Horror', 'Humor'];

  String _theme = themes.first;
  final _customTheme = TextEditingController();
  String _tone = tones.first;
  int _acts = 3;
  final _title = TextEditingController();
  final _ideas = TextEditingController();
  final _rows = [_PlayerRow()];
  bool _busy = false;
  String _step = '';

  @override
  Widget build(BuildContext context) {
    final llm = context.watch<LlamaService>();
    final s = context.read<AppServices>();
    final known = s.db.players();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nueva campaña'),
        actions: [
          IconButton(
            tooltip: 'Importar biblia (JSON)',
            icon: const Icon(Icons.file_open),
            onPressed: _busy ? null : _importJson,
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Tema', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in themes)
                ChoiceChip(label: Text(t), selected: _theme == t, onSelected: (_) => setState(() => _theme = t)),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _customTheme,
              decoration: const InputDecoration(labelText: 'Otro tema (opcional, sustituye al elegido)'),
            ),
            const SizedBox(height: 16),
            Text('Tono', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in tones)
                ChoiceChip(label: Text(t), selected: _tone == t, onSelected: (_) => setState(() => _tone = t)),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              const Text('Actos: '),
              Expanded(
                child: Slider(
                  value: _acts.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  label: '$_acts',
                  onChanged: (v) => setState(() => _acts = v.round()),
                ),
              ),
              Text('$_acts'),
            ]),
            TextField(controller: _title, decoration: const InputDecoration(labelText: 'Título (opcional)')),
            const SizedBox(height: 12),
            TextField(
              controller: _ideas,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Ideas, ambientación, cosas que queréis (o no) ver',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 20),
            Text('Jugadores', style: Theme.of(context).textTheme.titleMedium),
            for (final r in _rows) _playerCard(r, known),
            TextButton.icon(
              icon: const Icon(Icons.person_add),
              label: const Text('Añadir jugador'),
              onPressed: () => setState(() => _rows.add(_PlayerRow())),
            ),
            const SizedBox(height: 20),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_step, textAlign: TextAlign.center),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Que la IA invente la campaña'),
              onPressed: llm.isReady && !_busy ? _create : null,
            ),
            if (!llm.isReady)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Carga un modelo en Ajustes para generar la campaña.', textAlign: TextAlign.center),
              ),
          ],
        ),
      ),
    );
  }

  Widget _playerCard(_PlayerRow r, List<Player> known) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Autocomplete<String>(
                optionsBuilder: (v) =>
                    known.map((p) => p.name).where((n) => n.toLowerCase().contains(v.text.toLowerCase())),
                onSelected: (v) => r.player.text = v,
                fieldViewBuilder: (context, ctrl, focus, onSubmit) {
                  ctrl.addListener(() => r.player.text = ctrl.text);
                  return TextField(
                    controller: ctrl,
                    focusNode: focus,
                    decoration: const InputDecoration(labelText: 'Jugador'),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(controller: r.character, decoration: const InputDecoration(labelText: 'Personaje')),
            ),
            if (_rows.length > 1)
              IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _rows.remove(r))),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: r.sheet,
            decoration: const InputDecoration(labelText: 'Clase, raza, trasfondo… (opcional)'),
          ),
        ]),
      ),
    );
  }

  List<CampaignPlayer> _players() {
    final s = context.read<AppServices>();
    final out = <CampaignPlayer>[];
    for (final r in _rows) {
      final name = r.player.text.trim();
      if (name.isEmpty) continue;
      final p = s.db.upsertPlayer(name);
      out.add(CampaignPlayer(
        playerId: p.id!,
        playerName: p.name,
        characterName: r.character.text.trim(),
        characterSheet: r.sheet.text.trim(),
      ));
    }
    return out;
  }

  String get _effectiveTheme => _customTheme.text.trim().isEmpty ? _theme : _customTheme.text.trim();

  Future<void> _create() async {
    final players = _players();
    if (players.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Añade al menos un jugador')));
      return;
    }
    setState(() {
      _busy = true;
      _step = 'Pensando…';
    });
    try {
      final c = await context.read<AppServices>().campaignBuilder().create(
            theme: _effectiveTheme,
            tone: _tone,
            acts: _acts,
            ideas: _ideas.text.trim(),
            players: players,
            title: _title.text.trim(),
            onStep: (s) => mounted ? setState(() => _step = s) : null,
          );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CampaignDetailScreen(campaignId: c.id!)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo crear: $e')));
      setState(() => _busy = false);
    }
  }

  Future<void> _importJson() async {
    final players = _players();
    final res = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    final path = res?.path;
    if (path == null || !mounted) return;
    final services = context.read<AppServices>();
    try {
      final bible = (jsonDecode(await File(path).readAsString()) as Map).cast<String, dynamic>();
      final c = await services.campaignBuilder().import(
            bible,
            theme: _effectiveTheme,
            tone: _tone,
            players: players,
            fallbackTitle: _title.text.trim(),
          );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CampaignDetailScreen(campaignId: c.id!)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JSON no válido: $e')));
    }
  }
}
