import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../core/portable.dart';
import '../core/settings.dart';
import 'llm.dart';

enum EngineStatus { empty, downloading, loading, ready, error }

/// Motor de inferencia local basado en llama.cpp (paquete llamadart).
///
/// * Windows / Linux: backend Vulkan (GPU NVIDIA, AMD o Intel) o CPU; CUDA si
///   se compila con ese módulo.
/// * Android: CPU optimizada ARM (NEON/i8mm) y Vulkan opcional.
///
/// Mantiene dos motores: uno de chat (narrador) y otro opcional de
/// embeddings para la memoria semántica (RAG).
class LlamaService extends ChangeNotifier implements TextGenerator {
  LlamaService(this.settings, this.dataRoot);

  final AppSettings settings;

  /// Los modelos se descargan dentro de la carpeta de datos (portable).
  final DataRoot dataRoot;

  ModelLoadOptions get _download => ModelLoadOptions(cacheDirectory: dataRoot.models);

  LlamaEngine? _chat;
  LlamaEngine? _embed;

  EngineStatus status = EngineStatus.empty;
  EngineStatus embedStatus = EngineStatus.empty;
  double? progress;
  String message = 'Sin modelo cargado';
  String backendName = '';
  String loadedModel = '';
  String loadedEmbedModel = '';
  bool _busy = false;

  /// Cola para que sólo haya una generación a la vez en el motor.
  Future<void> _tail = Future.value();

  Future<void Function()> _acquire() async {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await prev;
    return done.complete;
  }

  @override
  bool get isReady => status == EngineStatus.ready && _chat != null;

  @override
  bool get canEmbed => embedStatus == EngineStatus.ready && _embed != null;

  ModelSource _source(String uri) {
    final looksLocal = !uri.contains('://') || uri.startsWith('file://');
    if (looksLocal) return ModelSource.path(dataRoot.resolve(uri.replaceFirst('file://', '')));
    return ModelSource.parse(uri);
  }

  ModelParams _params({required bool embedding}) {
    final device = switch (settings.device) {
      'cpu' => ComputeDevice.cpu,
      'gpu' => ComputeDevice.gpu,
      _ => ComputeDevice.auto,
    };
    final backend = switch (settings.backend) {
      'vulkan' => GpuBackend.vulkan,
      'cuda' => GpuBackend.cuda,
      'opencl' => GpuBackend.opencl,
      'cpu' => GpuBackend.cpu,
      _ => GpuBackend.auto,
    };
    return ModelParams(
      contextSize: embedding ? 2048 : settings.contextSize,
      device: device,
      preferredBackend: device == ComputeDevice.cpu ? GpuBackend.auto : backend,
      gpuLayers: device == ComputeDevice.cpu ? 0 : settings.gpuLayers,
    );
  }

  /// Carga (y descarga si hace falta) el modelo de chat.
  Future<void> loadChatModel([String? uri]) async {
    uri ??= settings.chatModel;
    if (uri.isEmpty) {
      message = 'Elige un modelo en Ajustes';
      notifyListeners();
      return;
    }
    if (_busy) return;
    _busy = true;
    status = EngineStatus.downloading;
    progress = null;
    message = 'Preparando modelo…';
    notifyListeners();
    try {
      final engine = _chat ?? LlamaEngine(LlamaBackend());
      _chat = engine;
      await engine.setModel(
        LlamaModel(_source(uri)),
        params: _params(embedding: false),
        download: _download,
        onProgress: (p) {
          progress = p.fraction;
          final mb = (p.receivedBytes / 1e6).toStringAsFixed(0);
          final total = p.totalBytes == null ? '' : ' / ${(p.totalBytes! / 1e6).toStringAsFixed(0)} MB';
          message = 'Descargando modelo: $mb MB$total';
          notifyListeners();
        },
      );
      status = EngineStatus.loading;
      notifyListeners();
      backendName = await engine.getBackendName();
      loadedModel = uri;
      settings.chatModel = dataRoot.toStored(uri);
      settings.addRecentModel(dataRoot.toStored(uri));
      status = EngineStatus.ready;
      message = 'Listo · $backendName';
    } catch (e, st) {
      debugPrint('Error cargando modelo: $e\n$st');
      status = EngineStatus.error;
      message = 'Error al cargar el modelo: $e';
    } finally {
      _busy = false;
      progress = null;
      notifyListeners();
    }
  }

