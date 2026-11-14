import 'dart:math';

import 'package:director_de_rol/ai/campaign_builder.dart';
import 'package:director_de_rol/ai/director.dart';
import 'package:director_de_rol/ai/memory/graph.dart';
import 'package:director_de_rol/ai/memory/rag.dart';
import 'package:director_de_rol/ai/narration_parser.dart';
import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:director_de_rol/core/story_package.dart';
import 'package:director_de_rol/game/dice.dart';
import 'package:director_de_rol/game/game_state.dart';
import 'package:director_de_rol/game/world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fakes.dart';

/// Dados trucados: devuelve siempre los valores dados, en bucle.
class LoadedRandom implements Random {
  LoadedRandom(this.values);
  final List<int> values;
  var _i = 0;
  @override
  int nextInt(int max) => (values[_i++ % values.length] - 1).clamp(0, max - 1);
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 0.5;
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  Future<Campaign> campaign(FakeLlm llm) async {
    final ana = db.upsertPlayer('Ana');
    final luis = db.upsertPlayer('Luis');
    return CampaignBuilder(db: db, llm: llm, rag: RagMemory(db, llm), graph: KnowledgeGraph(db), voiceAssigner: fakeVoice)
        .create(theme: 'Fantasía', tone: 'Épico', acts: 2, ideas: '', players: [
      CampaignPlayer(playerId: ana.id!, playerName: 'Ana', characterName: 'Kael'),
      CampaignPlayer(playerId: luis.id!, playerName: 'Luis', characterName: 'Mira'),
    ]);
  }

  group('dados', () {
    test('expresiones de dados', () {
      final d = Dice(LoadedRandom([4, 6, 2]));
      final r = d.roll('2d6+3')!;
      expect(r.rolls, [4, 6]);
      expect(r.total, 13);
      expect(d.roll('d20 - 1')!.total, 1);
      expect(d.roll('hola'), isNull);
    });

    test('tirada pedida por el director: personaje, habilidad y CD', () {
      final r = RollRequest.parse('Kael | Percepción CD 15');
      expect(r.who, 'Kael');
      expect(r.skill, 'Percepción');
      expect(r.dc, 15);
      final r2 = RollRequest.parse('Sigilo (dificultad 12)');
      expect(r2.who, '');
      expect(r2.skill, 'Sigilo');
      expect(r2.dc, 12);
    });

    test('grados de éxito', () {
      final req = RollRequest.parse('Atletismo CD 14');
      SkillCheck check(int die, [int mod = 0]) => SkillCheck(request: req, who: 'Kael', die: die, modifier: mod);
      expect(check(20).tier, RollTier.critico);
      expect(check(1, 20).tier, RollTier.pifia);
      expect(check(12, 2).tier, RollTier.exitoParcial);
      expect(check(19, 2).tier, RollTier.exito);
      expect(check(10, 2).tier, RollTier.fallo);
      expect(check(12, 2).describe(), contains('d20 (12) +2 = 14 contra CD 14'));
    });
  });

  group('etiquetas de estado', () {
    test('el parser reconoce los cambios propuestos', () {
      final p = parseNarration('La flecha te alcanza.\n[[pv: Kael -4]]\n[[objeto: Mira +Llave de hierro]]\n'
          '[[oro: Kael | -15]]\n[[estado: Kael +envenenado]]\n[[actitud: Bran el tabernero +1]]\n'
          '[[promesa: Llevar el anillo al abad]]\n[[resuelto: pagar a Bran]]\n[[tiempo: dos semanas]]\n[[daño: Mira 3]]');
      expect(p.cleanText, 'La flecha te alcanza.');
      expect(p.changes.map((c) => c.toString()), [
        'pv: Kael -4',
        'objeto: Mira +Llave de hierro',
        'oro: Kael -15',
        'estado: Kael +envenenado',
        'actitud: Bran el tabernero +1',
        'pv: Mira -3',
      ]);
      expect(p.threadsOpened.single, ('promesa', 'Llevar el anillo al abad'));
      expect(p.threadsClosed.single, 'pagar a Bran');
      expect(WorldEngine.parseDays(p.timeSkip!), 14);
    });

    test('la app aplica los cambios a las fichas y a los PNJ', () async {
      final c = await campaign(FakeLlm(jsonReplies: [sampleBible]));
      final gs = GameState(db);
      expect(db.charStates(c.id!).map((e) => e.name), ['Kael', 'Mira']);
      final notes = gs.apply(c.id!, [
        const StateChange('pv', 'Kael', '-4'),
        const StateChange('objeto', 'Ana', '+Antorcha x3'), // por el nombre del jugador
        const StateChange('objeto', 'Kael', '-Antorcha'),
        const StateChange('oro', 'Mira', '+20'),
        const StateChange('estado', 'Kael', '+envenenado'),
        const StateChange('actitud', 'Bran', '+2'),
        const StateChange('pv', 'Nadie', '-4'),
      ]);
      final kael = db.charState(c.id!, 'Kael')!;
      expect(kael.hp, 6);
      expect(kael.inventory.single.name, 'Antorcha');
      expect(kael.inventory.single.qty, 2);
      expect(kael.conditions, ['envenenado']);
      expect(db.charState(c.id!, 'Mira')!.gold, 20);
      expect(db.npcByName(c.id!, 'Bran el tabernero')!.attitude, 2);
      expect(notes.length, 6);
      expect(kael.summary(), contains('PV 6/10'));
    });
  });

