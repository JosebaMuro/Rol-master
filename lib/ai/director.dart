import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/models.dart';
import '../core/scenes.dart';
import 'llm.dart';
import 'memory/extractor.dart';
import 'memory/graph.dart';
import 'memory/rag.dart';
import 'narration_parser.dart';
import 'prompts.dart';

/// Eventos que emite el director mientras responde.
sealed class DirectorEvent {}

class DirectorThinking extends DirectorEvent {
  DirectorThinking(this.thinking);
  final String thinking;
}

class DirectorPartial extends DirectorEvent {
  DirectorPartial(this.text);
  final String text;
}

class DirectorDone extends DirectorEvent {
  DirectorDone(this.message, this.parsed);
  final ChatMessage message;
  final ParsedNarration parsed;
}

typedef VoiceAssigner = VoiceProfile Function(int campaignId, String name, String hint);

/// Configuración de generación que el director toma de los ajustes.
class DirectorConfig {
  const DirectorConfig({
    this.temperature = 0.85,
    this.maxTokens = 900,
    this.thinking = true,
    this.thinkingBudget = 768,
    this.contextSize = 8192,
  });
  final double temperature;
  final int maxTokens;
  final bool thinking;
  final int thinkingBudget;
  final int contextSize;
}

/// El director de juego: orquesta prompts, memoria (resumen + RAG + grafo),
/// PNJ y registro de la partida.
class Director {
  Director({
    required this.db,
    required this.llm,
    required this.rag,
    required this.graph,
    required this.config,
    required this.voiceAssigner,
    this.onMessageSaved,
  }) : extractor = MemoryExtractor(db, llm, graph);

  final AppDatabase db;
  final TextGenerator llm;
  final RagMemory rag;
  final KnowledgeGraph graph;
  final MemoryExtractor extractor;
  DirectorConfig config;
  final VoiceAssigner voiceAssigner;
  final void Function(ChatMessage m)? onMessageSaved;

  /// Trabajo en segundo plano (extracción de memoria, compactación) que hay
  /// que esperar antes del siguiente turno para no usar el motor a la vez.
  Future<void> _background = Future.value();

  static const _memoryPointerKey = '_memoryUpTo';
  static const _compactEvery = 24;

  ChatMessage _save(ChatMessage m) {
    db.addMessage(m);
    onMessageSaved?.call(m);
    return m;
  }

  /// Empieza una sesión nueva de la campaña. Si es la primera, el director
  /// abre con la escena inicial de la biblia; si no, recuerda dónde se quedó.
  GameSession startSession(Campaign c) {
    final previous = db.lastSession(c.id!);
    final s = db.startSession(c.id!);
    if (previous == null) {
      final opening = (c.bible['opening'] ?? '').toString();
      if (opening.isNotEmpty) {
        _save(ChatMessage(
          campaignId: c.id!,
          sessionId: s.id!,
          role: MessageRole.gm,
          speaker: 'Director',
          content: parseNarration(opening).cleanText,
        ));
      }
    } else {
      final recap = previous.summary.isNotEmpty ? previous.summary : _fallbackRecap(c.id!);
      if (recap.isNotEmpty) {
        _save(ChatMessage(
          campaignId: c.id!,
          sessionId: s.id!,
          role: MessageRole.system,
          speaker: 'Anteriormente…',
          content: recap,
        ));
      }
    }
    return s;
  }

  String _fallbackRecap(int campaignId) {
    final last = db.recentMessages(campaignId, limit: 6);
    return last.where((m) => m.role == MessageRole.gm).map((m) => m.content).join('\n\n');
  }

  /// Turno de los jugadores: guarda su acción y devuelve la narración en
  /// streaming.
  Stream<DirectorEvent> playerTurn({
    required Campaign campaign,
    required GameSession session,
    required String speaker,
    required String text,
    required List<String> situations,
  }) async* {
    await _background;
    final playerMsg = _save(ChatMessage(
      campaignId: campaign.id!,
      sessionId: session.id!,
      role: MessageRole.player,
      speaker: speaker,
      content: text,
    ));
    yield* _respond(campaign, session, situations, playerMsg);
  }

  /// Vuelve a generar la última respuesta del director.
  Stream<DirectorEvent> regenerate({
    required Campaign campaign,
    required GameSession session,
    required List<String> situations,
  }) async* {
    await _background;
    final recent = db.recentMessages(campaign.id!, limit: 2);
    if (recent.isEmpty) return;
    if (recent.last.role == MessageRole.gm) db.deleteMessage(recent.last.id!);
    final lastPlayer = db.recentMessages(campaign.id!, limit: 1).lastOrNull;
    if (lastPlayer == null || lastPlayer.role != MessageRole.player) return;
    yield* _respond(campaign, session, situations, lastPlayer);
  }

