import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http_pkg;
import 'package:path/path.dart' as p;

/// Lo que se le pide al generador de imágenes.
class ImageRequest {
  const ImageRequest({
    required this.prompt,
    this.negative = '',
    this.width = 768,
    this.height = 512,
    this.seed = -1,
  });
  final String prompt;
  final String negative;
  final int width;
  final int height;

  /// Semilla (-1 = al azar). La misma semilla y texto dan la misma imagen.
  final int seed;
}

class ImageEngineException implements Exception {
  ImageEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Un motor capaz de dibujar una imagen a partir de un texto.
abstract class ImageEngine {
  /// 'local', 'openai' o 'a1111'.
  String get id;
  String get label;

  /// Los modelos de difusión clásicos entienden mal el español: conviene
  /// pasarles el texto en inglés.
  bool get prefersEnglish;

  /// null si está listo para generar; si no, qué le falta (para el usuario).
  String? get problem;

  /// Devuelve la imagen (PNG, JPEG o WebP).
  Future<Uint8List> generate(ImageRequest request);

  /// Corta la generación en curso.
  void cancel();
}

/// Generación local con stable-diffusion.cpp: se lanza `sd-cli` como proceso
/// aparte (así no comparte memoria con el modelo de lenguaje ni puede cerrar
/// la app si se queda sin memoria de vídeo).
class SdCppEngine implements ImageEngine {
  SdCppEngine({
    required this.exe,
    required this.model,
    this.vae = '',
    this.llm = '',
    this.steps = 20,
    this.cfg = 7.0,
    this.lowVram = true,
    required this.tmpDir,
    this.timeout = const Duration(minutes: 20),
  });

  final String exe;
  final String model;
  final String vae;
  final String llm;
  final int steps;
  final double cfg;
  final bool lowVram;
  final String tmpDir;
  final Duration timeout;
  Process? _process;
  bool _cancelled = false;

  @override
  String get id => 'local';
  @override
  String get label => 'Local (${p.basenameWithoutExtension(model)})';

  /// Los modelos en piezas (Z-Image, FLUX…) llevan un modelo de lenguaje
  /// como codificador de texto y entienden el español.
  bool get split => llm.isNotEmpty;
  @override
  bool get prefersEnglish => !split;

  @override
  String? get problem {
    if (exe.isEmpty || !File(exe).existsSync()) return 'Falta el programa generador (sd-cli)';
    if (model.isEmpty) return 'Elige o descarga un modelo de imágenes en Ajustes';
    for (final f in [model, vae, llm]) {
      if (f.isNotEmpty && !File(f).existsSync()) return 'No se encuentra ${p.basename(f)}';
    }
    return null;
  }

  /// Argumentos de `sd-cli` para una petición (aparte, para poder probarlos).
  List<String> arguments(ImageRequest r, String output) => [
        if (split) ...['--diffusion-model', model] else ...['-m', model],
        if (vae.isNotEmpty) ...['--vae', vae],
        if (llm.isNotEmpty) ...['--llm', llm],
        '-p', r.prompt,
        if (r.negative.isNotEmpty && cfg > 1.0) ...['-n', r.negative],
        '-W', '${r.width}',
        '-H', '${r.height}',
        '--steps', '$steps',
        '--cfg-scale', cfg.toStringAsFixed(1),
        '-s', '${r.seed}',
        if (lowVram) ...['--offload-to-cpu', '--vae-tiling'],
        '-o', output,
      ];

  @override
  Future<Uint8List> generate(ImageRequest request) async {
    final why = problem;
    if (why != null) throw ImageEngineException(why);
    Directory(tmpDir).createSync(recursive: true);
    final out = File(p.join(tmpDir, 'imagen_${DateTime.now().microsecondsSinceEpoch}.png'));
    _cancelled = false;
    final log = <String>[];
    void keep(String chunk) {
      for (final line in chunk.split(RegExp(r'[\r\n]+'))) {
        if (line.trim().isEmpty) continue;
        log.add(line.trim());
        if (log.length > 40) log.removeAt(0);
      }
    }

    final Process proc;
    try {
      proc = await Process.start(exe, arguments(request, out.path), workingDirectory: p.dirname(exe));
    } on ProcessException catch (e) {
      throw ImageEngineException('No se pudo arrancar el generador: ${e.message}');
    }
    _process = proc;
    const lenient = Utf8Decoder(allowMalformed: true);
    final outDone = proc.stdout.transform(lenient).listen(keep).asFuture<void>();
    final errDone = proc.stderr.transform(lenient).listen(keep).asFuture<void>();
    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      throw ImageEngineException('El generador lleva más de ${timeout.inMinutes} minutos: se ha detenido');
    } finally {
      _process = null;
    }
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    try {
      if (_cancelled) throw ImageEngineException('Generación cancelada');
      if (code != 0 || !out.existsSync() || out.lengthSync() == 0) {
        throw ImageEngineException(_explain(code, log));
      }
      return await out.readAsBytes();
    } finally {
      try {
        if (out.existsSync()) out.deleteSync();
      } catch (_) {}
    }
  }