  group('grafo con caducidad', () {
    test('ubicación y posesión son exclusivas; la muerte saca del mapa', () {
      final c = db.insertCampaign(Campaign(title: 'T', theme: 'X'));
      final g = KnowledgeGraph(db);
      g.addFact(c.id!, 'Bran', 'está en', 'Taberna', session: 1);
      g.addFact(c.id!, 'Bran', 'odia a', 'Morwen', session: 1);
      g.addFact(c.id!, 'Bran', 'está en', 'Puerto', session: 2);
      g.addFact(c.id!, 'Mira', 'posee', 'Anillo', session: 2);
      g.addFact(c.id!, 'Kael', 'posee', 'Anillo', session: 3);
      final active = db.relations(c.id!, ended: false).map((r) => r.toString()).toSet();
      expect(active, {'Bran —odia a→ Morwen', 'Bran —está en→ Puerto', 'Kael —posee→ Anillo'});
      final past = db.relations(c.id!, ended: true);
      expect(past.map((r) => r.toString()), containsAll(['Bran —está en→ Taberna', 'Mira —posee→ Anillo']));
      expect(past.firstWhere((r) => r.targetName == 'Taberna').untilSession, 2);

      g.addFact(c.id!, 'Bran', 'murió en', 'Puerto', session: 4);
      expect(db.relations(c.id!, ended: false).any((r) => r.relation == 'está en'), isFalse);

      // El contexto separa lo vigente de lo pasado.
      final ctx = g.contextFor(c.id!, 'Hablamos de Bran');
      expect(ctx, contains('Relaciones vigentes'));
      expect(ctx, contains('Ya NO es cierto'));
      expect(ctx, contains('Bran está en Taberna'));

      // Si vuelve a ser cierto, se reabre.
      g.addFact(c.id!, 'Mira', 'posee', 'Anillo', session: 5);
      expect(db.relations(c.id!, ended: false).where((r) => r.targetName == 'Anillo').single.sourceName, 'Mira');
    });

    test('el archivista caduca hechos, abre y cierra asuntos y actualiza PNJ', () async {
      final llm = FakeLlm(jsonReplies: [
        sampleBible,
        {
          'entities': [],
          'relations': [
            {'source': 'Bran el tabernero', 'relation': 'es aliado de', 'target': 'Orden del Alba'},
          ],
          'ended_relations': [
            {'source': 'Bran el tabernero', 'relation': 'vive en', 'target': 'Taberna del Cuervo'},
          ],
          'threads_opened': [
            {'kind': 'deuda', 'text': 'Kael debe 10 monedas a Bran'},
          ],
          'threads_closed': [1],
          'npcs': [
            {'name': 'Bran el tabernero', 'attitude_change': -1, 'goal': 'Vender el anillo', 'learned': 'Kael tiene el anillo'},
          ],
        },
      ]);
      final c = await campaign(llm);
      db.addPlotThread(PlotThread(campaignId: c.id!, kind: 'promesa', text: 'Pagar a Bran'));
      KnowledgeGraph(db).addFact(c.id!, 'Bran el tabernero', 'vive en', 'Taberna del Cuervo');
      final director = Director(db: db, llm: llm, rag: RagMemory(db, llm), graph: KnowledgeGraph(db),
          config: const DirectorConfig(), voiceAssigner: fakeVoice);
      final r = await director.extractor.extract(c.id!, 'Pago', 'Bran sonríe', session: 2, messageId: 9, present: ['Bran el tabernero']);
      expect(r.notes, isNotEmpty);
      final threads = db.plotThreads(c.id!);
      expect(threads.firstWhere((t) => t.text == 'Pagar a Bran').open, isFalse);
      expect(threads.firstWhere((t) => t.kind == 'deuda').open, isTrue);
      final bran = db.npcByName(c.id!, 'Bran el tabernero')!;
      expect(bran.attitude, -1);
      expect(bran.goal, 'Vender el anillo');
      expect(bran.knows.single, 'S2: Kael tiene el anillo');
      expect(bran.lastSeen, 9);
      // Lo que dejó de ser cierto pasa al pasado; lo nuevo queda vigente.
      expect(db.relations(c.id!, ended: true).single.relation, 'vive en');
      expect(db.relations(c.id!, ended: false).any((r) => r.relation == 'es aliado de'), isTrue);
    });
  });