  Stream<DirectorEvent> _respond(
    Campaign campaign,
    GameSession session,
    List<String> situations,
    ChatMessage playerMsg,
  ) async* {
    final messages = await buildPrompt(campaign, situations, playerMsg.content);
    final text = StringBuffer();
    final thinking = StringBuffer();
    try {
      await for (final chunk in llm.chat(
        messages,
        temperature: config.temperature,
        maxTokens: config.maxTokens,
        thinking: config.thinking,
        thinkingBudget: config.thinking ? config.thinkingBudget : null,
      )) {
        if (chunk.thinking.isNotEmpty) {
          thinking.write(chunk.thinking);
          yield DirectorThinking(thinking.toString());
        }
        if (chunk.text.isNotEmpty) {
          text.write(chunk.text);
          yield DirectorPartial(stripTagsForDisplay(text.toString()));
        }
      }
    } catch (e) {
      if (text.isEmpty) rethrow;
    }

    var raw = text.toString();
    // Algunos modelos meten el razonamiento en el texto con <think>.
    final inlineThink = RegExp(r'<think>([\s\S]*?)</think>').firstMatch(raw);
    if (inlineThink != null) {
      thinking.write(inlineThink.group(1));
      raw = raw.replaceFirst(inlineThink.group(0)!, '');
    }
    final parsed = parseNarration(raw);
    final gm = _save(ChatMessage(
      campaignId: campaign.id!,
      sessionId: session.id!,
      role: MessageRole.gm,
      speaker: 'Director',
      content: parsed.cleanText,
      thinking: thinking.toString().trim(),
    ));

    _applyState(campaign, parsed);
    yield DirectorDone(gm, parsed);

    _background = _afterTurn(campaign, playerMsg, gm);
  }

  void _applyState(Campaign c, ParsedNarration p) {
    var changed = false;
    if (p.act != null) {
      final idx = (p.act! - 1).clamp(0, c.acts.isEmpty ? 0 : c.acts.length - 1);
      if (idx != c.currentAct) {
        c.currentAct = idx;
        changed = true;
      }
    }
    if (p.location != null && p.location!.isNotEmpty && p.location != c.location) {
      c.location = p.location!;
      graph.addEntity(c.id!, c.location, type: 'lugar');
      changed = true;
    }
    // Escena para el fondo: la etiqueta explícita o, si no, deducida del lugar.
    final scene = Scenes.byId(p.scene) ?? (p.location != null ? Scenes.detect(p.location!) : null) ??
        (p.mapRequest != null ? Scenes.detect(p.mapRequest!.kind) : null);
    if (scene != null && c.bible[Scenes.bibleKey] != scene.id) {
      c.bible[Scenes.bibleKey] = scene.id;
      changed = true;
    }
    for (final name in p.speakers) {
      if (db.npcByName(c.id!, name) == null) {
        db.upsertNpc(Npc(campaignId: c.id!, name: name, voice: voiceAssigner(c.id!, name, '')));
        graph.addEntity(c.id!, name, type: 'pnj');
      }
    }
    if (changed) db.updateCampaign(c);
  }

  Future<void> _afterTurn(Campaign c, ChatMessage player, ChatMessage gm) async {
    try {
      await rag.addText(c.id!, 'sesión · ${gm.ts.toIso8601String().substring(0, 16)}',
          '[${player.speaker}] ${player.content}\n[Director] ${gm.content}');
      await extractor.extract(c.id!, '[${player.speaker}] ${player.content}', gm.content);
      await _compactMemory(c);
    } catch (e) {
      debugPrint('Tareas tras el turno: $e');
    }
  }

  /// Memoria a largo plazo: cuando se acumulan muchos mensajes sin resumir,
  /// los condensa en la memoria de la campaña.
  Future<void> _compactMemory(Campaign c) async {
    final upTo = (c.bible[_memoryPointerKey] as num?)?.toInt() ?? 0;
    final pending = db.recentMessages(c.id!, limit: 400).where((m) => m.id! > upTo).toList();
    if (pending.length < _compactEvery + 8) return;
    final toSummarize = pending.sublist(0, pending.length - 8);
    final buf = StringBuffer();
    await for (final ch in llm.chat(
      [
        const LlmMessage.system('Eres el cronista de una partida de rol. Escribes notas precisas y breves.'),
        LlmMessage.user(Prompts.summarizeRequest(Prompts.transcript(toSummarize))),
      ],
      temperature: 0.3,
      maxTokens: 600,
    )) {
      buf.write(ch.text);
    }
    final summary = buf.toString().trim();
    if (summary.isEmpty) return;
    var memory = c.memory.isEmpty ? summary : '${c.memory}\n$summary';
    if (estimateTokens(memory) > 1500) {
      // Recomprime la memoria cuando crece demasiado.
      final b2 = StringBuffer();
      await for (final ch in llm.chat(
        [
          const LlmMessage.system('Condensa estas notas de campaña conservando todos los hechos importantes, en viñetas.'),
          LlmMessage.user(memory),
        ],
        temperature: 0.2,
        maxTokens: 900,
      )) {
        b2.write(ch.text);
      }
      if (b2.isNotEmpty) memory = b2.toString().trim();
    }
    c.memory = memory;
    c.bible[_memoryPointerKey] = toSummarize.last.id;
    db.updateCampaign(c);
  }

