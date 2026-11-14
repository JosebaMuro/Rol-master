import '../core/db.dart';
import '../core/models.dart';
import 'dice.dart';

/// El mundo avanza solo: cada pocos turnos (o con un salto de tiempo) los
/// relojes de las facciones y del villano tiran dados y pueden avanzar.
/// Cuando uno se llena, su consecuencia ocurre y el director debe mostrarla.
class WorldEngine {
  WorldEngine(this.db, {Dice? dice}) : dice = dice ?? Dice();
  final AppDatabase db;
  final Dice dice;

  static const eventsKey = '_eventosMundo';
  static const seededKey = '_relojes';
  static const turnKey = '_turnos';

  /// Crea los relojes iniciales a partir de la biblia (villano y facciones).
  /// Sólo una vez por campaña: si el grupo los borra, no vuelven.
  List<WorldClock> seed(Campaign c) {
    if (c.bible[seededKey] == true) return db.clocks(c.id!);
    final out = <WorldClock>[];
    final villain = c.bible['villain'];
    if (villain is Map && '${villain['name'] ?? ''}'.trim().isNotEmpty) {
      final name = '${villain['name']}'.trim();
      final plan = '${villain['plan'] ?? ''}'.trim();
      out.add(db.saveClock(WorldClock(
        campaignId: c.id!,
        name: plan.isEmpty ? 'El plan de $name' : plan,
        owner: name,
        segments: 8,
        consequence: '$name completa su plan${plan.isEmpty ? '' : ': $plan'}.',
      )));
    }
    for (final f in (c.bible['factions'] as List? ?? const []).whereType<Map>()) {
      final name = '${f['name'] ?? ''}'.trim();
      final goal = '${f['goal'] ?? ''}'.trim();
      if (name.isEmpty || goal.isEmpty) continue;
      out.add(db.saveClock(WorldClock(
        campaignId: c.id!,
        name: goal,
        owner: name,
        segments: 6,
        consequence: '$name consigue su objetivo: $goal.',
      )));
    }
    c.bible[seededKey] = true;
    db.updateCampaign(c);
    return out;
  }

  /// Cuenta un turno de juego. Cada [every] turnos el mundo avanza un paso.
  /// Devuelve las notas de lo que ha cambiado (vacío si nada).
  List<String> onTurn(Campaign c, {int every = 4}) {
    final n = ((c.bible[turnKey] as num?)?.toInt() ?? 0) + 1;
    c.bible[turnKey] = n;
    db.updateCampaign(c);
    if (every <= 0 || n % every != 0) return const [];
    return tick(c, steps: 1);
  }

  /// Avanza el mundo [steps] pasos. Los relojes que nadie frena avanzan más.
  List<String> tick(Campaign c, {int steps = 1}) {
    final notes = <String>[];
    for (final clock in db.clocks(c.id!, onlyActive: true)) {
      var advanced = 0;
      for (var i = 0; i < steps && !clock.full; i++) {
        final bonus = switch (clock.stance) {
          'se oponen' => -1,
          'ayudan' => 1,
          'huyen' || 'ignoran' => 1,
          _ => 0,
        };
        if (dice.die(6) + bonus >= 5) {
          clock.filled++;
          advanced++;
        }
      }
      if (advanced == 0) continue;
      if (clock.full) {
        clock.active = false;
        _queueEvent(c, clock.consequence.isEmpty ? '${clock.owner}: ${clock.name} se ha cumplido.' : clock.consequence);
        notes.add('⏳ ${clock.owner.isEmpty ? clock.name : clock.owner}: ¡se ha cumplido! ${clock.consequence}');
      } else {
        notes.add('⏳ ${clock.owner.isEmpty ? clock.name : '${clock.owner} (${clock.name})'} avanza: ${clock.filled}/${clock.segments}');
      }
      db.saveClock(clock);
    }
    return notes;
  }

  /// Salto de tiempo ("tres semanas después"): el mundo avanza en proporción.
  List<String> timeSkip(Campaign c, int days) {
    final steps = days <= 1 ? 1 : (days <= 7 ? 2 : (days <= 30 ? 4 : 6));
    final notes = tick(c, steps: steps);
    _queueEvent(c, 'Han pasado ${describeDays(days)}. Describe cómo ha cambiado el mundo y qué hicieron los PNJ mientras tanto.');
    return notes;
  }

  void _queueEvent(Campaign c, String text) {
    final list = pendingEvents(c)..add(text);
    c.bible[eventsKey] = list;
    db.updateCampaign(c);
  }

  /// Acontecimientos que el director aún no ha narrado.
  static List<String> pendingEvents(Campaign c) =>
      ((c.bible[eventsKey] as List?) ?? const []).map((e) => e.toString()).toList();

  /// Una vez el director los ha recibido en un turno, se dan por narrados.
  void clearEvents(Campaign c) {
    if (c.bible.remove(eventsKey) != null) db.updateCampaign(c);
  }

  static const _numbers = {
    'un': 1, 'una': 1, 'uno': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6, 'siete': 7, 'ocho': 8,
    'nueve': 9, 'diez': 10, 'quince': 15, 'veinte': 20, 'unos': 2, 'unas': 2, 'varios': 3, 'varias': 3,
  };

  /// "3 días", "dos semanas", "un mes", "medio año" → días.
  static int? parseDays(String text) {
    final t = AppDatabase.normalize(text);
    final m = RegExp(r'(\d+|[a-z]+)?\s*(hora|dia|jornada|noche|semana|mes|estacion|ano)').firstMatch(t);
    if (m == null) return null;
    final q = m.group(1);
    var n = q == null ? 1 : (int.tryParse(q) ?? _numbers[q] ?? 1);
    if (q == 'medio' || q == 'media') n = 0;
    final unit = switch (m.group(2)) {
      'hora' => 0,
      'semana' => 7,
      'mes' => 30,
      'estacion' => 90,
      'ano' => 365,
      _ => 1,
    };
    if (q == 'medio' || q == 'media') return (unit / 2).round().clamp(1, 1 << 20);
    return (n * unit).clamp(unit == 0 ? 0 : 1, 1 << 20);
  }

  static String describeDays(int d) {
    if (d <= 0) return 'unas horas';
    if (d == 1) return 'un día';
    if (d == 7) return 'una semana';
    if (d == 30) return 'un mes';
    if (d == 365) return 'un año';
    if (d < 7) return '$d días';
    if (d < 30) return d % 7 == 0 ? '${d ~/ 7} semanas' : '$d días';
    if (d < 365) return d % 30 == 0 ? '${d ~/ 30} meses' : '$d días';
    return d % 365 == 0 ? '${d ~/ 365} años' : '$d días';
  }
}