  static String _explain(int code, List<String> log) {
    final text = log.join('\n').toLowerCase();
    if (text.contains('out of memory') || text.contains('failed to allocate') || text.contains('outofdevicememory')) {
      return 'El generador se ha quedado sin memoria. Activa «Ahorrar memoria de vídeo», usa imágenes normales '
          'en vez de grandes o cierra el modelo de lenguaje mientras generas.';
    }
    final errors = log.where((l) => l.contains('[ERROR]') || l.toLowerCase().contains('error')).toList();
    final tail = (errors.isEmpty ? log : errors).reversed.take(3).toList().reversed.join(' · ');
    return 'El generador ha fallado (código $code)${tail.isEmpty ? '' : ': $tail'}';
  }

  @override
  void cancel() {
    _cancelled = true;
    _process?.kill();
  }
}

/// Servicio con la API de imágenes de OpenAI (`POST /v1/images/generations`):
/// OpenAI y los muchos servicios y servidores propios compatibles con ella.
class OpenAiImageEngine implements ImageEngine {
  OpenAiImageEngine({required this.baseUrl, this.apiKey = '', this.model = '', this.client, this.timeout = const Duration(minutes: 5)});

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  /// Cliente HTTP (para pruebas); null = uno nuevo por petición.
  final http_pkg.Client? client;
  http_pkg.Client? _active;
  static http_pkg.Client _newClient() => http_pkg.Client();

  @override
  String get id => 'openai';
  @override
  String get label => 'Servicio (${Uri.tryParse(baseUrl)?.host ?? baseUrl})';
  @override
  bool get prefersEnglish => false;
  @override
  String? get problem => baseUrl.trim().isEmpty ? 'Escribe la dirección del servicio de imágenes en Ajustes' : null;

  /// Admite la raíz del servicio, `…/v1` o la dirección completa.
  static Uri endpoint(String base) {
    var b = base.trim().replaceAll(RegExp(r'/+$'), '');
    if (!b.contains('://')) b = 'https://$b';
    if (b.endsWith('/images/generations')) return Uri.parse(b);
    if (!RegExp(r'/v\d+$').hasMatch(b)) b = '$b/v1';
    return Uri.parse('$b/images/generations');
  }

  /// Las APIs sólo aceptan unos pocos tamaños: se elige el de la misma forma.
  static String sizeFor(int w, int h) => w == h ? '1024x1024' : (w > h ? '1536x1024' : '1024x1536');

  @override
  Future<Uint8List> generate(ImageRequest request) async {
    final why = problem;
    if (why != null) throw ImageEngineException(why);
    final http = client ?? _newClient();
    _active = http;
    try {
      final res = await http
          .post(
            endpoint(baseUrl),
            headers: {'Content-Type': 'application/json', if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
            body: jsonEncode({
              if (model.isNotEmpty) 'model': model,
              'prompt': request.prompt,
              'n': 1,
              'size': sizeFor(request.width, request.height),
            }),
          )
          .timeout(timeout);
      final body = _json(res);
      if (res.statusCode >= 400) throw ImageEngineException(_apiError(res.statusCode, body));
      final data = body['data'];
      final first = data is List && data.isNotEmpty && data.first is Map ? data.first as Map : const {};
      final b64 = first['b64_json'];
      if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
      final url = first['url'];
      if (url is String && url.isNotEmpty) {
        final img = await http.get(Uri.parse(url)).timeout(timeout);
        if (img.statusCode == 200) return img.bodyBytes;
      }
      throw ImageEngineException('El servicio no ha devuelto ninguna imagen');
    } on TimeoutException {
      throw ImageEngineException('El servicio de imágenes no responde');
    } on SocketException catch (e) {
      throw ImageEngineException('No se puede conectar con el servicio de imágenes (${e.message})');
    } on http_pkg.ClientException catch (e) {
      throw ImageEngineException('No se puede conectar con el servicio de imágenes (${e.message})');
    } finally {
      _active = null;
      if (client == null) http.close();
    }
  }

  @override
  void cancel() {
    if (client == null) _active?.close();
  }
}

/// Servidor con la API de Automatic1111 (`POST /sdapi/v1/txt2img`): también
/// Forge y SD.Next. Sirve para generar desde el móvil con el PC de casa.
class A1111Engine implements ImageEngine {
  A1111Engine({required this.baseUrl, this.steps = 20, this.cfg = 7.0, this.client, this.timeout = const Duration(minutes: 10)});

