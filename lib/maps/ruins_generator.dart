import 'dart:math';

import 'dungeon_generator.dart';

/// Ruinas y laberintos con «Wave Function Collapse» (modelo de teselas
/// simple, la idea de github.com/mxgmn/WaveFunctionCollapse).
///
/// El mapa se divide en celdas grandes. Cada celda puede ser vacía, pasillo o
/// sala, con aberturas hacia sus cuatro vecinas. Las aberturas tienen que
/// encajar con las de la vecina, y los bordes del mapa van cerrados. Se va
/// fijando la celda con menos opciones (menor entropía), se propagan las
/// restricciones y al final se queda la zona conectada más grande.
class RuinsGenerator {
  static const cellSize = 7;

  // Bits de abertura: norte, este, sur, oeste.
  static const _n = 1, _e = 2, _s = 4, _w = 8;
  static const _dirs = [(_n, 0, -1, _s), (_e, 1, 0, _w), (_s, 0, 1, _n), (_w, -1, 0, _e)];

  /// Teselas posibles: (aberturas, tipo) con 0 = vacía, 1 = pasillo, 2 = sala.
  static final List<(int, int)> _tiles = [
    (0, 0),
    for (var mask = 1; mask < 16; mask++) (mask, 1),
    for (var mask = 1; mask < 16; mask++) (mask, 2),
  ];

  static int _bits(int m) => (m & 1) + (m >> 1 & 1) + (m >> 2 & 1) + (m >> 3 & 1);

  static double _weight((int, int) t) {
    final (mask, kind) = t;
    final b = _bits(mask);
    if (kind == 0) return 2.2;
    if (kind == 1) {
      if (b == 1) return 0.25;
      if (b == 2) return (mask == (_n | _s) || mask == (_e | _w)) ? 1.3 : 1.0;
      return b == 3 ? 0.55 : 0.3;
    }
    return switch (b) { 1 => 0.75, 2 => 0.6, 3 => 0.4, _ => 0.2 };
  }

  static DungeonMap generate(int seed, int w, int h) {
    for (var attempt = 0; attempt < 12; attempt++) {
      final m = _try(seed + attempt * 7919, seed, w, h);
      if (m != null) return m;
    }
    // Muy improbable: se recurre a la mazmorra clásica.
    return DungeonGenerator.generate(kind: 'mazmorra', seed: seed, width: w, height: h);
  }

  static DungeonMap? _try(int s, int seed, int w, int h) {
    final r = Random(s);
    final cols = (w - 4) ~/ cellSize, rows = (h - 4) ~/ cellSize;
    if (cols < 2 || rows < 2) return null;
    final grid = _collapse(r, cols, rows);
    if (grid == null) return null;

    // Zona conectada más grande (por aberturas).
    final comp = List.filled(cols * rows, -1);
    var best = -1, bestSize = 0, id = 0;
    for (var i = 0; i < cols * rows; i++) {
      if (grid[i].$2 == 0 || comp[i] >= 0) continue;
      var size = 0;
      final stack = [i];
      comp[i] = id;
      while (stack.isNotEmpty) {
        final c = stack.removeLast();
        size++;
        final cx = c % cols, cy = c ~/ cols;
        for (final (bit, dx, dy, _) in _dirs) {
          if (grid[c].$1 & bit == 0) continue;
          final nx = cx + dx, ny = cy + dy;
          final ni = ny * cols + nx;
          if (comp[ni] < 0) {
            comp[ni] = id;
            stack.add(ni);
          }
        }
      }
      if (size > bestSize) {
        bestSize = size;
        best = id;
      }
      id++;
    }
    final roomsInBest = [for (var i = 0; i < cols * rows; i++) if (comp[i] == best && grid[i].$2 == 2) i];
    if (bestSize < cols * rows ~/ 3 || roomsInBest.length < 5) return null;

    final m = DungeonMap(w, h, 'ruinas', seed);
    final roomOfCell = <int, int>{};
    for (var i = 0; i < cols * rows; i++) {
      if (comp[i] != best) continue;
      final (mask, kind) = grid[i];
      final x0 = 2 + (i % cols) * cellSize, y0 = 2 + (i ~/ cols) * cellSize;
      final c = cellSize ~/ 2;
      // Pasillos desde el centro hacia cada abertura.
      for (final (bit, dx, dy, _) in _dirs) {
        if (mask & bit == 0) continue;
        for (var k = 0; k <= c; k++) {
          final x = x0 + c + dx * k, y = y0 + c + dy * k;
          if (m.at(x, y) == Tile.wall) m.set(x, y, Tile.corridor);
        }
      }
      if (kind == 2) {
        final rw = 3 + r.nextInt(3), rh = 3 + r.nextInt(3);
        final room = Room(x0 + c - rw ~/ 2, y0 + c - rh ~/ 2, rw, rh, 0);
        for (var y = room.y; y < room.y + room.h; y++) {
          for (var x = room.x; x < room.x + room.w; x++) {
            m.set(x, y, Tile.floor);
          }
        }
        roomOfCell[i] = m.rooms.length;
        m.rooms.add(room);
      } else if (kind == 1) {
        m.set(x0 + c, y0 + c, Tile.corridor);
      }
    }

    // Qué salas se comunican (siguiendo los pasillos de celda en celda).
    for (final start in roomOfCell.keys) {
      final seen = {start};
      final queue = [start];
      while (queue.isNotEmpty) {
        final c = queue.removeAt(0);
        final cx = c % cols, cy = c ~/ cols;
        for (final (bit, dx, dy, _) in _dirs) {
          if (grid[c].$1 & bit == 0) continue;
          final ni = (cy + dy) * cols + cx + dx;
          if (!seen.add(ni)) continue;
          final other = roomOfCell[ni];
          if (other != null) {
            final a = roomOfCell[start]!;
            if (a < other) m.links.add((a, other));
          } else {
            queue.add(ni);
          }
        }
      }
    }

    DungeonGenerator.placeDoors(m);
    // Derrumbes: columnas caídas en las esquinas de algunas salas (sin cerrar el paso).
    for (final room in m.rooms) {
      if (room.w >= 5 && room.h >= 5 && r.nextDouble() < 0.5) {
        for (final (x, y) in [(room.x, room.y), (room.x + room.w - 1, room.y + room.h - 1)]) {
          if (r.nextBool()) m.set(x, y, Tile.pillar);
        }
      }
    }
    DungeonGenerator.number(m);
    DungeonGenerator.decorate(m, r);
    return m;
  }

