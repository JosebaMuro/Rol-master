import 'dart:io';

import 'package:director_de_rol/ai/campaign_builder.dart';
import 'package:director_de_rol/ai/director.dart';
import 'package:director_de_rol/ai/llm.dart';
import 'package:director_de_rol/ai/memory/graph.dart';
import 'package:director_de_rol/ai/memory/rag.dart';
import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:director_de_rol/logs/log_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Future<Campaign> makeCampaign(FakeLlm llm) async {
    final ana = db.upsertPlayer('Ana');
    final luis = db.upsertPlayer('Luis');
    return CampaignBuilder(
      db: db,
      llm: llm,
      rag: RagMemory(db, llm),
      graph: KnowledgeGraph(db),
      voiceAssigner: fakeVoice,
    ).create(
      theme: 'Fantasía oscura',
      tone: 'Épico',
      acts: 2,
      ideas: '',
      players: [
        CampaignPlayer(playerId: ana.id!, playerName: 'Ana', characterName: 'Kael'),
        CampaignPlayer(playerId: luis.id!, playerName: 'Luis', characterName: 'Mira'),
      ],
    );
  }

  test('el generador de campañas crea PNJ con voz, grafo y memoria', () async {
    final llm = FakeLlm(jsonReplies: [sampleBible]);
    final c = await makeCampaign(llm);
    expect(c.title, 'La Corona de Ceniza');
    final npcs = db.npcs(c.id!);
    expect(npcs.map((n) => n.name), containsAll(['Bran el tabernero', 'Sor Elia', 'Lady Morwen']));
    expect(npcs.firstWhere((n) => n.name == 'Sor Elia').voice.pitch, 1.3);
    expect(db.entities(c.id!).map((e) => e.name), containsAll(['Taberna del Cuervo', 'Orden del Alba', 'Kael']));
    expect(db.chunkCount(c.id!), greaterThan(0));
    // La petición incluye a los personajes de los jugadores.
    expect(llm.jsonCalls.single.last.text, contains('Kael'));
  });

  test('una partida completa: apertura, turno, memoria, cierre y continuación', () async {
    final llm = FakeLlm(
      jsonReplies: [
        sampleBible,
        {
          'entities': [
            {'name': 'Anillo negro', 'type': 'objeto', 'description': 'Lleva el sello real'},
          ],
          'relations': [
            {'source': 'Kael', 'relation': 'posee', 'target': 'Anillo negro'},
          ],
        },
      ],
      replies: [
        'Bran os mira con recelo.\n@Bran el tabernero: Ese anillo trae desgracias.\n@Capitana Ysolde: ¡Guardia! Nadie sale.\n'
            '[[musica: Misterio]]\n[[lugar: Taberna del Cuervo]]\n[[acto: 1]]\n¿Qué hacéis?',
        'Resumen: Kael encontró el anillo negro. Situación actual: en la taberna.',
      ],
    );
    final c = await makeCampaign(llm);
    final director = Director(
      db: db,
      llm: llm,
      rag: RagMemory(db, llm),
      graph: KnowledgeGraph(db),
      config: const DirectorConfig(thinking: true),
      voiceAssigner: fakeVoice,
    );

    final s1 = director.startSession(c);
    final opening = db.messagesForSession(s1.id!);
    expect(opening.single.role, MessageRole.gm);
    expect(opening.single.content, contains('Cerramos pronto'));

    final events = await director
        .playerTurn(campaign: c, session: s1, speaker: 'Kael', text: 'Enseño el anillo a Bran', situations: ['Misterio'])
        .toList();
    final done = events.whereType<DirectorDone>().single;
    expect(events.whereType<DirectorThinking>(), isNotEmpty);
    expect(done.parsed.musicSuggestion, 'Misterio');
    expect(done.message.thinking, contains('Pienso'));

    // El prompt lleva reglas, biblia, PNJ, hechos del grafo y la acción.
    final prompt = llm.chatCalls.first;
    expect(prompt.first.role, LlmRole.system);
    expect(prompt.first.text, contains('DIRECTOR DE JUEGO'));
    expect(prompt.first.text, contains('Lady Morwen'));
    expect(prompt.first.text, contains('Bran el tabernero'));
    expect(prompt.last.text, contains('Enseño el anillo a Bran'));

    // Nuevo PNJ improvisado con voz propia, y estado actualizado.
    expect(db.npcByName(c.id!, 'Capitana Ysolde'), isNotNull);
    final updated = db.campaign(c.id!)!;
    expect(updated.location, 'Taberna del Cuervo');

    // Cierre de sesión: espera a la extracción de memoria y resume.
    final summary = await director.endSession(updated, s1);
    expect(summary, contains('anillo negro'));
    expect(db.relations(c.id!).any((r) => r.relation == 'posee' && r.targetName == 'Anillo negro'), isTrue);

    // Registro en disco organizado por jugador y tema.
    final dir = await Directory.systemTemp.createTemp('logs');
    final paths = await LogService(db, dir.path).writeSession(updated, db.sessions(c.id!).single);
    expect(paths.length, 2);
    expect(paths.first, contains('Ana${Platform.pathSeparator}Fantasía oscura${Platform.pathSeparator}La Corona de Ceniza'));
    expect(File(paths.first).readAsStringSync(), contains('Enseño el anillo a Bran'));
    await dir.delete(recursive: true);

    // La siguiente sesión empieza recordando dónde se quedó.
    final s2 = director.startSession(updated);
    final recap = db.messagesForSession(s2.id!).single;
    expect(recap.role, MessageRole.system);
    expect(recap.content, contains('anillo negro'));
    expect(s2.number, 2);

    // Y el prompt de la sesión 2 incluye el resumen anterior.
    final p2 = await director.buildPrompt(updated, ['Misterio'], 'Salimos de la taberna');
    expect(p2.first.text, contains('RESUMEN DE LA SESIÓN ANTERIOR'));
  });

  test('las consultas al registro usan los resúmenes de sesión', () async {
    final llm = FakeLlm(jsonReplies: [sampleBible], replies: ['En la sesión 1 encontrasteis el anillo.']);
    final c = await makeCampaign(llm);
    final s = db.startSession(c.id!);
    db.endSession(s, 'Encontraron el anillo negro.');
    final director = Director(
      db: db,
      llm: llm,
      rag: RagMemory(db, llm),
      graph: KnowledgeGraph(db),
      config: const DirectorConfig(),
      voiceAssigner: fakeVoice,
    );
    final answer = (await director.askAboutLogs(c, '¿Qué encontramos?').toList()).join();
    expect(answer, contains('anillo'));
    expect(llm.chatCalls.last.last.text, contains('Sesión 1: Encontraron el anillo negro.'));
  });
}
