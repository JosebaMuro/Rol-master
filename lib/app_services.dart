import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai/campaign_builder.dart';
import 'ai/director.dart';
import 'ai/llama_service.dart';
import 'ai/memory/graph.dart';
import 'ai/memory/rag.dart';
import 'core/db.dart';
import 'core/portable.dart';
import 'core/settings.dart';
import 'docs/doc_library.dart';
import 'logs/log_service.dart';
import 'maps/map_service.dart';
import 'music/music_service.dart';
import 'voice/speech_input.dart';
import 'voice/voice_packs.dart';
import 'voice/voice_service.dart';

/// Contenedor de todos los servicios de la app.
class AppServices {
  AppServices._({
    required this.settings,
    required this.db,
    required this.llm,
    required this.rag,
    required this.graph,
    required this.voicePacks,
    required this.voices,
    required this.music,
    required this.maps,
    required this.logs,
    required this.docs,
    required this.dataRoot,
    required this.speech,
  });

  final AppSettings settings;
  final AppDatabase db;
  final LlamaService llm;
  final RagMemory rag;
  final KnowledgeGraph graph;
  final VoicePackManager voicePacks;
  final VoiceService voices;
  final MusicService music;
  final MapService maps;
  final LogService logs;
  final DocLibrary docs;
  /// Micrófono + reconocimiento de voz local.
  final SpeechInput speech;
  /// Carpeta única con todos los datos (portable).
  final DataRoot dataRoot;
  String get dataDir => dataRoot.root;

  static Future<AppServices> init() async {
    String fallback;
    try {
      fallback = p.join((await getApplicationDocumentsDirectory()).path, 'DirectorDeRol');
    } catch (_) {
      fallback = p.join((await getApplicationSupportDirectory()).path, 'DirectorDeRol');
    }
    String? androidDir;
    if (Platform.isAndroid) {
      // Carpeta externa de la app: se ve desde el PC por USB
      // (Android/data/<paquete>/files/DirectorDeRol).
      final ext = await getExternalStorageDirectory();
      if (ext != null) androidDir = p.join(ext.path, 'DirectorDeRol');
      fallback = p.join((await getApplicationSupportDirectory()).path, 'DirectorDeRol');
    }
    final root = DataRoot.locate(fallback: fallback, androidDir: androidDir);
    final settings = AppSettings.load(root.settingsFile);

    final db = AppDatabase.open(root.database, root: root);
    final llm = LlamaService(settings, root);
    final rag = RagMemory(db, llm);
    final graph = KnowledgeGraph(db);
    final packs = VoicePackManager(root.voices);
    await packs.refresh();
    final voices = VoiceService(settings: settings, packs: packs, tempDir: root.tmp);
    final music = MusicService(db, settings, root)..init();
    voices.onSpeakingChanged = music.duck;
    final maps = MapService(db, llm, root.maps);
    final logs = LogService(db, root.logs, exportsDir: root.exports);

    final s = AppServices._(
      settings: settings,
      db: db,
      llm: llm,
      rag: rag,
      graph: graph,
      voicePacks: packs,
      voices: voices,
      music: music,
      maps: maps,
      logs: logs,
      docs: DocLibrary(db, rag, llm, root),
      dataRoot: root,
      speech: SpeechInput(root.speech, selectedModel: settings.speechModel),
    );
    // Carga en segundo plano para no retrasar el arranque.
    voices.init();
    if (settings.chatModel.isNotEmpty) llm.loadChatModel();
    if (settings.embedModel.isNotEmpty) llm.loadEmbedModel();
    return s;
  }

  DirectorConfig get directorConfig => DirectorConfig(
        temperature: settings.temperature,
        maxTokens: settings.maxTokens,
        thinking: settings.thinking,
        thinkingBudget: settings.thinkingBudget,
        contextSize: settings.contextSize,
        worldEvery: settings.worldEvery,
      );

  Director director() => Director(
        db: db,
        llm: llm,
        rag: rag,
        graph: graph,
        config: directorConfig,
        voiceAssigner: voices.assign,
      );

  CampaignBuilder campaignBuilder() => CampaignBuilder(
        db: db,
        llm: llm,
        rag: rag,
        graph: graph,
        voiceAssigner: voices.assign,
      );

  Future<void> dispose() async {
    await voices.stop();
    await music.stop();
    speech.dispose();
    await llm.shutdown();
    db.close();
  }
}
