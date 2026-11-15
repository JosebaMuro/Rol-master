/// Una pieza de un modelo de imágenes que se descarga.
class ImageModelFile {
  const ImageModelFile(this.role, this.name, this.url, this.bytes);

  /// 'model' (modelo de difusión o fichero único), 'vae' o 'llm'
  /// (codificador de texto).
  final String role;
  final String name;
  final String url;
  final int bytes;
}

/// Modelo recomendado para generar imágenes en local con stable-diffusion.cpp.
class ImageModelPreset {
  const ImageModelPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.files,
    required this.steps,
    required this.cfg,
    this.target = 'pc',
  });
  final String id;
  /// 'pc' o 'móvil'.
  final String target;
  final String label;
  final String description;
  final List<ImageModelFile> files;
  final int steps;
  final double cfg;

  double get sizeGb => files.fold<int>(0, (a, f) => a + f.bytes) / 1e9;
}

const imageModelPresets = <ImageModelPreset>[
  ImageModelPreset(
    id: 'sd-turbo',
    label: 'SD-Turbo (Q8)',
    description: 'Ligero y rápido: un solo fichero que cabe en el móvil y dibuja en 4 pasos. Calidad '
        'sencilla y sólo entiende inglés (la app le traduce la descripción con la IA). Para móviles con 8 GB '
        'de RAM o más; tarda de medio minuto a unos minutos por imagen.',
    steps: 4,
    cfg: 1.0,
    target: 'móvil',
    files: [
      ImageModelFile(
        'model',
        'sd_turbo-f16-q8_0.gguf',
        'https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/main/sd_turbo-f16-q8_0.gguf',
        2023745376,
      ),
    ],
  ),
  ImageModelPreset(
    id: 'z-image-turbo',
    label: 'Z-Image Turbo (Q4)',
    description: 'Muy buena calidad en 8 pasos y entiende el español. Tres ficheros; gráfica con 4 GB de '
        'memoria o más (sin gráfica funciona, pero tarda minutos por imagen). Licencia Apache 2.0.',
    steps: 8,
    cfg: 1.0,
    files: [
      ImageModelFile(
        'model',
        'z_image_turbo-Q4_K.gguf',
        'https://huggingface.co/leejet/Z-Image-Turbo-GGUF/resolve/main/z_image_turbo-Q4_K.gguf',
        3864250304,
      ),
      ImageModelFile(
        'llm',
        'Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
        'https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
        2497281120,
      ),
      ImageModelFile(
        'vae',
        'z_image_ae.safetensors',
        'https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors',
        335304388,
      ),
    ],
  ),
];
