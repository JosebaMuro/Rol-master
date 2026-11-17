import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../core/portable.dart';
import '../core/settings.dart';
import 'llm.dart';
import 'model_catalog.dart';

enum EngineStatus { empty, downloading, loading, ready, error }

/// Motor de inferencia local basado en llama.cpp (paquete llamadart).
///
/// * Windows / Linux: CUDA (NVIDIA) si está incluido, Vulkan (NVIDIA, AMD o
///   Intel) o CPU. En «Auto» se elige la mejor GPU dedicada que haya.
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

  /// Dónde se ejecuta el modelo cargado, en palabras («GPU NVIDIA … (CUDA) ·
  /// 37 capas» o «CPU: …»). Vacío si no hay modelo.
  String gpuSummary = '';

  /// El modelo cargado tiene capas en la GPU.
  bool onGpu = false;

  /// GPUs que ve llama.cpp en este equipo (se rellena al cargar un modelo).
  List<GpuDeviceInfo> gpus = const [];
  String loadedModel = '';
  String loadedEmbedModel = '';

  /// El modelo cargado ve imágenes (se cargó con su proyector de visión).
  bool vision = false;

  /// El modelo cargado tiene modo de razonamiento propio; si no, razona guiado.
  bool nativeThinking = true;
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

  @override
  bool get canSee => isReady && vision;

  ModelSource _source(String uri) {
    final looksLocal = !uri.contains('://') || uri.startsWith('file://');
    if (looksLocal) return ModelSource.path(dataRoot.resolve(uri.replaceFirst('file://', '')));
    return ModelSource.parse(uri);
  }

  ModelParams _params({required bool embedding, GpuChoice? choice}) {
    final device = switch (settings.device) {
      'cpu' => ComputeDevice.cpu,
      'gpu' => ComputeDevice.gpu,
      _ => ComputeDevice.auto,
    };
    var backend = switch (settings.backend) {
      'vulkan' => GpuBackend.vulkan,
      'cuda' => GpuBackend.cuda,
      'opencl' => GpuBackend.opencl,
      'cpu' => GpuBackend.cpu,
      _ => GpuBackend.auto,
    };
    List<int>? devices;
    if (device != ComputeDevice.cpu && choice != null && (backend == GpuBackend.auto || backend == choice.backend)) {
      backend = choice.backend;
      devices = choice.devices;
    }
    return ModelParams(
      contextSize: embedding ? 2048 : settings.contextSize,
      device: device,
      preferredBackend: device == ComputeDevice.cpu ? GpuBackend.auto : backend,
      gpuLayers: device == ComputeDevice.cpu ? 0 : settings.gpuLayers,
      gpuDevices: devices,
    );
  }

  /// Busca las GPUs del equipo (CUDA y Vulkan) y elige dónde cargar.
  /// En Android se deja la elección de siempre (CPU salvo que se pida GPU).
  Future<GpuChoice?> _chooseGpu(LlamaEngine engine) async {
    if (!(Platform.isWindows || Platform.isLinux)) return null;
    if (settings.device == 'cpu') return null;
    final found = <GpuDeviceInfo>[];
    for (final b in const [GpuBackend.cuda, GpuBackend.vulkan]) {
      try {
        found.addAll(await engine.listGpuDevices(probeBackends: [b]));
      } catch (e) {
        debugPrint('No se pudieron listar las GPU ${b.name}: $e');
      }
    }
    // Sin duplicados (cada sonda devuelve también lo ya registrado).
    final seen = <String>{};
    gpus = [
      for (final d in found)
        if (seen.add('${d.backend.name}:${d.mainGpu}')) d,
    ];
    debugPrint('GPUs vistas: ${gpus.join(', ')}');
    return GpuChoice.pick(gpus, settings.backend);
  }

  /// Resume en palabras dónde ha quedado el modelo tras cargarlo.
  Future<void> _describePlacement(LlamaEngine engine, GpuChoice? choice) async {
    int? layers;
    try {
      layers = await engine.getResolvedGpuLayers();
    } catch (_) {}
    onGpu = (layers ?? 0) > 0;
    if (onGpu) {
      final where = choice?.label ?? backendName;
      final n = layers! >= 99 ? 'todas las capas' : '$layers capas';
      gpuSummary = 'GPU: $where · $n';
    } else if (settings.device == 'cpu' || settings.gpuLayers == 0) {
      gpuSummary = 'CPU (elegido en Ajustes)';
    } else if (gpus.isEmpty && (Platform.isWindows || Platform.isLinux)) {
      gpuSummary = 'CPU: no se ha encontrado ninguna GPU compatible. '
          'Actualiza el controlador de la tarjeta gráfica.';
    } else {
      gpuSummary = 'CPU: la GPU no se ha podido usar con este backend';
    }
  }

  /// Carga (y descarga si hace falta) el modelo de chat. Si el modelo tiene
  /// proyector de visión (el del catálogo o [projector]) se carga con él.
  Future<void> loadChatModel([String? uri, String? projector]) async {
    uri ??= settings.chatModel;
    if (uri.isEmpty) {
      message = 'Elige un modelo en Ajustes';
      notifyListeners();
      return;
    }
    if (_busy) return;
    projector ??= chatPresetFor(uri)?.projector ??
        (dataRoot.toStored(uri) == settings.chatModel ? settings.chatProjector : '');
    _busy = true;
    status = EngineStatus.downloading;
    progress = null;
    message = 'Preparando modelo…';
    notifyListeners();
    try {
      final engine = _chat ?? LlamaEngine(LlamaBackend());
      _chat = engine;
      void onProgress(ModelDownloadProgress p) {
        progress = p.fraction;
        final mb = (p.receivedBytes / 1e6).toStringAsFixed(0);
        final total = p.totalBytes == null ? '' : ' / ${(p.totalBytes! / 1e6).toStringAsFixed(0)} MB';
        message = 'Descargando modelo: $mb MB$total';
        notifyListeners();
      }

      var visionError = '';
      final String modelUri = uri;
      final String proj = projector;
      Future<void> attempt(GpuChoice? choice) async {
        visionError = '';
        vision = false;
        if (proj.isNotEmpty) {
          try {
            await engine.setModel(
              LlamaModel(_source(modelUri), projector: _source(proj)),
              params: _params(embedding: false, choice: choice),
              download: _download,
              onProgress: onProgress,
            );
            vision = await engine.supportsVision;
            if (!vision) visionError = 'el proyector no da visión en este equipo';
          } catch (e, st) {
            // Sin proyector el modelo sigue sirviendo para narrar.
            debugPrint('No se pudo cargar con visión: $e\n$st');
            visionError = '$e';
            await engine.setModel(
              LlamaModel(_source(modelUri)),
              params: _params(embedding: false, choice: choice),
              download: _download,
              onProgress: onProgress,
            );
          }
        } else {
          await engine.setModel(
            LlamaModel(_source(modelUri)),
            params: _params(embedding: false, choice: choice),
            download: _download,
            onProgress: onProgress,
          );
        }
      }

      var choice = await _chooseGpu(engine);
      try {
        await attempt(choice);
      } catch (e) {
        // Si CUDA falla (controlador antiguo, falta de memoria…), se prueba
        // con Vulkan en la misma tarjeta antes de rendirse.
        final vulkan = choice?.backend == GpuBackend.cuda && settings.backend == 'auto'
            ? GpuChoice.pick(gpus.where((g) => g.backend != GpuBackend.cuda).toList(), 'vulkan')
            : null;
        if (vulkan == null) rethrow;
        debugPrint('CUDA no ha podido cargar el modelo ($e); se prueba con Vulkan');
        choice = vulkan;
        await attempt(choice);
      }
      status = EngineStatus.loading;
      notifyListeners();
      backendName = await engine.getBackendName();
      await _describePlacement(engine, choice);
      loadedModel = uri;
      nativeThinking = hasNativeThinking(uri);
      settings.chatModel = dataRoot.toStored(uri);
      settings.chatProjector = projector.isEmpty ? '' : dataRoot.toStored(projector);
      settings.addRecentModel(dataRoot.toStored(uri));
      status = EngineStatus.ready;
      message = 'Listo · ${gpuSummary.isEmpty ? backendName : gpuSummary}'
          '${vision ? ' · ve imágenes' : ''}'
          '${visionError.isEmpty ? '' : ' · sin visión ($visionError)'}';
    } catch (e, st) {
      debugPrint('Error cargando modelo: $e\n$st');
      status = EngineStatus.error;
      vision = false;
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
      final choice = await _chooseGpu(engine);
      await engine.setModel(LlamaModel(_source(uri)), params: _params(embedding: true, choice: choice), download: _download);
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

  LlamaChatRole _role(LlmRole r) => switch (r) {
        LlmRole.system => LlamaChatRole.system,
        LlmRole.user => LlamaChatRole.user,
        LlmRole.assistant => LlamaChatRole.assistant,
      };

  List<LlamaChatMessage> _convert(List<LlmMessage> messages) => [
        for (final m in messages)
          if (vision && m.images.isNotEmpty)
            LlamaChatMessage.withContent(
              role: _role(m.role),
              content: [
                for (final path in m.images) LlamaImageContent(path: path),
                LlamaTextContent(m.text),
              ],
            )
          else
            LlamaChatMessage.fromText(role: _role(m.role), text: m.text),
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
    final budget = thinkingBudget ?? 1024;
    // Los modelos sin modo de razonamiento propio (Gemma 3…) piensan «guiados»:
    // se les pide un bloque <think>…</think> que aquí se separa de la narración.
    final guided = thinking && !nativeThinking;
    GenerationParams params(bool withThinking) => GenerationParams(
          maxTokens: maxTokens + (withThinking ? budget : 0),
          temp: temperature,
          topP: 0.92,
          penalty: 1.08,
          thinkingBudget:
              withThinking && !guided && thinkingBudget != null ? ThinkingBudget(maxTokens: thinkingBudget) : null,
        );
    final release = await _acquire();
    try {
      final input = guided ? withGuidedThinking(messages, budget) : messages;
      final splitter = ThinkSplitter();
      var thought = 0;
      var runaway = false;
      await for (final c in engine.create(
        _convert(input),
        params: params(thinking),
        enableThinking: thinking && !guided,
      )) {
        final split = splitter.add(c.text);
        final chunk = LlmChunk(text: split.text, thinking: c.thinking + split.thinking);
        if (chunk.text.isNotEmpty || chunk.thinking.isNotEmpty) yield chunk;
        if (guided) {
          thought += split.thinking.length;
          // Si no cierra el bloque no quedaría sitio para la narración.
          if (splitter.inside && thought / 3.5 > budget * 1.25) {
            runaway = true;
            break;
          }
        }
      }
      if (runaway) {
        engine.cancelGeneration();
        yield const LlmChunk(thinking: '…\n');
        await for (final c in engine.create(_convert(messages), params: params(false), enableThinking: false)) {
          if (c.text.isNotEmpty) yield LlmChunk(text: c.text);
        }
      } else {
        final rest = splitter.close();
        if (rest.text.isNotEmpty || rest.thinking.isNotEmpty) yield rest;
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
    if (Platform.isWindows) return 'Windows · CUDA / Vulkan / CPU';
    if (Platform.isLinux) return 'Linux · CUDA / Vulkan / CPU';
    return Platform.operatingSystem;
  }
}

/// Dónde cargar el modelo: backend, GPUs concretas y su nombre para mostrar.
class GpuChoice {
  const GpuChoice(this.backend, this.devices, this.label);

  final GpuBackend backend;

  /// Índices (`mainGpu`) de las GPU a usar; null = las que elija llama.cpp.
  final List<int>? devices;
  final String label;

  static bool _isGpu(GpuDeviceInfo d) =>
      d.type == GpuDeviceType.discreteGpu || d.type == GpuDeviceType.integratedGpu;

  /// Elige la GPU: CUDA si hay una tarjeta NVIDIA con CUDA, si no Vulkan; y
  /// dentro del backend la dedicada con más memoria (no la integrada, que
  /// repartiría el modelo y lo haría más lento). [wanted] es el backend
  /// elegido en Ajustes ('auto', 'cuda', 'vulkan'…).
  static GpuChoice? pick(List<GpuDeviceInfo> gpus, String wanted) {
    final order = switch (wanted) {
      'cuda' => const [GpuBackend.cuda],
      'vulkan' => const [GpuBackend.vulkan],
      'auto' => const [GpuBackend.cuda, GpuBackend.vulkan],
      _ => const <GpuBackend>[],
    };
    for (final b in order) {
      final list = gpus.where((d) => d.backend == b && _isGpu(d)).toList();
      if (list.isEmpty) continue;
      final dedicated = list.where((d) => d.isDiscreteGpu).toList();
      final pool = dedicated.isEmpty ? list : dedicated;
      pool.sort((a, c) => c.memoryTotalBytes.compareTo(a.memoryTotalBytes));
      final best = pool.first;
      final name = best.description.isNotEmpty ? best.description : best.name;
      final gb = best.memoryTotalBytes > 0 ? ' · ${(best.memoryTotalBytes / (1 << 30)).toStringAsFixed(1)} GB' : '';
      final label = '$name (${b == GpuBackend.cuda ? 'CUDA' : 'Vulkan'}$gb)';
      // Sólo se fija el dispositivo cuando hay varios donde elegir.
      final devices = list.length > 1 ? [best.mainGpu] : null;
      return GpuChoice(b, devices, label);
    }
    return null;
  }
}