  group('el mundo se mueve', () {
    test('la biblia crea relojes del villano y las facciones, una sola vez', () async {
      final c = await campaign(FakeLlm(jsonReplies: [sampleBible]));
      final clocks = db.clocks(c.id!);
      expect(clocks.map((k) => k.owner), ['Lady Morwen', 'Orden del Alba']);
      expect(clocks.first.segments, 8);
      for (final k in clocks) {
        db.deleteClock(k.id!);
      }
      WorldEngine(db).seed(db.campaign(c.id!)!);
      expect(db.clocks(c.id!), isEmpty);
    });

    test('avanza cada N turnos y un reloj lleno deja un acontecimiento', () async {
      final c = await campaign(FakeLlm(jsonReplies: [sampleBible]));
      final world = WorldEngine(db, dice: Dice(LoadedRandom([6])));
      final camp = db.campaign(c.id!)!;
      expect(world.onTurn(camp, every: 2), isEmpty);
      expect(world.onTurn(camp, every: 2), isNotEmpty);
      final notes = world.tick(camp, steps: 8);
      expect(notes.join(), contains('se ha cumplido'));
      expect(WorldEngine.pendingEvents(db.campaign(c.id!)!).first, contains('Lady Morwen completa su plan'));
      expect(db.clocks(c.id!, onlyActive: true), isEmpty);
    });

    test('saltos de tiempo en lenguaje natural', () {
      expect(WorldEngine.parseDays('3 días'), 3);
      expect(WorldEngine.parseDays('una semana'), 7);
      expect(WorldEngine.parseDays('medio año'), 183);
      expect(WorldEngine.parseDays('tres meses'), 90);
      expect(WorldEngine.parseDays('nada'), isNull);
      expect(WorldEngine.describeDays(14), '2 semanas');
    });
  });

  test('turno completo: el director propone, la app aplica y todo entra en el prompt', () async {
    final llm = FakeLlm(jsonReplies: [sampleBible], replies: [
      'Una trampa salta.\n[[pv: Kael -3]]\n[[objeto: Mira +Llave negra]]\n[[promesa: Devolver la llave al abad]]\n'
          '[[tirada: Kael | Percepción CD 12]]\n¿Qué hacéis?',
    ]);
    final c = await campaign(llm);
    db.addPin(PinnedMemory(campaignId: c.id!, text: 'Bran mintió sobre el mensajero'));
    final director = Director(db: db, llm: llm, rag: RagMemory(db, llm), graph: KnowledgeGraph(db),
        config: const DirectorConfig(worldEvery: 0), voiceAssigner: fakeVoice);
    final s = director.startSession(c);
    final done = (await director.playerTurn(campaign: c, session: s, speaker: 'Kael', text: 'Abro el cofre', situations: []).toList())
        .whereType<DirectorDone>()
        .single;
    expect(done.notes, contains('Kael: PV 10 → 7/10'));
    expect(done.parsed.rolls.single, 'Kael | Percepción CD 12');
    expect(db.charState(c.id!, 'Mira')!.inventory.single.name, 'Llave negra');
    // Las notas de la mesa quedan en la sesión (y en el registro).
    expect(db.messagesForSession(s.id!).any((m) => m.speaker == Director.tableSpeaker && m.content.contains('Llave negra')), isTrue);

    final prompt = (await director.buildPrompt(db.campaign(c.id!)!, [], 'Sigo')).first.text;
    expect(prompt, contains('ESTADO DE LOS PERSONAJES'));
    expect(prompt, contains('Kael: PV 7/10'));
    expect(prompt, contains('Bran mintió sobre el mensajero'));
    expect(prompt, contains('[promesa] Devolver la llave al abad'));
    expect(prompt, contains('EL MUNDO SE MUEVE'));

    // Repetir la respuesta borra también las notas de la mesa.
    await director.regenerate(campaign: c, session: s, situations: []).toList();
    final msgs = db.messagesForSession(s.id!);
    expect(msgs.where((m) => m.role == MessageRole.gm).length, 2); // apertura + nueva respuesta
  });

