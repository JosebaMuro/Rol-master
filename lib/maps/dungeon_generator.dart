import 'dart:math';

/// Tipos de casilla del mapa.
enum Tile { wall, floor, corridor, door, water, stairsUp, stairsDown, pillar }

class Room {
  Room(this.x, this.y, this.w, this.h, this.number);
  final int x, y, w, h;
  int number;
  int get cx => x + w ~/ 2;
  int get cy => y + h ~/ 2;
  bool contains(int px, int py) => px >= x && px < x + w && py >= y && py < y + h;
  bool overlaps(Room o, int margin) =>
      x - margin < o.x + o.w && x + w + margin > o.x && y - margin < o.y + o.h && y + h + margin > o.y;
}

class DungeonMap {
  DungeonMap(this.width, this.height, this.kind, this.seed)
      : tiles = List.generate(height, (_) => List.filled(width, Tile.wall));
  final int width, height;
  final String kind;
  final int seed;
  final List<List<Tile>> tiles;
  final List<Room> rooms = [];

  /// Conexiones entre salas (índices en [rooms]) para la leyenda.
  final List<(int, int)> links = [];

  Tile at(int x, int y) => (x < 0 || y < 0 || x >= width || y >= height) ? Tile.wall : tiles[y][x];
  void set(int x, int y, Tile t) {
    if (x > 0 && y > 0 && x < width - 1 && y < height - 1) tiles[y][x] = t;
  }

  bool isOpen(int x, int y) => at(x, y) != Tile.wall;

  int get openCount => tiles.fold(0, (a, row) => a + row.where((t) => t != Tile.wall).length);
}

/// Generador procedimental de mapas: mazmorras clásicas, criptas simétricas y
/// cuevas naturales. Determinista a partir de la semilla.
class DungeonGenerator {
  static const kinds = {'mazmorra': 'Mazmorra', 'cripta': 'Cripta', 'cueva': 'Cueva'};

  static String normalizeKind(String k) {
    final n = k.toLowerCase();
    if (n.contains('cuev') || n.contains('caverna') || n.contains('gruta') || n.contains('mina')) return 'cueva';
    if (n.contains('cript') || n.contains('tumba') || n.contains('templo') || n.contains('catacumba')) return 'cripta';
    return 'mazmorra';
  }

  static DungeonMap generate({required String kind, required int seed, int width = 64, int height = 44, int? rooms}) {
    switch (normalizeKind(kind)) {
      case 'cueva':
        return _cave(seed, width, height, rooms ?? 7);
      case 'cripta':
        return _crypt(seed, width, height);
      default:
        return _dungeon(seed, width, height, rooms ?? 12);
    }
  }

  // ------------------------------------------------------------ mazmorra
  static DungeonMap _dungeon(int seed, int w, int h, int target) {
    final r = Random(seed);
    final m = DungeonMap(w, h, 'mazmorra', seed);
    var attempts = 0;
    while (m.rooms.length < target && attempts++ < 600) {
      final rw = 4 + r.nextInt(7), rh = 4 + r.nextInt(5);
      final rx = 2 + r.nextInt(w - rw - 4), ry = 2 + r.nextInt(h - rh - 4);
      final room = Room(rx, ry, rw, rh, 0);
      if (m.rooms.any((o) => o.overlaps(room, 2))) continue;
      m.rooms.add(room);
    }
    _carveRooms(m);
    _connect(m, r, extraRatio: 0.2);
    _decorate(m, r);
    return m;
  }

  // -------------------------------------------------------------- cripta
  static DungeonMap _crypt(int seed, int w, int h) {
    final r = Random(seed);
    final m = DungeonMap(w, h, 'cripta', seed);
    const cols = 5, rows = 3;
    final cw = (w - 4) ~/ cols, ch = (h - 4) ~/ rows;
    for (var gy = 0; gy < rows; gy++) {
      for (var gx = 0; gx < cols; gx++) {
        // Simetría: la mitad derecha refleja a la izquierda.
        final mirror = cols - 1 - gx;
        final rr = Random(seed * 31 + gy * 7 + min(gx, mirror));
        if (gx != cols ~/ 2 && rr.nextDouble() < 0.18) continue;
        final rw = max(3, cw - 2 - rr.nextInt(3)), rh = max(3, ch - 2 - rr.nextInt(3));
        final rx = 2 + gx * cw + (cw - rw) ~/ 2, ry = 2 + gy * ch + (ch - rh) ~/ 2;
        m.rooms.add(Room(rx, ry, rw, rh, 0));
      }
    }
    _carveRooms(m);
    // Conexiones en rejilla (vecinos) con árbol + algunas extra.
    _connect(m, r, extraRatio: 0.35, gridLike: true);
    // Columnas en las salas grandes.
    for (final room in m.rooms) {
      if (room.w >= 7 && room.h >= 5) {
        for (final dx in [1, room.w - 2]) {
          for (var y = room.y + 1; y < room.y + room.h - 1; y += 2) {
            m.set(room.x + dx, y, Tile.pillar);
          }
        }
      }
    }
    _decorate(m, r);
    return m;
  }

