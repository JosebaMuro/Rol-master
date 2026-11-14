import 'dart:math';

import 'dungeon_generator.dart';

/// Pueblos y ciudades amuralladas: calles principales que salen de la plaza
/// hacia las puertas, callejuelas, manzanas de casas, río con puentes y
/// campos fuera de la muralla. Inspirado en el generador de ciudades
/// medievales de watabou (github.com/watabou/TownGeneratorOS), escrito de
/// nuevo y mucho más sencillo, sobre la misma rejilla que las mazmorras.
class TownGenerator {
  static const landmarks = [
    'Plaza mayor',
    'Taberna',
    'Templo',
    'Mercado',
    'Herrería',
    'Casa del alcalde',
    'Cuartel de la guardia',
    'Posada',
    'Establos',
    'Tienda del alquimista',
  ];

  static DungeonMap generate(int seed, int w, int h) {
    final r = Random(seed);
    final m = DungeonMap(w, h, 'pueblo', seed);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        m.tiles[y][x] = Tile.grass;
      }
    }
    void put(int x, int y, Tile t) {
      if (x >= 0 && y >= 0 && x < w && y < h) m.tiles[y][x] = t;
    }

    final cx = w ~/ 2 + r.nextInt(5) - 2, cy = h ~/ 2 + r.nextInt(3) - 1;
    final rx = w * 0.36, ry = h * 0.36;
    bool inside(int x, int y) => pow((x - cx) / rx, 2) + pow((y - cy) / ry, 2) < 1.0;
    bool onWall(int x, int y) {
      final d = pow((x - cx) / rx, 2) + pow((y - cy) / ry, 2);
      return d >= 0.86 && d < 1.0;
    }

    // Río que cruza de norte a sur, serpenteando.
    final hasRiver = r.nextDouble() < 0.65;
    final riverX = <int>[];
    if (hasRiver) {
      var x = (w * (0.2 + r.nextDouble() * 0.6)).round();
      for (var y = 0; y < h; y++) {
        x = (x + r.nextInt(3) - 1).clamp(4, w - 5);
        riverX.add(x);
        for (var k = -1; k <= 1; k++) {
          put(x + k, y, Tile.water);
        }
      }
    }

    // Muralla con cuatro puertas en los ejes.
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (onWall(x, y) && m.at(x, y) != Tile.water) put(x, y, Tile.townWall);
      }
    }

    // Calles principales: de la plaza a cada puerta, con curvas suaves.
    void road(int x0, int y0, int x1, int y1, {int width = 2}) {
      var x = x0, y = y0;
      while (x != x1 || y != y1) {
        final ddx = (x1 - x).abs(), ddy = (y1 - y).abs();
        if (ddx > ddy || (ddx == ddy && r.nextBool())) {
          x += (x1 - x).sign;
        } else {
          y += (y1 - y).sign;
        }
        if (r.nextDouble() < 0.12) {
          // Pequeño quiebro.
          if (ddx > ddy) {
            y += r.nextBool() ? 1 : -1;
          } else {
            x += r.nextBool() ? 1 : -1;
          }
        }
        for (var a = 0; a < width; a++) {
          for (var b = 0; b < width; b++) {
            final t = m.at(x + a, y + b);
            if (t == Tile.water) {
              put(x + a, y + b, Tile.bridge);
            } else if (t == Tile.townWall) {
              put(x + a, y + b, Tile.gate);
            } else if (t != Tile.bridge && t != Tile.gate && x + a < w && y + b < h) {
              put(x + a, y + b, Tile.road);
            }
          }
        }
      }
    }

    final gates = [(cx, 0), (w - 1, cy), (cx, h - 1), (0, cy)];
    for (final (gx, gy) in gates) {
      road(cx, cy, gx.clamp(0, w - 2), gy.clamp(0, h - 2));
    }
    // Una calle diagonal de vez en cuando.
    if (r.nextBool()) road(cx, cy, (cx + rx * 0.9).round(), (cy - ry * 0.9).round(), width: 1);

    // Plaza mayor.
    final plaza = Room(cx - 3, cy - 2, 7, 5, 0);
    for (var y = plaza.y; y < plaza.y + plaza.h; y++) {
      for (var x = plaza.x; x < plaza.x + plaza.w; x++) {
        if (m.at(x, y) != Tile.water) put(x, y, Tile.plaza);
      }
    }

    // Callejuelas en rejilla irregular dentro de la muralla.
    for (var y = cy - (ry * 0.8).round(); y < cy + ry; y += 5 + r.nextInt(3)) {
      final x0 = cx - (rx * (0.4 + r.nextDouble() * 0.5)).round(), x1 = cx + (rx * (0.4 + r.nextDouble() * 0.5)).round();
      for (var x = x0; x <= x1; x++) {
        if (inside(x, y) && !onWall(x, y) && m.at(x, y) == Tile.grass) put(x, y, Tile.road);
        if (m.at(x, y) == Tile.water) put(x, y, Tile.bridge);
      }
    }
    for (var x = cx - (rx * 0.85).round(); x < cx + rx; x += 6 + r.nextInt(4)) {
      final y0 = cy - (ry * (0.3 + r.nextDouble() * 0.6)).round(), y1 = cy + (ry * (0.3 + r.nextDouble() * 0.6)).round();
      for (var y = y0; y <= y1; y++) {
        if (inside(x, y) && !onWall(x, y) && m.at(x, y) == Tile.grass) put(x, y, Tile.road);
      }
    }

    // Casas: rectángulos pegados a una calle, con callejones entre ellas.
    bool free(Room b) {
      for (var y = b.y - 1; y <= b.y + b.h; y++) {
        for (var x = b.x - 1; x <= b.x + b.w; x++) {
          final t = m.at(x, y);
          final edge = y == b.y - 1 || y == b.y + b.h || x == b.x - 1 || x == b.x + b.w;
          if (edge) {
            if (t == Tile.building) return false;
          } else if (t != Tile.grass || !inside(x, y) || onWall(x, y)) {
            return false;
          }
        }
      }
      return true;
    }

    bool nearRoad(Room b) {
      for (var y = b.y - 1; y <= b.y + b.h; y++) {
        for (var x = b.x - 1; x <= b.x + b.w; x++) {
          final t = m.at(x, y);
          if (t == Tile.road || t == Tile.plaza) return true;
        }
      }
      return false;
    }

    for (var tries = 0; tries < 2600; tries++) {
      final bw = 2 + r.nextInt(3), bh = 2 + r.nextInt(2);
      final b = Room(2 + r.nextInt(w - bw - 4), 2 + r.nextInt(h - bh - 4), bw, bh, 0);
      if (!free(b) || !nearRoad(b)) continue;
      for (var y = b.y; y < b.y + b.h; y++) {
        for (var x = b.x; x < b.x + b.w; x++) {
          put(x, y, Tile.building);
        }
      }
      m.buildings.add(b);
    }

    // Fuera de la muralla: campos de cultivo junto a los caminos y arboledas.
    for (var i = 0; i < 9; i++) {
      final fw = 5 + r.nextInt(6), fh = 3 + r.nextInt(4);
      final fx = r.nextInt(w - fw), fy = r.nextInt(h - fh);
      var ok = true;
      for (var y = fy; y < fy + fh && ok; y++) {
        for (var x = fx; x < fx + fw; x++) {
          if (m.at(x, y) != Tile.grass || inside(x, y)) {
            ok = false;
            break;
          }
        }
      }
      if (!ok) continue;
      for (var y = fy; y < fy + fh; y++) {
        for (var x = fx; x < fx + fw; x++) {
          put(x, y, Tile.field);
        }
      }
    }
    for (var i = 0; i < 160; i++) {
      final x = r.nextInt(w), y = r.nextInt(h);
      if (m.at(x, y) == Tile.grass && !inside(x, y)) put(x, y, Tile.tree);
    }

    // Lugares numerados: la plaza y los edificios más destacados.
    final plazaRoom = Room(plaza.x, plaza.y, plaza.w, plaza.h, 0);
    m.rooms.add(plazaRoom);
    m.labels[plazaRoom] = landmarks.first;
    final byPlaza = [...m.buildings]..sort((a, b) {
        int d(Room q) => (q.cx - cx).abs() + (q.cy - cy).abs();
        return d(a).compareTo(d(b));
      });
    final big = [...m.buildings]..sort((a, b) => (b.w * b.h).compareTo(a.w * a.h));
    final chosen = <Room>{};
    for (final b in [...byPlaza.take(4), ...big.take(4), ...byPlaza.skip(8).take(30).where((_) => r.nextDouble() < 0.1)]) {
      if (m.rooms.length >= landmarks.length) break;
      if (chosen.add(b)) {
        m.labels[b] = landmarks[m.rooms.length];
        m.rooms.add(b);
      }
    }
    // Las puertas de la muralla también se numeran.
    const gateNames = ['Puerta norte', 'Puerta este', 'Puerta sur', 'Puerta oeste'];
    for (var i = 0; i < gates.length; i++) {
      final (gx, gy) = gates[i];
      final g = _findGate(m, gx.clamp(0, w - 1), gy.clamp(0, h - 1), cx, cy);
      if (g == null) continue;
      final room = Room(g.$1 - 1, g.$2 - 1, 3, 3, 0);
      m.labels[room] = gateNames[i];
      m.rooms.add(room);
    }
    DungeonGenerator.number(m);
    return m;
  }

  /// Busca una casilla de puerta en la recta entre el borde y el centro.
  static (int, int)? _findGate(DungeonMap m, int gx, int gy, int cx, int cy) {
    for (var t = 0.0; t <= 1.0; t += 0.01) {
      final x = (gx + (cx - gx) * t).round(), y = (gy + (cy - gy) * t).round();
      for (var k = -2; k <= 2; k++) {
        for (final (xx, yy) in [(x + k, y), (x, y + k)]) {
          if (m.at(xx, yy) == Tile.gate) return (xx, yy);
        }
      }
    }
    return null;
  }
}
