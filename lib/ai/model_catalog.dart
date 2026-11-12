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
  });
  final String id;
  final String label;
  final String uri;
  final double sizeGb;
  final int minRamGb;

  /// 'móvil', 'pc' o 'ambos'.
  final String target;
  final String description;

  /// Si el modelo tiene modo de razonamiento (thinking).
  final bool reasoning;
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
