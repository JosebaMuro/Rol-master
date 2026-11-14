import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'dungeon_generator.dart';

/// Dibuja un [DungeonMap] con estilo de pergamino y lo exporta a PNG.
class MapRenderer {
  static const cell = 22.0;
  static const margin = 60.0;

  static const _parchment = Color(0xFFEBDDBF);
  static const _floor = Color(0xFFFBF5E6);
  static const _wallFill = Color(0xFF3E3329);
  static const _ink = Color(0xFF2B211A);
  static const _water = Color(0xFF7FA7C9);
  static const _door = Color(0xFF8B5A2B);

  static Future<Uint8List> renderPng(DungeonMap m, String title) async {
    final size = Size(m.width * cell + margin * 2, m.height * cell + margin * 2 + 30);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    paint(canvas, size, m, title);
    final pic = rec.endRecording();
    final img = await pic.toImage(size.width.ceil(), size.height.ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bytes!.buffer.asUint8List();
  }

  static void paint(Canvas canvas, Size size, DungeonMap m, String title) {
    if (m.isTown) return _paintTown(canvas, size, m, title);
    final r = Random(m.seed);
    canvas.drawRect(Offset.zero & size, Paint()..color = _parchment);
    // Manchas del pergamino.
    for (var i = 0; i < 40; i++) {
      canvas.drawCircle(
        Offset(r.nextDouble() * size.width, r.nextDouble() * size.height),
        20 + r.nextDouble() * 90,
        Paint()..color = const Color(0xFFC8B48A).withValues(alpha: 0.06 + r.nextDouble() * 0.06),
      );
    }

    final origin = Offset(margin, margin + 30);
    Rect cellRect(int x, int y) => Rect.fromLTWH(origin.dx + x * cell, origin.dy + y * cell, cell, cell);

    // Sombra de roca alrededor del espacio abierto (rayado).
    final hatch = Paint()
      ..color = _ink.withValues(alpha: 0.55)
      ..strokeWidth = 1.1;
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        if (m.at(x, y) != Tile.wall) continue;
        var near = false;
        for (var dy = -2; dy <= 2 && !near; dy++) {
          for (var dx = -2; dx <= 2 && !near; dx++) {
            if (m.isOpen(x + dx, y + dy)) near = true;
          }
        }
        if (!near) continue;
        final c = cellRect(x, y);
        for (var k = 0; k < 3; k++) {
          final t = r.nextDouble();
          final a = Offset(c.left + t * cell, c.top + r.nextDouble() * cell);
          canvas.drawLine(a, a + Offset(5 + r.nextDouble() * 4, -4 - r.nextDouble() * 4), hatch);
        }
      }
    }

