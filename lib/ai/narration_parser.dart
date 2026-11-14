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
///   * Cambios de estado que aplica la app (la IA sólo los propone):
///       [[pv: Kael -4]]  [[objeto: Kael +Espada larga]]  [[oro: Mira +20]]
///       [[estado: Kael +envenenado]]  [[actitud: Bran +1]]
///       [[pendiente: promesa | Llevar el anillo al abad]]  [[resuelto: Llevar el anillo]]
///       [[tiempo: 3 días]]
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

/// Cambio de estado propuesto por el director con una etiqueta.
class StateChange {
  const StateChange(this.kind, this.target, this.value);

  /// 'pv', 'objeto', 'oro', 'estado' o 'actitud'.
  final String kind;
  final String target;

  /// "-4", "+Espada larga", "+envenenado"…
  final String value;

  /// Número con signo del valor (para pv, oro y actitud).
  int? get amount {
    final m = RegExp(r'([+\-−]?)\s*(\d+)').firstMatch(value);
    if (m == null) return null;
    final n = int.parse(m.group(2)!);
    return (m.group(1) == '-' || m.group(1) == '−') ? -n : n;
  }

  /// true si añade (+), false si quita (−).
  bool get adds => !(value.trimLeft().startsWith('-') || value.trimLeft().startsWith('−'));

  /// El valor sin el signo inicial ("Espada larga").
  String get bare => value.trim().replaceFirst(RegExp(r'^[+\-−]\s*'), '').trim();

  @override
  String toString() => '$kind: $target $value';

  /// "Kael -4", "Kael | +Espada", "Kael: +envenenado".
  static StateChange? parse(String kind, String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final sep = RegExp(r'\s*[|:]\s*').firstMatch(t);
    if (sep != null) {
      final target = t.substring(0, sep.start).trim();
      final value = t.substring(sep.end).trim();
      if (target.isNotEmpty && value.isNotEmpty) return StateChange(kind, target, value);
    }
    final sign = RegExp(r'\s[+\-−]').firstMatch(t);
    if (sign != null) {
      return StateChange(kind, t.substring(0, sign.start).trim(), t.substring(sign.start).trim());
    }
    final num = RegExp(r'\s(\d+)\s*$').firstMatch(t);
    if (num != null) return StateChange(kind, t.substring(0, num.start).trim(), num.group(1)!);
    return null;
  }
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
    this.changes = const [],
    this.threadsOpened = const [],
    this.threadsClosed = const [],
    this.timeSkip,
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
  final List<StateChange> changes;
  /// (tipo, texto) de asuntos nuevos: promesas, deudas, amenazas…
  final List<(String, String)> threadsOpened;
  final List<String> threadsClosed;
  /// Salto de tiempo anunciado ("3 días").
  final String? timeSkip;

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
  String? timeSkip;
  final rolls = <String>[];
  final changes = <StateChange>[];
  final opened = <(String, String)>[];
  final closed = <String>[];

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
      case 'pv' || 'hp' || 'vida':
        final c = StateChange.parse('pv', value);
        if (c != null) changes.add(c);
      case 'daño' || 'dano':
        final c = StateChange.parse('pv', value);
        if (c != null) changes.add(StateChange('pv', c.target, '-${c.bare}'));
      case 'cura' || 'curacion' || 'curación':
        final c = StateChange.parse('pv', value);
        if (c != null) changes.add(StateChange('pv', c.target, '+${c.bare}'));
      case 'objeto' || 'item' || 'inventario':
        final c = StateChange.parse('objeto', value);
        if (c != null) changes.add(c);
      case 'oro' || 'dinero' || 'monedas':
        final c = StateChange.parse('oro', value);
        if (c != null) changes.add(c);
      case 'estado' || 'condicion' || 'condición':
        final c = StateChange.parse('estado', value);
        if (c != null) changes.add(c);
      case 'actitud':
        final c = StateChange.parse('actitud', value);
        if (c != null) changes.add(c);
      case 'pendiente' || 'promesa' || 'deuda' || 'amenaza' || 'mision' || 'misión' || 'pista':
        final parts = value.split('|');
        if (parts.length > 1) {
          opened.add((parts.first.trim().toLowerCase(), parts.sublist(1).join('|').trim()));
        } else if (value.isNotEmpty) {
          opened.add((key == 'pendiente' ? 'pendiente' : key.replaceAll('mision', 'misión'), value));
        }
      case 'resuelto' || 'cumplido' || 'cerrado':
        if (value.isNotEmpty) closed.add(value);
      case 'tiempo' || 'salto':
        timeSkip = value;
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
    changes: changes,
    threadsOpened: opened,
    threadsClosed: closed,
    timeSkip: timeSkip,
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
