import 'package:director_de_rol/ai/campaign_builder.dart';
import 'package:director_de_rol/ai/director.dart';
import 'package:director_de_rol/ai/llm.dart';
import 'package:director_de_rol/ai/memory/graph.dart';
import 'package:director_de_rol/ai/memory/rag.dart';
import 'package:director_de_rol/ai/model_catalog.dart';
import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('catálogo', () {
    test('Gemma 3 es una alternativa más, con proyector de visión, y Qwen3 sigue', () {
      final gemma = chatPresets.where((m) => m.id.startsWith('gemma3')).toList();
      expect(gemma, hasLength(2));
      for (final m in gemma) {
        expect(m.vision, isTrue);
        expect(m.projector, startsWith('hf://ggml-org/gemma-3-'));
        expect(m.projector, endsWith('mmproj-model-f16.gguf'));
        expect(m.reasoning, isFalse);
      }
      expect(chatPresets.where((m) => m.id.startsWith('qwen3')), hasLength(4));
      expect(chatPresets.map((m) => m.id).toSet(), hasLength(chatPresets.length));
    });

    test('distingue razonamiento propio de guiado', () {
      expect(hasNativeThinking('hf://unsloth/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf'), isTrue);
      expect(hasNativeThinking('hf://ggml-org/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf'), isFalse);
      expect(hasNativeThinking(r'C:\datos\modelos\DeepSeek-R1-Distill-Q4.gguf'), isTrue);
      expect(hasNativeThinking('modelos/gemma-3-27b-it-Q4_K_M.gguf'), isFalse);
      expect(hasNativeThinking('modelos/Mistral-Nemo-Q4.gguf'), isFalse);
    });
  });

  group('razonamiento guiado', () {
    test('la instrucción se añade al mensaje de sistema', () {
      final out = withGuidedThinking(const [LlmMessage.system('Reglas.'), LlmMessage.user('Hola')], 768);
      expect(out, hasLength(2));
      expect(out.first.text, startsWith('Reglas.'));
      expect(out.first.text, contains('<think>'));
      expect(withGuidedThinking(const [LlmMessage.user('Hola')], 768).first.role, LlmRole.system);
    });

    String run(List<String> pieces, {required bool thinking}) {
      final s = ThinkSplitter();
      final text = StringBuffer(), think = StringBuffer();
      for (final c in [...pieces.map(s.add), s.close()]) {
        text.write(c.text);
        think.write(c.thinking);
      }
      return thinking ? think.toString() : text.toString();
    }

    test('separa el bloque aunque las etiquetas lleguen partidas', () {
      const full = '<think>Kael quiere abrir la puerta. Tirada de fuerza.</think>La puerta cruje. ¿Qué hacéis?';
      for (var size = 1; size <= full.length; size++) {
        final pieces = [for (var i = 0; i < full.length; i += size) full.substring(i, (i + size).clamp(0, full.length))];
        expect(run(pieces, thinking: true), 'Kael quiere abrir la puerta. Tirada de fuerza.', reason: 'trozos de $size');
        expect(run(pieces, thinking: false), 'La puerta cruje. ¿Qué hacéis?', reason: 'trozos de $size');
      }
    });

    test('sin etiquetas todo es narración, y un «<» suelto no se pierde', () {
      expect(run(['Tiras 3 < 5 y ', 'fallas <'], thinking: false), 'Tiras 3 < 5 y fallas <');
      expect(run(['Tiras 3 < 5'], thinking: true), '');
    });

    test('un bloque sin cerrar queda como razonamiento', () {
      final s = ThinkSplitter();
      s.add('<think>pensando');
      expect(s.inside, isTrue);
      expect(run(['<think>pensando sin', ' fin'], thinking: true), 'pensando sin fin');
    });
  });

  group('visión', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    Future<(Director, Campaign, GameSession)> table(FakeLlm llm) async {
      final ana = db.upsertPlayer('Ana');
      final c = await CampaignBuilder(
        db: db,
        llm: llm,
        rag: RagMemory(db, llm),
        graph: KnowledgeGraph(db),
        voiceAssigner: fakeVoice,
      ).create(
        theme: 'Fantasía',
        tone: 'Épico',
        acts: 2,
        ideas: '',
        players: [CampaignPlayer(playerId: ana.id!, playerName: 'Ana', characterName: 'Kael')],
      );
      final director = Director(
        db: db,
        llm: llm,
        rag: RagMemory(db, llm),
        graph: KnowledgeGraph(db),
        config: const DirectorConfig(),
        voiceAssigner: fakeVoice,
      );
      return (director, c, director.startSession(c));
    }

    test('la imagen viaja sólo con el turno en que se enseña', () async {
      final llm = FakeLlm(jsonReplies: [sampleBible], sees: true);
      final (director, c, s) = await table(llm);
      await director
          .playerTurn(campaign: c, session: s, speaker: 'Kael', text: 'Mirad este mapa', situations: [], images: ['/tmp/mapa.png'])
          .toList();
      final first = llm.chatCalls.last;
      expect(first.last.images, ['/tmp/mapa.png']);
      expect(first.last.text, contains('mapa.png'));
      expect(first.where((m) => m.images.isNotEmpty), hasLength(1));

      await director.regenerate(campaign: c, session: s, situations: []).toList();
      expect(llm.chatCalls.last.last.images, ['/tmp/mapa.png']);

      await director.playerTurn(campaign: c, session: s, speaker: 'Kael', text: 'Sigo el camino', situations: []).toList();
      final next = llm.chatCalls.last;
      expect(next.where((m) => m.images.isNotEmpty), isEmpty);
      // Queda constancia en la conversación de que se enseñó una imagen.
      expect(next.any((m) => m.text.contains('mapa.png')), isTrue);
    });

    test('un modelo sin visión ignora la imagen', () async {
      final llm = FakeLlm(jsonReplies: [sampleBible]);
      final (director, c, s) = await table(llm);
      await director
          .playerTurn(campaign: c, session: s, speaker: 'Kael', text: 'Mirad este mapa', situations: [], images: ['/tmp/mapa.png'])
          .toList();
      expect(llm.chatCalls.last.last.images, isEmpty);
      expect(llm.chatCalls.last.last.text, isNot(contains('mapa.png')));
    });
  });
}