  /// El núcleo de WFC: devuelve una tesela por celda, o null si hubo
  /// contradicción.
  static List<(int, int)>? _collapse(Random r, int cols, int rows) {
    final n = cols * rows;
    final domain = List.generate(n, (i) {
      final cx = i % cols, cy = i ~/ cols;
      var forbidden = 0;
      if (cy == 0) forbidden |= _n;
      if (cx == cols - 1) forbidden |= _e;
      if (cy == rows - 1) forbidden |= _s;
      if (cx == 0) forbidden |= _w;
      return <int>{for (var t = 0; t < _tiles.length; t++) if (_tiles[t].$1 & forbidden == 0) t};
    });

    bool propagate(List<int> start) {
      final stack = [...start];
      while (stack.isNotEmpty) {
        final c = stack.removeLast();
        final cx = c % cols, cy = c ~/ cols;
        for (final (bit, dx, dy, opp) in _dirs) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
          final ni = ny * cols + nx;
          // ¿Puede esta celda abrir o cerrar hacia la vecina?
          final canOpen = domain[c].any((t) => _tiles[t].$1 & bit != 0);
          final canClose = domain[c].any((t) => _tiles[t].$1 & bit == 0);
          final before = domain[ni].length;
          domain[ni].removeWhere((t) {
            final open = _tiles[t].$1 & opp != 0;
            return open ? !canOpen : !canClose;
          });
          if (domain[ni].isEmpty) return false;
          if (domain[ni].length != before) stack.add(ni);
        }
      }
      return true;
    }

    if (!propagate(List.generate(n, (i) => i))) return null;
    while (true) {
      // Celda sin decidir con menor entropía (con un poco de ruido para desempatar).
      var pick = -1;
      var bestE = double.infinity;
      for (var i = 0; i < n; i++) {
        final d = domain[i];
        if (d.length <= 1) continue;
        final e = d.length + r.nextDouble() * 0.5;
        if (e < bestE) {
          bestE = e;
          pick = i;
        }
      }
      if (pick < 0) break;
      final options = domain[pick].toList();
      final total = options.fold<double>(0, (a, t) => a + _weight(_tiles[t]));
      var roll = r.nextDouble() * total;
      var chosen = options.last;
      for (final t in options) {
        roll -= _weight(_tiles[t]);
        if (roll <= 0) {
          chosen = t;
          break;
        }
      }
      domain[pick]
        ..clear()
        ..add(chosen);
      if (!propagate([pick])) return null;
    }
    return [for (final d in domain) _tiles[d.first]];
  }
}