  test('salto de tiempo pedido por el grupo', () async {
    final c = await campaign(FakeLlm(jsonReplies: [sampleBible]));
    final director = Director(db: db, llm: FakeLlm(), rag: RagMemory(db, FakeLlm()), graph: KnowledgeGraph(db),
        config: const DirectorConfig(), voiceAssigner: fakeVoice, world: WorldEngine(db, dice: Dice(LoadedRandom([6]))));
    final s = director.startSession(c);
    final notes = director.skipTime(c, s, 30);
    expect(notes.first, '⌛ Pasan un mes.');
    expect(db.clocks(c.id!).first.filled, 4);
    expect(WorldEngine.pendingEvents(db.campaign(c.id!)!).last, contains('Han pasado un mes'));
  });

  test('exportar con progreso conserva fichas, recuerdos, asuntos, relojes y hechos pasados', () async {
    final c = await campaign(FakeLlm(jsonReplies: [sampleBible]));
    GameState(db).apply(c.id!, [const StateChange('pv', 'Kael', '-2'), const StateChange('objeto', 'Kael', '+Anillo')]);
    db.addPin(PinnedMemory(campaignId: c.id!, text: 'Recuerdo clave'));
    db.addPlotThread(PlotThread(campaignId: c.id!, kind: 'deuda', text: 'Deuda con Bran'));
    final g = KnowledgeGraph(db)..addFact(c.id!, 'Bran', 'está en', 'Taberna');
    g.addFact(c.id!, 'Bran', 'está en', 'Puerto');
    final bran = db.npcByName(c.id!, 'Bran el tabernero')!..attitude = 2;
    db.updateNpcState(bran);
    final clock = db.clocks(c.id!).first..filled = 3;
    db.saveClock(clock);

    final bytes = StoryPackage.export(db, c.id!);
    final copy = StoryPackage.import(db, bytes, mapsDir: '/tmp');
    expect(db.charState(copy.id!, 'Kael')!.hp, 8);
    expect(db.charState(copy.id!, 'Kael')!.inventory.single.name, 'Anillo');
    expect(db.pins(copy.id!).single.text, 'Recuerdo clave');
    expect(db.plotThreads(copy.id!).single.text, 'Deuda con Bran');
    expect(db.clocks(copy.id!).first.filled, 3);
    expect(db.npcByName(copy.id!, 'Bran el tabernero')!.attitude, 2);
    expect(db.relations(copy.id!, ended: true).single.targetName, 'Taberna');

    // Sin progreso: la historia limpia para otro grupo.
    final clean = StoryPackage.import(db, StoryPackage.export(db, c.id!, includeProgress: false), mapsDir: '/tmp');
    expect(db.pins(clean.id!), isEmpty);
    expect(db.clocks(clean.id!).first.filled, 0);
    expect(db.relations(clean.id!, ended: true), isEmpty);
    expect(db.npcByName(clean.id!, 'Bran el tabernero')!.attitude, 0);
  });

  test('una base de datos de la versión anterior se actualiza sin perder nada', () {
    final raw = sqlite3.openInMemory();
    // Esquema v2 mínimo: se crea con la app actual y se vuelve atrás.
    final old = AppDatabase(raw);
    final c = old.insertCampaign(Campaign(title: 'Vieja', theme: 'X'));
    final e1 = old.upsertEntity(c.id!, 'A'), e2 = old.upsertEntity(c.id!, 'B');
    old.addRelation(c.id!, e1.id!, 'conoce a', e2.id!);
    raw.execute('''
      DROP TABLE char_states; DROP TABLE pins; DROP TABLE plot_threads; DROP TABLE world_clocks;
      ALTER TABLE relations DROP COLUMN ended; ALTER TABLE relations DROP COLUMN since_session;
      ALTER TABLE relations DROP COLUMN until_session; ALTER TABLE npcs DROP COLUMN goal;
      ALTER TABLE npcs DROP COLUMN attitude; ALTER TABLE npcs DROP COLUMN knows; ALTER TABLE npcs DROP COLUMN last_seen;
      PRAGMA user_version = 2;
    ''');
    final upgraded = AppDatabase(raw);
    expect(upgraded.relations(c.id!, ended: false).single.relation, 'conoce a');
    expect(upgraded.charStates(c.id!), isEmpty);
    expect(raw.select('PRAGMA user_version').first.values.first, AppDatabase.schemaVersion);
  });
}
