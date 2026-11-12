import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai/campaign_builder.dart';
import 'ai/director.dart';
import 'ai/llama_service.dart';
import 'ai/memory/graph.dart';
import 'ai/memory/rag.dart';
import 'core/db.dart';
import 'core/settings.dart';
import 'logs/log_service.dart';
import 'maps/map_service.dart';
import 'music/music_service.dart';
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
    required this.dataDir,
    required this.documentsDir,
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
  final String dataDir;
  final String documentsDir;

  static Future<AppServices> init() async {
    final settings = await AppSettings.load();
    final support = await getApplicationSupportDirectory();
    final dataDir = p.join(support.path, 'DirectorDeRol');
    Directory(dataDir).createSync(recursive: true);

    String docs;
    try {
      docs = p.join((await getApplicationDocumentsDirectory()).path, 'DirectorDeRol');
    } catch (_) {
      docs = p.join(dataDir, 'documentos');
    }
    if (Platform.isAndroid) {
      // En Android, la carpeta externa de la app es accesible desde el PC
      // (Android/data/<paquete>/files/DirectorDeRol).
      final ext = await getExternalStorageDirectory();
      if (ext != null) docs = p.join(ext.path, 'DirectorDeRol');
    }
    Directory(docs).createSync(recursive: true);

    final db = AppDatabase.open(p.join(dataDir, 'director.db'));
    final llm = LlamaService(settings);
    final rag = RagMemory(db, llm);
    final graph = KnowledgeGraph(db);
    final packs = VoicePackManager(p.join(dataDir, 'voces'));
    await packs.refresh();
    final tmp = await getTemporaryDirectory();
    final voices = VoiceService(settings: settings, packs: packs, tempDir: tmp.path);
    final music = MusicService(db, settings)..init();
    voices.onSpeakingChanged = music.duck;
    final maps = MapService(db, llm, p.join(docs, 'mapas'));
    final logs = LogService(db, p.join(docs, 'logs'));

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
      dataDir: dataDir,
      documentsDir: docs,
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
    await llm.shutdown();
    db.close();
  }
}
