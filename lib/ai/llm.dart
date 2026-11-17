import 'dart:convert';

/// Mensaje genérico para el modelo de lenguaje.
enum LlmRole { system, user, assistant }

class LlmMessage {
  const LlmMessage(this.role, this.text, {this.images = const []});
  const LlmMessage.system(this.text)
      : role = LlmRole.system,
        images = const [];
  const LlmMessage.user(this.text, {this.images = const []}) : role = LlmRole.user;
  const LlmMessage.assistant(this.text)
      : role = LlmRole.assistant,
        images = const [];
  final LlmRole role;
  final String text;

  /// Rutas locales de imágenes que acompañan al mensaje. Sólo las usan los
  /// modelos con visión (ver [TextGenerator.canSee]); el resto las ignora.
  final List<String> images;

  LlmMessage withImages(List<String> images) => LlmMessage(role, text, images: images);
}

/// Fragmento de una respuesta en streaming: texto visible y razonamiento.
class LlmChunk {
  const LlmChunk({this.text = '', this.thinking = ''});
  final String text;
  final String thinking;
}

/// Abstracción del motor de IA. La implementación real usa llama.cpp
/// (ver llama_service.dart); los tests usan una implementación falsa.
abstract class TextGenerator {
  bool get isReady;

  /// Indica si hay un modelo de embeddings cargado para el RAG semántico.
  bool get canEmbed;

  /// Indica si el modelo cargado ve imágenes (tiene proyector de visión).
  bool get canSee;

  Stream<LlmChunk> chat(
    List<LlmMessage> messages, {
    double temperature = 0.8,
    int maxTokens = 1024,
    bool thinking = false,
    int? thinkingBudget,
  });

  /// Genera un objeto JSON que cumple [schema] (gramática restringida cuando
  /// el motor lo soporta).
  Future<Map<String, dynamic>> json(
    List<LlmMessage> messages, {
    required Map<String, dynamic> schema,
    int maxTokens = 1024,
    double temperature = 0.4,
  });

  Future<List<double>?> embed(String text, {bool query = false});

  void cancel();
}

/// Instrucción para que un modelo sin modo de razonamiento propio (Gemma 3,
/// por ejemplo) piense antes de narrar. El bloque se separa de la narración
/// con [ThinkSplitter], igual que el razonamiento nativo de Qwen3.
String guidedThinkingInstruction(int budgetTokens) {
  final words = (budgetTokens * 0.6).round().clamp(60, 1200);
  return 'RAZONAMIENTO PREVIO: antes de responder, piensa paso a paso dentro de un único bloque '
      '<think>…</think> (máximo $words palabras, en notas breves): qué intentan los personajes, qué reglas, '
      'tiradas y consecuencias aplican, qué saben y quieren los PNJ presentes, y cómo encaja con la trama y con '
      'lo ya ocurrido. Cierra siempre el bloque con </think> y escribe después tu respuesta normal. '
      'Nada de lo que pongas dentro del bloque lo verán los jugadores.';
}

/// Añade la instrucción de razonamiento guiado al mensaje de sistema.
List<LlmMessage> withGuidedThinking(List<LlmMessage> messages, int budgetTokens) {
  final rule = guidedThinkingInstruction(budgetTokens);
  if (messages.isNotEmpty && messages.first.role == LlmRole.system) {
    return [LlmMessage.system('${messages.first.text}\n\n$rule'), ...messages.skip(1)];
  }
  return [LlmMessage.system(rule), ...messages];
}

/// Separa en streaming el razonamiento escrito entre `<think>` y `</think>`
/// del texto visible, aunque las etiquetas lleguen partidas entre fragmentos.
class ThinkSplitter {
  static const _open = '<think>';
  static const _close = '</think>';

  String _pending = '';
  bool _inside = false;

  /// Hay un bloque de razonamiento abierto y sin cerrar.
  bool get inside => _inside;

  LlmChunk add(String piece) {
    _pending += piece;
    final text = StringBuffer();
    final thinking = StringBuffer();
    while (true) {
      final tag = _inside ? _close : _open;
      final out = _inside ? thinking : text;
      final i = _pending.indexOf(tag);
      if (i >= 0) {
        out.write(_pending.substring(0, i));
        _pending = _pending.substring(i + tag.length);
        _inside = !_inside;
        continue;
      }
      // Retiene el final si puede ser el principio de una etiqueta.
      var keep = 0;
      for (var n = tag.length - 1; n > 0; n--) {
        if (_pending.endsWith(tag.substring(0, n))) {
          keep = n;
          break;
        }
      }
      out.write(_pending.substring(0, _pending.length - keep));
      _pending = _pending.substring(_pending.length - keep);
      break;
    }
    return LlmChunk(text: text.toString(), thinking: thinking.toString());
  }

  /// Lo que quedaba retenido al terminar la generación.
  LlmChunk close() {
    final rest = _pending;
    _pending = '';
    return _inside ? LlmChunk(thinking: rest) : LlmChunk(text: rest);
  }
}

/// Extrae el primer objeto JSON de un texto libre (por si el modelo añade
/// texto alrededor). Devuelve un mapa vacío si no lo encuentra.
Map<String, dynamic> extractJsonObject(String text) {
  var t = text.trim();
  // Quita bloques de razonamiento y vallas de código.
  t = t.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
  t = t.replaceAll(RegExp(r'```(?:json)?'), '');
  final start = t.indexOf('{');
  if (start < 0) return {};
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < t.length; i++) {
    final c = t[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        try {
          final v = jsonDecode(t.substring(start, i + 1));
          if (v is Map) return v.cast<String, dynamic>();
        } catch (_) {
          return {};
        }
      }
    }
  }
  return {};
}

/// Estimación barata de tokens (≈ 3,5 caracteres por token en español).
int estimateTokens(String s) => (s.length / 3.5).ceil();