  // --------------------------------------------------------------- cueva
  static DungeonMap _cave(int seed, int w, int h, int zones) {
    final r = Random(seed);
    final m = DungeonMap(w, h, 'cueva', seed);
    var grid = List.generate(h, (y) => List.generate(w, (x) {
          if (x == 0 || y == 0 || x == w - 1 || y == h - 1) return true;
          return r.nextDouble() < 0.45;
        }));
    for (var it = 0; it < 5; it++) {
      final next = List.generate(h, (_) => List.filled(w, true));
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          var walls = 0;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (grid[y + dy][x + dx]) walls++;
            }
          }
          next[y][x] = walls >= 5;
        }
      }
      grid = next;
    }
    // Región abierta más grande.
    final region = List.generate(h, (_) => List.filled(w, -1));
    var best = -1, bestSize = 0, id = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        if (grid[y][x] || region[y][x] >= 0) continue;
        var size = 0;
        final stack = [(x, y)];
        region[y][x] = id;
        while (stack.isNotEmpty) {
          final (cx, cy) = stack.removeLast();
          size++;
          for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final nx = cx + dx, ny = cy + dy;
            if (nx > 0 && ny > 0 && nx < w - 1 && ny < h - 1 && !grid[ny][nx] && region[ny][nx] < 0) {
              region[ny][nx] = id;
              stack.add((nx, ny));
            }
          }
        }
        if (size > bestSize) {
          bestSize = size;
          best = id;
        }
        id++;
      }
    }
    final open = <(int, int)>[];
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        if (region[y][x] == best) {
          m.tiles[y][x] = Tile.floor;
          open.add((x, y));
        }
      }
    }
    if (open.isEmpty) return _dungeon(seed, w, h, 8);
    // Charcas subterráneas.
    final pools = 1 + r.nextInt(3);
    for (var i = 0; i < pools; i++) {
      final (px, py) = open[r.nextInt(open.length)];
      final rad = 1 + r.nextInt(3);
      for (var y = py - rad; y <= py + rad; y++) {
        for (var x = px - rad; x <= px + rad; x++) {
          if ((x - px) * (x - px) + (y - py) * (y - py) <= rad * rad && m.at(x, y) == Tile.floor) {
            m.tiles[y][x] = Tile.water;
          }
        }
      }
    }
    // Zonas numeradas repartidas por muestreo del punto más lejano.
    final picks = <(int, int)>[open[r.nextInt(open.length)]];
    while (picks.length < zones) {
      (int, int)? far;
      var farD = -1;
      for (var i = 0; i < open.length; i += 3) {
        final o = open[i];
        if (m.at(o.$1, o.$2) != Tile.floor) continue;
        var d = 1 << 30;
        for (final pk in picks) {
          d = min(d, (o.$1 - pk.$1) * (o.$1 - pk.$1) + (o.$2 - pk.$2) * (o.$2 - pk.$2));
        }
        if (d > farD) {
          farD = d;
          far = o;
        }
      }
      if (far == null) break;
      picks.add(far);
    }
    for (final (x, y) in picks) {
      m.rooms.add(Room(x - 1, y - 1, 3, 3, 0));
    }
    _number(m);
    // Escaleras junto a la primera y la última zona (no bajo el número).
    void stairsNear(Room z, Tile t) {
      for (final (dx, dy) in const [(2, 0), (-2, 0), (0, 2), (0, -2), (1, 1), (-1, -1)]) {
        if (m.at(z.cx + dx, z.cy + dy) == Tile.floor) {
          m.tiles[z.cy + dy][z.cx + dx] = t;
          return;
        }
      }
    }

    stairsNear(m.rooms.first, Tile.stairsUp);
    stairsNear(m.rooms.last, Tile.stairsDown);
    return m;
  }

  // ------------------------------------------------------------ utilidades
  static void _carveRooms(DungeonMap m) {
    for (final room in m.rooms) {
      for (var y = room.y; y < room.y + room.h; y++) {
        for (var x = room.x; x < room.x + room.w; x++) {
          m.set(x, y, Tile.floor);
        }
      }
    }
  }

  static void _connect(DungeonMap m, Random r, {double extraRatio = 0.2, bool gridLike = false}) {
    final n = m.rooms.length;
    if (n < 2) return;
    int dist(int a, int b) =>
        (m.rooms[a].cx - m.rooms[b].cx).abs() + (m.rooms[a].cy - m.rooms[b].cy).abs();
    // Árbol de expansión mínima (Prim).
    final inTree = <int>{0};
    final edges = <(int, int)>[];
    while (inTree.length < n) {
      (int, int)? best;
      var bestD = 1 << 30;
      for (final a in inTree) {
        for (var b = 0; b < n; b++) {
          if (inTree.contains(b)) continue;
          final d = dist(a, b);
          if (d < bestD) {
            bestD = d;
            best = (a, b);
          }
        }
      }
      edges.add(best!);
      inTree.add(best.$2);
    }
    // Conexiones extra para crear bucles (más interesante de explorar).
    final extra = (n * extraRatio).round();
    for (var i = 0; i < extra; i++) {
      final a = r.nextInt(n);
      var b = -1, bd = 1 << 30;
      for (var j = 0; j < n; j++) {
        if (j == a || edges.contains((a, j)) || edges.contains((j, a))) continue;
        final d = dist(a, j);
        if (d < bd && (!gridLike || d < 40)) {
          bd = d;
          b = j;
        }
      }
      if (b >= 0) edges.add((a, b));
    }
    for (final (a, b) in edges) {
      _corridor(m, r, m.rooms[a], m.rooms[b]);
      m.links.add((a, b));
    }
    // Puertas: casillas de pasillo que entran en perpendicular a una sala
    // (no las de un pasillo que corre pegado a la pared).
    bool walled(int x, int y) => m.at(x, y) == Tile.wall;
    for (final room in m.rooms) {
      for (var x = room.x; x < room.x + room.w; x++) {
        for (final (y, dy) in [(room.y - 1, -1), (room.y + room.h, 1)]) {
          if (m.at(x, y) == Tile.corridor && walled(x - 1, y) && walled(x + 1, y) && m.isOpen(x, y + dy)) {
            m.set(x, y, Tile.door);
          }
        }
      }
      for (var y = room.y; y < room.y + room.h; y++) {
        for (final (x, dx) in [(room.x - 1, -1), (room.x + room.w, 1)]) {
          if (m.at(x, y) == Tile.corridor && walled(x, y - 1) && walled(x, y + 1) && m.isOpen(x + dx, y)) {
            m.set(x, y, Tile.door);
          }
        }
      }
    }
    _number(m);
  }

  static void _corridor(DungeonMap m, Random r, Room a, Room b) {
    var x = a.cx, y = a.cy;
    final horizontalFirst = r.nextBool();
    void step(int nx, int ny) {
      if (m.at(nx, ny) == Tile.wall) m.set(nx, ny, Tile.corridor);
    }

    if (horizontalFirst) {
      while (x != b.cx) {
        x += (b.cx - x).sign;
        step(x, y);
      }
      while (y != b.cy) {
        y += (b.cy - y).sign;
        step(x, y);
      }
    } else {
      while (y != b.cy) {
        y += (b.cy - y).sign;
        step(x, y);
      }
      while (x != b.cx) {
        x += (b.cx - x).sign;
        step(x, y);
      }
    }
  }

  /// Numera las salas de izquierda a derecha y de arriba abajo, como en los
  /// módulos clásicos.
  static void _number(DungeonMap m) {
    final order = [...m.rooms]..sort((a, b) {
        final band = (a.cy ~/ 10).compareTo(b.cy ~/ 10);
        return band != 0 ? band : a.cx.compareTo(b.cx);
      });
    for (var i = 0; i < order.length; i++) {
      order[i].number = i + 1;
    }
    final index = {for (var i = 0; i < m.rooms.length; i++) m.rooms[i]: i};
    final remapped = m.links.map((l) => (index[m.rooms[l.$1]]!, index[m.rooms[l.$2]]!)).toList();
    m.rooms.sort((a, b) => a.number.compareTo(b.number));
    final newIndex = {for (var i = 0; i < m.rooms.length; i++) m.rooms[i]: i};
    final byOld = {for (final e in index.entries) e.value: e.key};
    m.links
      ..clear()
      ..addAll(remapped.map((l) => (newIndex[byOld[l.$1]]!, newIndex[byOld[l.$2]]!)));
  }

  static void _decorate(DungeonMap m, Random r) {
    if (m.rooms.isEmpty) return;
    final first = m.rooms.first, last = m.rooms.last;
    m.set(first.x + 1, first.y + 1, Tile.stairsUp);
    m.set(last.x + last.w - 2, last.y + last.h - 2, Tile.stairsDown);
    // Alguna sala inundada.
    if (m.rooms.length > 4 && r.nextDouble() < 0.6) {
      final room = m.rooms[1 + r.nextInt(m.rooms.length - 2)];
      for (var y = room.y + 1; y < room.y + room.h - 1; y++) {
        for (var x = room.x + 1; x < room.x + room.w - 1; x++) {
          if (r.nextDouble() < 0.55 && m.at(x, y) == Tile.floor) m.set(x, y, Tile.water);
        }
      }
    }
  }

  /// Comprueba que todo el espacio abierto es alcanzable desde la sala 1.
  static bool isFullyConnected(DungeonMap m) {
    if (m.rooms.isEmpty) return false;
    final start = (m.rooms.first.cx, m.rooms.first.cy);
    final seen = <(int, int)>{start};
    final stack = [start];
    while (stack.isNotEmpty) {
      final (x, y) = stack.removeLast();
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final n = (x + dx, y + dy);
        if (m.isOpen(n.$1, n.$2) && seen.add(n)) stack.add(n);
      }
    }
    return seen.length == m.openCount;
  }
}
