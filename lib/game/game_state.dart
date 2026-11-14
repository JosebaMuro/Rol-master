import '../ai/narration_parser.dart';
import '../core/db.dart';
import '../core/models.dart';

/// Aplica a las fichas los cambios que propone el director. La IA narra; la
/// app lleva la cuenta de PV, objetos, oro, estados y actitudes de los PNJ.
class GameState {
  GameState(this.db);
  final AppDatabase db;

  /// Crea la ficha de cada personaje jugador que aún no la tenga.
  List<CharacterState> ensureCharacters(int campaignId) {
    final existing = db.charStates(campaignId);
    final names = {for (final c in existing) AppDatabase.normalize(c.name)};
    for (final p in db.campaignPlayers(campaignId)) {
      final name = p.characterName.isEmpty ? p.playerName : p.characterName;
      if (names.add(AppDatabase.normalize(name))) {
        existing.add(db.saveCharState(CharacterState(campaignId: campaignId, name: name, player: p.playerName)));
      }
    }
    return existing;
  }

  /// Busca la ficha por nombre del personaje, del jugador o por una palabra
  /// del nombre ("Kael" para "Kael el Rojo").
  CharacterState? find(int campaignId, String who) {
    final n = AppDatabase.normalize(who);
    if (n.isEmpty) return null;
    final all = ensureCharacters(campaignId);
    for (final c in all) {
      if (AppDatabase.normalize(c.name) == n || AppDatabase.normalize(c.player) == n) return c;
    }
    for (final c in all) {
      final words = AppDatabase.normalize(c.name).split(' ').where((w) => w.length > 2);
      if (words.any((w) => n.split(' ').contains(w))) return c;
    }
    return null;
  }

  /// Aplica los cambios y devuelve una línea legible por cada uno aplicado
  /// (para mostrarla en la mesa y guardarla en el registro).
  List<String> apply(int campaignId, List<StateChange> changes, {int messageId = 0}) {
    final notes = <String>[];
    for (final ch in changes) {
      final note = switch (ch.kind) {
        'actitud' => _attitude(campaignId, ch, messageId),
        _ => _character(campaignId, ch),
      };
      if (note != null) notes.add(note);
    }
    return notes;
  }

  String? _character(int campaignId, StateChange ch) {
    final c = find(campaignId, ch.target);
    if (c == null) return null;
    String? note;
    switch (ch.kind) {
      case 'pv':
        final n = ch.amount;
        if (n == null) return null;
        final before = c.hp;
        c.hp = (c.hp + n).clamp(-c.maxHp, c.maxHp);
        note = '${c.name}: PV $before → ${c.hp}/${c.maxHp}${c.down ? ' (fuera de combate)' : ''}';
      case 'oro':
        final n = ch.amount;
        if (n == null) return null;
        c.gold = (c.gold + n).clamp(0, 1 << 30);
        note = '${c.name}: oro ${n >= 0 ? '+' : ''}$n (tiene ${c.gold})';
      case 'objeto':
        var name = ch.bare;
        if (name.isEmpty) return null;
        var qty = 1;
        final q = RegExp(r'\s*[x×]\s*(\d+)$').firstMatch(name) ?? RegExp(r'^(\d+)\s+').firstMatch(name);
        if (q != null) {
          qty = int.parse(q.group(1)!);
          name = name.replaceFirst(q.group(0)!, '').trim();
        }
        final norm = AppDatabase.normalize(name);
        final item = c.inventory.where((i) => AppDatabase.normalize(i.name) == norm).firstOrNull;
        if (ch.adds) {
          if (item != null) {
            item.qty += qty;
          } else {
            c.inventory.add(InventoryItem(name, qty));
          }
          note = '${c.name} obtiene: $name${qty > 1 ? ' x$qty' : ''}';
        } else {
          if (item == null) return null;
          item.qty -= qty;
          if (item.qty <= 0) c.inventory.remove(item);
          note = '${c.name} pierde: ${item.name}${qty > 1 ? ' x$qty' : ''}';
        }
      case 'estado':
        final cond = ch.bare.toLowerCase();
        if (cond.isEmpty) return null;
        if (ch.adds) {
          if (c.conditions.contains(cond)) return null;
          c.conditions.add(cond);
          note = '${c.name} queda $cond';
        } else {
          if (!c.conditions.remove(cond)) return null;
          note = '${c.name} ya no está $cond';
        }
      default:
        return null;
    }
    db.saveCharState(c);
    return note;
  }

  String? _attitude(int campaignId, StateChange ch, int messageId) {
    final npc = db.npcByName(campaignId, ch.target) ??
        db.npcs(campaignId).where((n) => AppDatabase.normalize(n.name).contains(AppDatabase.normalize(ch.target))).firstOrNull;
    final n = ch.amount;
    if (npc == null || n == null) return null;
    final before = npc.attitude;
    npc.attitude = (npc.attitude + n).clamp(-3, 3);
    if (npc.attitude == before) return null;
    db.updateNpcState(npc);
    return '${npc.name} ahora es ${npc.attitudeName} con el grupo';
  }
}
