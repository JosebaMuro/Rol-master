/// Interpreta la respuesta del director de juego.
///
/// Convenciones que el director usa (ver prompts.dart):
///   * Diálogo de PNJ en una línea propia:  `@Nombre: texto que dice`
///   * Etiquetas de control (no se muestran):
///       [[musica: Combate]]
///       [[mapa: mazmorra | La cripta del rey]]
///       [[tirada: Percepción CD 15]]
///       [[acto: 2]]
///       [[lugar: Ruinas de Velmor]]
class NarrationSegment {
  const NarrationSegment.narration(this.text) : speaker = null;
  const NarrationSegment.dialogue(this.speaker, this.text);
  final String? speaker;
  final String text;
  bool get isDialogue => speaker != null;

  @override
  String toString() => isDialogue ? '@$speaker: $text' : text;
}

class MapRequest {
  const MapRequest(this.kind, this.title);
  final String kind;
  final String title;
}

class ParsedNarration {
  ParsedNarration({
    required this.cleanText,
    required this.segments,
    this.musicSuggestion,
    this.mapRequest,
    this.rolls = const [],
    this.act,
    this.location,
    this.scene,
  });
  final String cleanText;
  final List<NarrationSegment> segments;
  final String? musicSuggestion;
  final MapRequest? mapRequest;
  final List<String> rolls;
  final int? act;
  final String? location;
  /// Tipo de escena para el fondo (castillo, cueva…).
  final String? scene;

  Set<String> get speakers => {for (final s in segments) if (s.speaker != null) s.speaker!};
}

final _tagRe = RegExp(r'\[\[\s*([a-záéíóúñ]+)\s*:\s*([^\]]*?)\s*\]\]', caseSensitive: false);
final _dialogueRe = RegExp(r'^\s*[-*•]?\s*@\s*([^:\n]{1,40}?)\s*:\s*(.+)$');
final _boldDialogueRe = RegExp(r'^\s*\*\*([^*:\n]{1,40}?)\*\*\s*:\s*(.+)$');

ParsedNarration parseNarration(String raw) {
  String? music;
  MapRequest? map;
  int? act;
  String? location;
  String? scene;
  final rolls = <String>[];

  var text = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
  text = text.replaceAllMapped(_tagRe, (m) {
    final key = m.group(1)!.toLowerCase();
    final value = m.group(2)!.trim();
    switch (key) {
      case 'musica' || 'música' || 'music':
        music = value;
      case 'mapa' || 'map':
        final parts = value.split('|');
        map = MapRequest(
          parts.first.trim().toLowerCase(),
          parts.length > 1 ? parts.sublist(1).join('|').trim() : 'Mapa',
        );
      case 'tirada' || 'roll':
        rolls.add(value);
      case 'acto' || 'act':
        act = int.tryParse(RegExp(r'\d+').firstMatch(value)?.group(0) ?? '');
      case 'lugar' || 'location':
        location = value;
      case 'escena' || 'scene':
        scene = value;
    }
    return '';
  });

  final segments = <NarrationSegment>[];
  final narrationBuf = StringBuffer();
  void flush() {
    final t = narrationBuf.toString().trim();
    if (t.isNotEmpty) segments.add(NarrationSegment.narration(t));
    narrationBuf.clear();
  }

  final cleanLines = <String>[];
  for (final line in text.split('\n')) {
    final m = _dialogueRe.firstMatch(line) ?? _boldDialogueRe.firstMatch(line);
    if (m != null) {
      flush();
      final speaker = m.group(1)!.trim();
      var said = m.group(2)!.trim();
      said = _stripQuotes(said);
      segments.add(NarrationSegment.dialogue(speaker, said));
      cleanLines.add('**$speaker:** «$said»');
    } else {
      narrationBuf.writeln(line);
      cleanLines.add(line);
    }
  }
  flush();

  final clean = cleanLines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return ParsedNarration(
    cleanText: clean,
    segments: segments,
    musicSuggestion: music,
    mapRequest: map,
    rolls: rolls,
    act: act,
    location: location,
    scene: scene,
  );
}

String _stripQuotes(String s) {
  var t = s.trim();
  const pairs = {'"': '"', '«': '»', '“': '”', '—': ''};
  for (final e in pairs.entries) {
    if (t.startsWith(e.key)) {
      t = t.substring(e.key.length);
      if (e.value.isNotEmpty && t.endsWith(e.value)) t = t.substring(0, t.length - e.value.length);
      break;
    }
  }
  return t.trim();
}

/// Quita etiquetas [[...]] de un texto parcial mientras llega en streaming,
/// incluida una etiqueta a medio escribir al final.
String stripTagsForDisplay(String partial) {
  var t = partial.replaceAll(RegExp(r'<think>[\s\S]*?(</think>|$)'), '');
  t = t.replaceAll(_tagRe, '');
  final open = t.lastIndexOf('[[');
  if (open >= 0 && !t.substring(open).contains(']]')) t = t.substring(0, open);
  return t;
}
