import 'dart:convert';

/// Mensaje genérico para el modelo de lenguaje.
enum LlmRole { system, user, assistant }

class LlmMessage {
  const LlmMessage(this.role, this.text);
  const LlmMessage.system(this.text) : role = LlmRole.system;
  const LlmMessage.user(this.text) : role = LlmRole.user;
  const LlmMessage.assistant(this.text) : role = LlmRole.assistant;
  final LlmRole role;
  final String text;
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
