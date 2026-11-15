/// Modelos recomendados. Todos son GGUF y se ejecutan en local con llama.cpp.
/// Se descargan una vez desde Hugging Face y quedan en caché.
class ModelPreset {
  const ModelPreset({
    required this.id,
    required this.label,
    required this.uri,
    required this.sizeGb,
    required this.minRamGb,
    required this.target,
    required this.description,
    this.reasoning = false,
    this.projector,
  });
  final String id;
  final String label;
  final String uri;
  final double sizeGb;
  final int minRamGb;

  /// 'móvil', 'pc' o 'ambos'.
  final String target;
  final String description;

  /// Si el modelo tiene modo de razonamiento propio (thinking). Los que no lo
  /// tienen razonan «guiados»: se les pide pensar dentro de `<think>…</think>`.
  final bool reasoning;

  /// URI del proyector de visión (mmproj) que acompaña al modelo, si ve
  /// imágenes. Se descarga y se carga junto con él.
  final String? projector;

  bool get vision => projector != null;
}

ModelPreset? chatPresetFor(String uri) {
  for (final m in chatPresets) {
    if (m.uri == uri) return m;
  }
  return null;
}

/// Familias con modo de razonamiento propio, para modelos que no están en el
/// catálogo (un .gguf local o una URL).
final _nativeThinkingNames = RegExp(
  r'qwen3|qwq|deepseek-?r1|[-_.]r1[-_.]|gpt-oss|smollm3|magistral|reason|think|cogito|granite-3\.[2-9]',
  caseSensitive: false,
);

/// Si el modelo de [uri] razona por sí mismo cuando se le pide (enable_thinking).
bool hasNativeThinking(String uri) {
  final preset = chatPresetFor(uri);
  if (preset != null) return preset.reasoning;
  return _nativeThinkingNames.hasMatch(uri.split(RegExp(r'[/\\]')).last);
}

const chatPresets = <ModelPreset>[
  ModelPreset(
    id: 'qwen3-1.7b',
    label: 'Qwen3 1.7B (Q4_K_M)',
    uri: 'hf://unsloth/Qwen3-1.7B-GGUF/Qwen3-1.7B-Q4_K_M.gguf',
    sizeGb: 1.1,
    minRamGb: 4,
    target: 'móvil',
    reasoning: true,
    description: 'Ligero, para móviles de gama media. Razona, pero las historias son más simples.',
  ),
  ModelPreset(
    id: 'qwen3-4b',
    label: 'Qwen3 4B (Q4_K_M)',
    uri: 'hf://unsloth/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf',
    sizeGb: 2.5,
    minRamGb: 6,
    target: 'ambos',
    reasoning: true,
    description: 'Equilibrio recomendado: móviles de gama alta y cualquier PC moderno.',
  ),
  ModelPreset(
    id: 'qwen3-8b',
    label: 'Qwen3 8B (Q4_K_M)',
    uri: 'hf://unsloth/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf',
    sizeGb: 5.0,
    minRamGb: 10,
    target: 'pc',
    reasoning: true,
    description: 'Narrativa rica y buen razonamiento. Ideal en PC con GPU (Vulkan/CUDA).',
  ),
  ModelPreset(
    id: 'qwen3-14b',
    label: 'Qwen3 14B (Q4_K_M)',
    uri: 'hf://unsloth/Qwen3-14B-GGUF/Qwen3-14B-Q4_K_M.gguf',
    sizeGb: 9.0,
    minRamGb: 16,
    target: 'pc',
    reasoning: true,
    description: 'La mejor calidad para PC con GPU de 12 GB o más.',
  ),
  ModelPreset(
    id: 'gemma3-4b',
    label: 'Gemma 3 4B (Q4_K_M) + visión',
    uri: 'hf://ggml-org/gemma-3-4b-it-GGUF/gemma-3-4b-it-Q4_K_M.gguf',
    projector: 'hf://ggml-org/gemma-3-4b-it-GGUF/mmproj-model-f16.gguf',
    sizeGb: 3.3,
    minRamGb: 8,
    target: 'ambos',
    description: 'Alternativa a Qwen3 4B: ve las imágenes que le enseñes (mapas, fichas, fotos) '
        'y razona guiado antes de narrar.',
  ),
  ModelPreset(
    id: 'gemma3-12b',
    label: 'Gemma 3 12B (Q4_K_M) + visión',
    uri: 'hf://ggml-org/gemma-3-12b-it-GGUF/gemma-3-12b-it-Q4_K_M.gguf',
    projector: 'hf://ggml-org/gemma-3-12b-it-GGUF/mmproj-model-f16.gguf',
    sizeGb: 8.2,
    minRamGb: 16,
    target: 'pc',
    description: 'Alternativa a Qwen3 8B/14B para PC con GPU de 10 GB o más. Muy buen español, '
        've imágenes y razona guiado.',
  ),
];

const embedPresets = <ModelPreset>[
  ModelPreset(
    id: 'embeddinggemma-300m',
    label: 'EmbeddingGemma 300M (Q8_0)',
    uri: 'hf://ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf',
    sizeGb: 0.33,
    minRamGb: 2,
    target: 'ambos',
    description: 'Embeddings multilingües para la memoria semántica (RAG).',
  ),
];