  Future<void> loadEmbedModel([String? uri]) async {
    uri ??= settings.embedModel;
    if (uri.isEmpty) return;
    embedStatus = EngineStatus.downloading;
    notifyListeners();
    try {
      final engine = _embed ?? LlamaEngine(LlamaBackend());
      _embed = engine;
      await engine.setModel(LlamaModel(_source(uri)), params: _params(embedding: true), download: _download);
      loadedEmbedModel = uri;
      settings.embedModel = dataRoot.toStored(uri);
      embedStatus = EngineStatus.ready;
    } catch (e) {
      debugPrint('Error cargando embeddings: $e');
      embedStatus = EngineStatus.error;
    }
    notifyListeners();
  }

  Future<void> unloadEmbedModel() async {
    final e = _embed;
    _embed = null;
    embedStatus = EngineStatus.empty;
    settings.embedModel = '';
    notifyListeners();
    await e?.dispose();
  }

  List<LlamaChatMessage> _convert(List<LlmMessage> messages) => [
        for (final m in messages)
          LlamaChatMessage.fromText(
            role: switch (m.role) {
              LlmRole.system => LlamaChatRole.system,
              LlmRole.user => LlamaChatRole.user,
              LlmRole.assistant => LlamaChatRole.assistant,
            },
            text: m.text,
          ),
      ];

  @override
  Stream<LlmChunk> chat(
    List<LlmMessage> messages, {
    double temperature = 0.8,
    int maxTokens = 1024,
    bool thinking = false,
    int? thinkingBudget,
  }) async* {
    final engine = _chat;
    if (engine == null || !isReady) throw StateError('No hay modelo cargado');
    final params = GenerationParams(
      maxTokens: maxTokens + (thinking ? (thinkingBudget ?? 1024) : 0),
      temp: temperature,
      topP: 0.92,
      penalty: 1.08,
      thinkingBudget: thinking && thinkingBudget != null ? ThinkingBudget(maxTokens: thinkingBudget) : null,
    );
    final release = await _acquire();
    try {
      await for (final c in engine.create(_convert(messages), params: params, enableThinking: thinking)) {
        if (c.text.isNotEmpty || c.thinking.isNotEmpty) {
          yield LlmChunk(text: c.text, thinking: c.thinking);
        }
      }
    } finally {
      release();
    }
  }

  @override
  Future<Map<String, dynamic>> json(
    List<LlmMessage> messages, {
    required Map<String, dynamic> schema,
    int maxTokens = 1024,
    double temperature = 0.4,
  }) async {
    final engine = _chat;
    if (engine == null || !isReady) throw StateError('No hay modelo cargado');
    final release = await _acquire();
    try {
      return await _json(engine, messages, schema, maxTokens, temperature);
    } finally {
      release();
    }
  }

  Future<Map<String, dynamic>> _json(
    LlamaEngine engine,
    List<LlmMessage> messages,
    Map<String, dynamic> schema,
    int maxTokens,
    double temperature,
  ) async {
    try {
      return await engine.createStructuredJson<Map<String, dynamic>>(
        _convert(messages),
        output: LlamaStructuredOutput<Map<String, dynamic>>.jsonSchema(
          schema: schema,
          decoder: (j) => j,
          strict: false,
        ),
        params: GenerationParams(maxTokens: maxTokens, temp: temperature),
        enableThinking: false,
      );
    } on LlamaException catch (e) {
      // Reintento sin gramática: texto libre y extracción del JSON.
      debugPrint('JSON estructurado no disponible ($e), reintentando en texto libre');
      final buf = StringBuffer();
      await for (final c in engine.create(
        _convert([
          ...messages,
          const LlmMessage.user('Responde SOLO con un objeto JSON válido, sin texto adicional.'),
        ]),
        params: GenerationParams(maxTokens: maxTokens, temp: temperature),
        enableThinking: false,
      )) {
        buf.write(c.text);
      }
      return extractJsonObject(buf.toString());
    }
  }

  @override
  Future<List<double>?> embed(String text, {bool query = false}) async {
    final engine = _embed;
    if (engine == null || !canEmbed) return null;
    final prepared = query ? 'task: search result | query: $text' : 'title: none | text: $text';
    try {
      return await engine.embed(prepared);
    } catch (e) {
      debugPrint('Error en embedding: $e');
      return null;
    }
  }

  @override
  void cancel() => _chat?.cancelGeneration();

  /// Libera los motores. Hay que esperar a que termine antes de salir de la app.
  Future<void> shutdown() async {
    final c = _chat, e = _embed;
    _chat = null;
    _embed = null;
    await e?.dispose();
    await c?.dispose();
  }

  static String platformHint() {
    if (Platform.isAndroid) return 'Android · CPU ARM (Vulkan opcional)';
    if (Platform.isWindows) return 'Windows · Vulkan / CPU';
    if (Platform.isLinux) return 'Linux · Vulkan / CPU';
    return Platform.operatingSystem;
  }
}
