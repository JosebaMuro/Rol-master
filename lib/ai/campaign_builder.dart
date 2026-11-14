import '../core/db.dart';
import '../core/models.dart';
import 'director.dart';
import 'llm.dart';
import 'memory/graph.dart';
import 'memory/rag.dart';
import 'prompts.dart';

/// Genera una campaña completa (la "biblia") con la IA y la vuelca en la
/// base de datos, el grafo de conocimiento y la memoria RAG.
class CampaignBuilder {
  CampaignBuilder({
    required this.db,
    required this.llm,
    required this.rag,
    required this.graph,
    required this.voiceAssigner,
  });
  final AppDatabase db;
  final TextGenerator llm;
  final RagMemory rag;
  final KnowledgeGraph graph;
  final VoiceAssigner voiceAssigner;

  Future<Campaign> create({
    required String theme,
    required String tone,
    required int acts,
    required String ideas,
    required List<CampaignPlayer> players,
    String title = '',
    void Function(String step)? onStep,
  }) async {
    final refs = await rag.searchDocs('$theme $tone $ideas $title', k: 6);
    final reference = refs.map((h) => '  · (${h.chunk.source.replaceFirst('doc · ', '')}) ${h.chunk.text.replaceAll('\n', ' ')}').join('\n');
    onStep?.call(refs.isEmpty ? 'Inventando la historia, el villano y los actos…' : 'Inventando la historia con tu documentación…');
    final bible = await llm.json(
      [
        const LlmMessage.system(
          'Eres un diseñador de campañas de rol premiado. Creas historias originales, con capas, '
          'personajes con motivaciones grises y giros que se pueden anticipar con las pistas.',
        ),
        LlmMessage.user(Prompts.campaignRequest(
          theme: theme,
          tone: tone,
          acts: acts,
          ideas: ideas,
          players: players,
          title: title,
          reference: reference,
        )),
      ],
      schema: Prompts.campaignSchema,
      maxTokens: 4096,
      temperature: 0.9,
    );
    if (bible.isEmpty) throw StateError('La IA no devolvió una campaña válida. Prueba otra vez o usa un modelo mayor.');

    onStep?.call('Guardando la campaña…');
    return import(bible, theme: theme, tone: tone, players: players, fallbackTitle: title, onStep: onStep);
  }

  /// Vuelca una biblia (generada o importada de un JSON) en una campaña nueva.
  Future<Campaign> import(
    Map<String, dynamic> bible, {
    required String theme,
    required String tone,
    required List<CampaignPlayer> players,
    String fallbackTitle = '',
    void Function(String step)? onStep,
  }) async {
    final c = db.insertCampaign(Campaign(
      title: _s(bible['title']).isNotEmpty ? _s(bible['title']) : (fallbackTitle.isEmpty ? 'Campaña sin título' : fallbackTitle),
      theme: theme,
      tone: tone,
      setting: _s(bible['setting']),
      premise: _s(bible['premise']),
      bible: bible,
    ));
    final id = c.id!;
    db.setCampaignPlayers(id, players);

    onStep?.call('Creando PNJ y sus voces…');
    for (final n in _list(bible['npcs'])) {
      final name = _s(n['name']);
      if (name.isEmpty) continue;
      final hint = [_s(n['gender']), _s(n['age']), _s(n['voice'])].where((e) => e.isNotEmpty).join(', ');
      db.upsertNpc(Npc(
        campaignId: id,
        name: name,
        description: '${_s(n['role'])}. ${_s(n['personality'])}'.trim(),
        voiceHint: hint,
        voice: voiceAssigner(id, name, hint),
      ));
      graph.addEntity(id, name, type: 'pnj', description: '${_s(n['role'])}. ${_s(n['personality'])} Secreto: ${_s(n['secret'])}');
    }

    onStep?.call('Construyendo el grafo de conocimiento…');
    final villain = bible['villain'];
    if (villain is Map && _s(villain['name']).isNotEmpty) {
      graph.addEntity(id, _s(villain['name']), type: 'pnj', description: 'Antagonista. ${_s(villain['motivation'])}');
      if (db.npcByName(id, _s(villain['name'])) == null) {
        db.upsertNpc(Npc(
          campaignId: id,
          name: _s(villain['name']),
          description: 'Antagonista. ${_s(villain['motivation'])}',
          voice: voiceAssigner(id, _s(villain['name']), 'villano, grave'),
        ));
      }
    }
    for (final l in _list(bible['locations'])) {
      if (_s(l['name']).isNotEmpty) graph.addEntity(id, _s(l['name']), type: 'lugar', description: _s(l['description']));
    }
    for (final f in _list(bible['factions'])) {
      if (_s(f['name']).isNotEmpty) graph.addEntity(id, _s(f['name']), type: 'facción', description: _s(f['goal']));
    }
    for (final p in players) {
      if (p.characterName.isNotEmpty) {
        graph.addEntity(id, p.characterName, type: 'personaje', description: 'Personaje de ${p.playerName}. ${p.characterSheet}');
      }
    }
    if (villain is Map && _s(villain['name']).isNotEmpty) {
      for (final f in _list(bible['factions'])) {
        if (_s(f['goal']).toLowerCase().contains(_s(villain['name']).toLowerCase())) {
          graph.addFact(id, _s(villain['name']), 'manipula a', _s(f['name']));
        }
      }
    }

    onStep?.call('Indexando la biblia para la memoria (RAG)…');
    final lore = StringBuffer()
      ..writeln('Premisa: ${_s(bible['premise'])}')
      ..writeln('Gancho: ${_s(bible['hook'])}')
      ..writeln('Ambientación: ${_s(bible['setting'])}');
    for (final l in _list(bible['locations'])) {
      lore.writeln('\nLugar ${_s(l['name'])}: ${_s(l['description'])}');
    }
    for (final n in _list(bible['npcs'])) {
      lore.writeln('\nPNJ ${_s(n['name'])}: ${_s(n['role'])}. ${_s(n['personality'])}');
    }
    for (final f in _list(bible['factions'])) {
      lore.writeln('\nFacción ${_s(f['name'])}: ${_s(f['goal'])}');
    }
    await rag.addText(id, 'biblia', lore.toString());
    return c;
  }

  static String _s(Object? v) => (v ?? '').toString().trim();
  static List<Map> _list(Object? v) => v is List ? v.whereType<Map>().toList() : const [];
}