  /// Construye la conversación que se envía al modelo.
  Future<List<LlmMessage>> buildPrompt(Campaign c, List<String> situations, String playerText) async {
    final recentForQuery = db.recentMessages(c.id!, limit: 3).map((m) => m.content).join('\n');
    final query = '$playerText\n$recentForQuery';
    final graphFacts = graph.contextFor(c.id!, query);
    final hits = await rag.search(c.id!, playerText, k: 5);
    // La documentación (reglas, ambientación) siempre tiene hueco propio.
    final seen = hits.map((h) => h.chunk.text).toSet();
    hits.addAll((await rag.searchDocs(query, campaignId: c.id, k: 3)).where((h) => seen.add(h.chunk.text)));
    final ragText = hits.map((h) => '- (${h.chunk.source}) ${h.chunk.text.replaceAll('\n', ' ')}').join('\n');
    final lastSession = db.sessions(c.id!).where((s) => s.summary.isNotEmpty).lastOrNull;

    final system = '${Prompts.gmRules(situations)}\n'
        '${Prompts.campaignContext(
      c: c,
      players: db.campaignPlayers(c.id!),
      npcs: db.npcs(c.id!),
      lastSessionSummary: lastSession?.summary ?? '',
      graphFacts: graphFacts,
      ragSnippets: ragText,
    )}';

    final budget = config.contextSize -
        estimateTokens(system) -
        config.maxTokens -
        (config.thinking ? config.thinkingBudget : 0) -
        256;

    final history = <LlmMessage>[];
    var used = 0;
    final upTo = (c.bible[_memoryPointerKey] as num?)?.toInt() ?? 0;
    for (final m in db.recentMessages(c.id!, limit: 60).reversed) {
      if (m.role == MessageRole.system) continue;
      // Lo ya resumido en la memoria no hace falta repetirlo (salvo lo último).
      if (m.id! <= upTo && history.length >= 6) break;
      final t = m.role == MessageRole.player ? '[${m.speaker}] ${m.content}' : m.content;
      final cost = estimateTokens(t) + 8;
      if (used + cost > budget && history.isNotEmpty) break;
      used += cost;
      history.insert(0, m.role == MessageRole.player ? LlmMessage.user(t) : LlmMessage.assistant(t));
    }
    // Garantiza que la conversación termina con el turno del jugador.
    if (history.isEmpty || history.last.role != LlmRole.user) {
      history.add(LlmMessage.user(playerText));
    }
    return [LlmMessage.system(system), ...history];
  }

  /// Cierra la sesión generando el resumen que se usará al continuar.
  Future<String> endSession(Campaign c, GameSession s) async {
    await _background;
    final msgs = db.messagesForSession(s.id!);
    var summary = '';
    if (msgs.where((m) => m.role != MessageRole.system).length > 1 && llm.isReady) {
      final buf = StringBuffer();
      var transcript = Prompts.transcript(msgs);
      final maxChars = (config.contextSize - 1200) * 3;
      if (transcript.length > maxChars) transcript = transcript.substring(transcript.length - maxChars);
      await for (final ch in llm.chat(
        [
          const LlmMessage.system('Eres el cronista de una partida de rol.'),
          LlmMessage.user(Prompts.sessionSummaryRequest(transcript)),
        ],
        temperature: 0.4,
        maxTokens: 700,
      )) {
        buf.write(ch.text);
      }
      summary = buf.toString().trim();
    }
    db.endSession(s, summary);
    if (summary.isNotEmpty) {
      await rag.addText(c.id!, 'resumen sesión ${s.number}', summary);
    }
    return summary;
  }

  /// Responde preguntas sobre partidas pasadas usando los logs ("¿qué pasó en
  /// la sesión 2?").
  Stream<String> askAboutLogs(Campaign c, String question) async* {
    final hits = await rag.search(c.id!, question, k: 8);
    final sessions = db.sessions(c.id!).where((s) => s.summary.isNotEmpty);
    final ctx = StringBuffer()
      ..writeln('Resúmenes de sesiones:')
      ..writeln(sessions.map((s) => 'Sesión ${s.number}: ${s.summary}').join('\n'))
      ..writeln('\nFragmentos:')
      ..writeln(hits.map((h) => '- ${h.chunk.text}').join('\n'));
    await for (final ch in llm.chat(
      [
        const LlmMessage.system('Respondes preguntas sobre el historial de una campaña de rol usando sólo los datos dados.'),
        LlmMessage.user('$ctx\n\nPregunta: $question'),
      ],
      temperature: 0.3,
      maxTokens: 600,
    )) {
      if (ch.text.isNotEmpty) yield ch.text;
    }
  }
}