  final String baseUrl;
  final int steps;
  final double cfg;
  final Duration timeout;
  /// Cliente HTTP (para pruebas); null = uno nuevo por petición.
  final http_pkg.Client? client;
  http_pkg.Client? _active;
  static http_pkg.Client _newClient() => http_pkg.Client();

  @override
  String get id => 'a1111';
  @override
  String get label => 'Servidor Stable Diffusion (${Uri.tryParse(baseUrl)?.host ?? baseUrl})';
  @override
  bool get prefersEnglish => true;
  @override
  String? get problem => baseUrl.trim().isEmpty ? 'Escribe la dirección del servidor de imágenes en Ajustes' : null;

  static Uri endpoint(String base) {
    var b = base.trim().replaceAll(RegExp(r'/+$'), '');
    if (!b.contains('://')) b = 'http://$b';
    if (b.endsWith('/sdapi/v1/txt2img')) return Uri.parse(b);
    return Uri.parse('$b/sdapi/v1/txt2img');
  }

  @override
  Future<Uint8List> generate(ImageRequest request) async {
    final why = problem;
    if (why != null) throw ImageEngineException(why);
    final http = client ?? _newClient();
    _active = http;
    try {
      final res = await http
          .post(
            endpoint(baseUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'prompt': request.prompt,
              'negative_prompt': request.negative,
              'width': request.width,
              'height': request.height,
              'steps': steps,
              'cfg_scale': cfg,
              'seed': request.seed,
            }),
          )
          .timeout(timeout);
      final body = _json(res);
      if (res.statusCode >= 400) throw ImageEngineException(_apiError(res.statusCode, body));
      final images = body['images'];
      if (images is List && images.isNotEmpty && images.first is String) {
        final s = images.first as String;
        return base64Decode(s.contains(',') ? s.substring(s.indexOf(',') + 1) : s);
      }
      throw ImageEngineException('El servidor no ha devuelto ninguna imagen');
    } on TimeoutException {
      throw ImageEngineException('El servidor de imágenes no responde');
    } on SocketException catch (e) {
      throw ImageEngineException('No se puede conectar con el servidor de imágenes (${e.message})');
    } on http_pkg.ClientException catch (e) {
      throw ImageEngineException('No se puede conectar con el servidor de imágenes (${e.message})');
    } finally {
      _active = null;
      if (client == null) http.close();
    }
  }

  @override
  void cancel() {
    if (client == null) _active?.close();
  }
}

Map<String, dynamic> _json(http_pkg.Response res) {
  try {
    final v = jsonDecode(utf8.decode(res.bodyBytes));
    return v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

String _apiError(int status, Map<String, dynamic> body) {
  final err = body['error'];
  final detail = err is Map ? err['message'] : (err ?? body['detail'] ?? body['message']);
  final hint = switch (status) {
    401 || 403 => 'clave no válida o sin permiso',
    404 => 'dirección o modelo no encontrado',
    429 => 'límite de uso alcanzado',
    _ => 'error $status',
  };
  final d = detail == null ? '' : '$detail';
  return 'El servicio de imágenes ha respondido: $hint${d.isEmpty ? '' : ' ($d)'}';
}

/// ¿Parecen estos bytes una imagen que Flutter sabe mostrar?
String? imageExtension(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return '.png';
  if (b[0] == 0xFF && b[1] == 0xD8) return '.jpg';
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45) return '.webp';
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return '.gif';
  if (b[0] == 0x42 && b[1] == 0x4D) return '.bmp';
  return null;
}
