import 'dart:math';

/// Resultado de tirar una expresión de dados ("2d6+3", "d20").
class DiceResult {
  DiceResult(this.expression, this.rolls, this.modifier, {this.sides = 0});
  final String expression;
  final List<int> rolls;
  final int modifier;
  final int sides;
  int get total => rolls.fold(0, (a, b) => a + b) + modifier;

  /// Sólo tiene sentido en tiradas de un d20.
  bool get natural20 => sides == 20 && rolls.length == 1 && rolls.first == 20;
  bool get natural1 => sides == 20 && rolls.length == 1 && rolls.first == 1;

  @override
  String toString() {
    final dice = rolls.length == 1 ? '${rolls.first}' : rolls.join('+');
    final mod = modifier == 0 ? '' : (modifier > 0 ? ' +$modifier' : ' −${-modifier}');
    return '$expression → $dice$mod = $total';
  }
}

/// Lanza dados con un generador que se puede fijar para las pruebas.
class Dice {
  Dice([Random? random]) : _r = random ?? Random();
  final Random _r;

  int die(int sides) => 1 + _r.nextInt(max(1, sides));

  static final _exprRe = RegExp(r'^\s*(\d*)\s*d\s*(\d+)\s*(([+-−])\s*(\d+))?\s*$', caseSensitive: false);

  /// Acepta "d20", "2d6+3", "1d8 - 1". Devuelve null si no es una expresión.
  DiceResult? roll(String expression) {
    final m = _exprRe.firstMatch(expression);
    if (m == null) return null;
    final n = (int.tryParse(m.group(1) ?? '') ?? 1).clamp(1, 100);
    final sides = (int.tryParse(m.group(2)!) ?? 20).clamp(2, 1000);
    var mod = int.tryParse(m.group(5) ?? '') ?? 0;
    if (m.group(4) == '-' || m.group(4) == '−') mod = -mod;
    return DiceResult(expression.replaceAll(' ', ''), [for (var i = 0; i < n; i++) die(sides)], mod, sides: sides);
  }
}

/// Grado de éxito de una tirada contra una dificultad.
enum RollTier { pifia, fallo, exitoParcial, exito, critico }

extension RollTierName on RollTier {
  String get label => switch (this) {
        RollTier.pifia => 'PIFIA',
        RollTier.fallo => 'fallo',
        RollTier.exitoParcial => 'éxito por los pelos',
        RollTier.exito => 'éxito',
        RollTier.critico => '¡CRÍTICO!',
      };
}

/// Tirada que pide el director: `[[tirada: Kael | Percepción CD 15]]`.
class RollRequest {
  const RollRequest({required this.raw, this.who = '', required this.skill, this.dc});
  final String raw;
  /// Personaje que tira ('' = el que esté hablando).
  final String who;
  final String skill;
  final int? dc;

  static final _dcRe = RegExp(r'\b(?:CD|DC|dificultad)\s*:?\s*(\d+)', caseSensitive: false);

  factory RollRequest.parse(String raw) {
    var text = raw.trim();
    var who = '';
    final bar = text.indexOf('|');
    if (bar >= 0) {
      who = text.substring(0, bar).trim();
      text = text.substring(bar + 1).trim();
    }
    final dcMatch = _dcRe.firstMatch(text);
    final dc = dcMatch == null ? null : int.tryParse(dcMatch.group(1)!);
    var skill = text.replaceAll(_dcRe, '').replaceAll(RegExp(r'[\(\),;]+'), ' ').trim();
    skill = skill.replaceAll(RegExp(r'\s+'), ' ');
    if (skill.isEmpty) skill = 'Tirada';
    return RollRequest(raw: raw, who: who, skill: skill, dc: dc);
  }

  @override
  String toString() => '${who.isEmpty ? '' : '$who · '}$skill${dc == null ? '' : ' CD $dc'}';
}

/// Una tirada de habilidad ya resuelta por la app (no por la IA).
class SkillCheck {
  SkillCheck({required this.request, required this.who, required this.die, required this.modifier});
  final RollRequest request;
  final String who;
  final int die;
  final int modifier;

  int get total => die + modifier;

  RollTier get tier {
    if (die == 20) return RollTier.critico;
    if (die == 1) return RollTier.pifia;
    final dc = request.dc;
    if (dc == null) return total >= 15 ? RollTier.exito : (total >= 10 ? RollTier.exitoParcial : RollTier.fallo);
    if (total >= dc + 5) return RollTier.exito;
    if (total >= dc) return total == dc ? RollTier.exitoParcial : RollTier.exito;
    return RollTier.fallo;
  }

  bool get success => tier == RollTier.exito || tier == RollTier.exitoParcial || tier == RollTier.critico;

  /// Texto que se envía al director como acción del jugador.
  String describe() {
    final mod = modifier == 0 ? '' : (modifier > 0 ? ' +$modifier' : ' −${-modifier}');
    final vs = request.dc == null ? '' : ' contra CD ${request.dc}';
    return '🎲 $who tira ${request.skill}: d20 ($die)$mod = $total$vs → ${tier.label}';
  }

  static SkillCheck roll(RollRequest r, {required String who, int modifier = 0, Dice? dice}) =>
      SkillCheck(request: r, who: who, die: (dice ?? Dice()).die(20), modifier: modifier);
}
