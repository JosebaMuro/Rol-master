import 'package:director_de_rol/ai/llm.dart';
import 'package:director_de_rol/core/models.dart';

/// Motor de IA falso para pruebas: devuelve respuestas guionizadas.
class FakeLlm implements TextGenerator {
  FakeLlm({this.replies = const [], this.jsonReplies = const [], this.embeddings = false, this.sees = false});

  final bool sees;

  final List<String> replies;
  final List<Map<String, dynamic>> jsonReplies;
  final bool embeddings;
  int _r = 0, _j = 0;
  final List<List<LlmMessage>> chatCalls = [];
  final List<List<LlmMessage>> jsonCalls = [];
  final List<String> queryEmbeds = [];

  @override
  bool get isReady => true;

  @override
  bool get canEmbed => embeddings;

  @override
  bool get canSee => sees;

  @override
  Stream<LlmChunk> chat(List<LlmMessage> messages,
      {double temperature = 0.8, int maxTokens = 1024, bool thinking = false, int? thinkingBudget}) async* {
    chatCalls.add(messages);
    final text = replies.isEmpty ? 'Respuesta.' : replies[_r++ % replies.length];
    if (thinking) yield const LlmChunk(thinking: 'Pienso en la escena.');
    for (final word in text.split(' ')) {
      yield LlmChunk(text: '$word ');
    }
  }

  @override
  Future<Map<String, dynamic>> json(List<LlmMessage> messages,
      {required Map<String, dynamic> schema, int maxTokens = 1024, double temperature = 0.4}) async {
    jsonCalls.add(messages);
    if (jsonReplies.isEmpty) return {'entities': [], 'relations': []};
    return jsonReplies[_j++ % jsonReplies.length];
  }

  /// Embedding de juguete: bolsa de letras normalizada.
  @override
  Future<List<double>?> embed(String text, {bool query = false}) async {
    if (!embeddings) return null;
    if (query) queryEmbeds.add(text);
    final v = List<double>.filled(26, 0);
    for (final c in text.toLowerCase().codeUnits) {
      if (c >= 97 && c <= 122) v[c - 97] += 1;
    }
    return v;
  }

  @override
  void cancel() {}
}

VoiceProfile fakeVoice(int campaignId, String name, String hint) =>
    VoiceProfile(pitch: hint.contains('mujer') ? 1.3 : 0.9, systemVoice: 'voz-$name');

const sampleBible = <String, dynamic>{
  'title': 'La Corona de Ceniza',
  'setting': 'El reino de Velmor, tras la Guerra del Eclipse.',
  'premise': 'Alguien está resucitando a los reyes muertos.',
  'hook': 'Un mensajero muere en la taberna con un anillo negro.',
  'villain': {'name': 'Lady Morwen', 'motivation': 'Recuperar a su hijo', 'plan': 'Reunir las tres coronas'},
  'acts': [
    {'title': 'El anillo', 'summary': 'Investigar la muerte', 'goal': 'Llegar a la cripta', 'twist': 'El mensajero vive'},
    {'title': 'La cripta', 'summary': 'Explorar la cripta', 'goal': 'Recuperar la corona', 'twist': 'Morwen es la reina'},
  ],
  'npcs': [
    {
      'name': 'Bran el tabernero',
      'role': 'Tabernero',
      'personality': 'Desconfiado',
      'secret': 'Es espía',
      'gender': 'hombre',
      'age': 'adulto',
      'voice': 'grave',
    },
    {
      'name': 'Sor Elia',
      'role': 'Monja',
      'personality': 'Amable',
      'secret': 'Sirve a Morwen',
      'gender': 'mujer',
      'age': 'anciana',
      'voice': 'suave',
    },
  ],
  'locations': [
    {'name': 'Taberna del Cuervo', 'description': 'Humo y secretos.'},
    {'name': 'Cripta de los Reyes', 'description': 'Bajo la abadía.'},
  ],
  'factions': [
    {'name': 'Orden del Alba', 'goal': 'Detener a Lady Morwen'},
  ],
  'secrets': ['Morwen es la reina muerta'],
  'clues': ['El anillo tiene el sello real'],
  'endings': ['Morwen redimida', 'Velmor en ruinas'],
  'opening': 'La lluvia golpea los cristales de la Taberna del Cuervo.\n@Bran el tabernero: Cerramos pronto, forasteros.',
};