    // Suelo con rejilla.
    final floorPaint = Paint()..color = _floor;
    final grid = Paint()
      ..color = const Color(0xFFB9A98A)
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        final t = m.at(x, y);
        if (t == Tile.wall) continue;
        final c = cellRect(x, y);
        canvas.drawRect(c, floorPaint);
        canvas.drawRect(c, grid);
        switch (t) {
          case Tile.water:
            canvas.drawRect(c.deflate(0.5), Paint()..color = _water.withValues(alpha: 0.75));
            canvas.drawLine(c.centerLeft + const Offset(4, 0), c.center + const Offset(0, -2),
                Paint()..color = const Color(0xFFE8F1F8)..strokeWidth = 1);
          case Tile.door:
            final horizontal = m.isOpen(x - 1, y) && m.isOpen(x + 1, y);
            final d = horizontal
                ? Rect.fromCenter(center: c.center, width: cell * 0.35, height: cell * 0.9)
                : Rect.fromCenter(center: c.center, width: cell * 0.9, height: cell * 0.35);
            canvas.drawRect(d, Paint()..color = _door);
            canvas.drawRect(d, Paint()..color = _ink..style = PaintingStyle.stroke..strokeWidth = 1.2);
          case Tile.pillar:
            canvas.drawCircle(c.center, cell * 0.32, Paint()..color = _wallFill);
          case Tile.stairsUp || Tile.stairsDown:
            final p = Paint()
              ..color = _ink
              ..strokeWidth = 1.4;
            for (var i = 0; i < 5; i++) {
              final xx = c.left + 3 + i * (cell - 6) / 4;
              final shrink = t == Tile.stairsDown ? i * 1.5 : (4 - i) * 1.5;
              canvas.drawLine(Offset(xx, c.top + 3 + shrink), Offset(xx, c.bottom - 3 - shrink), p);
            }
          default:
            break;
        }
      }
    }

    // Contorno de los muros.
    final wallLine = Paint()
      ..color = _ink
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.square;
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        if (!m.isOpen(x, y)) continue;
        final c = cellRect(x, y);
        if (!m.isOpen(x, y - 1)) canvas.drawLine(c.topLeft, c.topRight, wallLine);
        if (!m.isOpen(x, y + 1)) canvas.drawLine(c.bottomLeft, c.bottomRight, wallLine);
        if (!m.isOpen(x - 1, y)) canvas.drawLine(c.topLeft, c.bottomLeft, wallLine);
        if (!m.isOpen(x + 1, y)) canvas.drawLine(c.topRight, c.bottomRight, wallLine);
      }
    }

    // Números de sala.
    for (final room in m.rooms) {
      final c = cellRect(room.cx, room.cy).center;
      canvas.drawCircle(c, cell * 0.62, Paint()..color = const Color(0xFFFFFBF0));
      canvas.drawCircle(c, cell * 0.62, Paint()..color = const Color(0xFF8E1B1B)..style = PaintingStyle.stroke..strokeWidth = 2);
      _text(canvas, '${room.number}', c, 13, const Color(0xFF8E1B1B), bold: true);
    }

    // Título y rosa de los vientos.
    _text(canvas, title, Offset(size.width / 2, 38), 26, _ink, bold: true, serif: true);
    _compass(canvas, Offset(size.width - margin + 10, size.height - margin + 10));
    _text(canvas, '1 casilla = 1,5 m', Offset(margin + 50, size.height - 22), 12, _ink);
  }

  // ------------------------------------------------------------- pueblos
  static const _grass = Color(0xFFD9DDB0);
  static const _road = Color(0xFFF3E7C9);
  static const _plazaC = Color(0xFFE9D9B0);
  static const _roof = Color(0xFF9C4F36);
  static const _roofDark = Color(0xFF6E3423);
  static const _stone = Color(0xFF5B5049);
  static const _field = Color(0xFFC9C27A);
  static const _treeC = Color(0xFF5E7D4A);

  static void _paintTown(Canvas canvas, Size size, DungeonMap m, String title) {
    final r = Random(m.seed);
    canvas.drawRect(Offset.zero & size, Paint()..color = _parchment);
    final origin = Offset(margin, margin + 30);
    Rect cellRect(int x, int y) => Rect.fromLTWH(origin.dx + x * cell, origin.dy + y * cell, cell, cell);
    canvas.drawRect(Rect.fromLTWH(origin.dx, origin.dy, m.width * cell, m.height * cell), Paint()..color = _grass);

    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        final c = cellRect(x, y);
        switch (m.at(x, y)) {
          case Tile.road || Tile.gate:
            canvas.drawRect(c.inflate(0.4), Paint()..color = _road);
          case Tile.plaza:
            canvas.drawRect(c.inflate(0.4), Paint()..color = _plazaC);
            canvas.drawRect(c.deflate(2), Paint()..color = const Color(0xFFD7C493)..style = PaintingStyle.stroke..strokeWidth = 0.7);
          case Tile.water:
            canvas.drawRect(c.inflate(0.4), Paint()..color = _water);
            if (r.nextDouble() < 0.3) {
              canvas.drawLine(c.centerLeft + const Offset(4, 0), c.center + const Offset(3, -2),
                  Paint()..color = const Color(0xFFE8F1F8)..strokeWidth = 1);
            }
          case Tile.bridge:
            canvas.drawRect(c.inflate(0.4), Paint()..color = _water);
            canvas.drawRect(c.deflate(1), Paint()..color = _door);
            canvas.drawLine(c.topLeft, c.topRight, Paint()..color = _ink..strokeWidth = 1.2);
            canvas.drawLine(c.bottomLeft, c.bottomRight, Paint()..color = _ink..strokeWidth = 1.2);
          case Tile.field:
            canvas.drawRect(c.inflate(0.4), Paint()..color = _field);
            canvas.drawLine(c.topLeft + const Offset(0, 6), c.topRight + const Offset(0, 6),
                Paint()..color = const Color(0xFFA9A15A)..strokeWidth = 1);
            canvas.drawLine(c.topLeft + const Offset(0, 15), c.topRight + const Offset(0, 15),
                Paint()..color = const Color(0xFFA9A15A)..strokeWidth = 1);
          case Tile.tree:
            canvas.drawCircle(c.center + Offset(r.nextDouble() * 4 - 2, r.nextDouble() * 4 - 2), cell * 0.55,
                Paint()..color = _treeC.withValues(alpha: 0.85));
            canvas.drawCircle(c.center, cell * 0.55, Paint()..color = _ink.withValues(alpha: 0.35)..style = PaintingStyle.stroke);
          default:
            break;
        }
      }
    }

    // Muralla de piedra con almenas, y puertas.
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        final t = m.at(x, y);
        final c = cellRect(x, y);
        if (t == Tile.townWall) {
          canvas.drawRect(c.inflate(0.6), Paint()..color = _stone);
          canvas.drawRect(c.deflate(4), Paint()..color = const Color(0xFF7A6E66));
        } else if (t == Tile.gate) {
          final nearWall = [(1, 0), (-1, 0), (0, 1), (0, -1)].any((d) => m.at(x + d.$1, y + d.$2) == Tile.townWall);
          if (nearWall) canvas.drawRect(c.deflate(3), Paint()..color = _door.withValues(alpha: 0.7));
        }
      }
    }

    // Casas con tejado a dos aguas.
    for (final b in m.buildings) {
      final rect = Rect.fromLTWH(origin.dx + b.x * cell + 1.5, origin.dy + b.y * cell + 1.5, b.w * cell - 3, b.h * cell - 3);
      canvas.drawRect(rect.shift(const Offset(2, 2)), Paint()..color = const Color(0xFF000000).withValues(alpha: 0.18));
      canvas.drawRect(rect, Paint()..color = _roof);
      final horizontal = b.w >= b.h;
      final ridge = Paint()
        ..color = _roofDark
        ..strokeWidth = 2;
      if (horizontal) {
        canvas.drawLine(rect.centerLeft, rect.centerRight, ridge);
        canvas.drawRect(Rect.fromLTRB(rect.left, rect.center.dy, rect.right, rect.bottom),
            Paint()..color = _roofDark.withValues(alpha: 0.35));
      } else {
        canvas.drawLine(rect.topCenter, rect.bottomCenter, ridge);
        canvas.drawRect(Rect.fromLTRB(rect.center.dx, rect.top, rect.right, rect.bottom),
            Paint()..color = _roofDark.withValues(alpha: 0.35));
      }
      canvas.drawRect(rect, Paint()..color = _ink..style = PaintingStyle.stroke..strokeWidth = 1.2);
    }

    // Números de los lugares.
    for (final room in m.rooms) {
      final c = cellRect(room.cx, room.cy).center;
      canvas.drawCircle(c, cell * 0.62, Paint()..color = const Color(0xFFFFFBF0));
      canvas.drawCircle(c, cell * 0.62, Paint()..color = const Color(0xFF8E1B1B)..style = PaintingStyle.stroke..strokeWidth = 2);
      _text(canvas, '${room.number}', c, 13, const Color(0xFF8E1B1B), bold: true);
    }

    _text(canvas, title, Offset(size.width / 2, 38), 26, _ink, bold: true, serif: true);
    _compass(canvas, Offset(size.width - margin + 10, size.height - margin + 10));
    _text(canvas, '1 casilla = 5 m', Offset(margin + 50, size.height - 22), 12, _ink);
  }

  static void _compass(Canvas canvas, Offset c) {
    final p = Path()
      ..moveTo(c.dx, c.dy - 26)
      ..lineTo(c.dx + 7, c.dy)
      ..lineTo(c.dx, c.dy + 26)
      ..lineTo(c.dx - 7, c.dy)
      ..close();
    canvas.drawPath(p, Paint()..color = _ink);
    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - 26)
        ..lineTo(c.dx + 7, c.dy)
        ..lineTo(c.dx, c.dy)
        ..close(),
      Paint()..color = const Color(0xFF8E1B1B),
    );
    _text(canvas, 'N', c + const Offset(0, -36), 13, _ink, bold: true);
  }

  static void _text(Canvas canvas, String s, Offset center, double size, Color color, {bool bold = false, bool serif = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontFamily: serif ? 'serif' : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }
}
