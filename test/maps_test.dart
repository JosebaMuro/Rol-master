import 'dart:io';

import 'package:director_de_rol/maps/dungeon_generator.dart';
import 'package:director_de_rol/maps/map_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final kind in ['mazmorra', 'cripta', 'cueva', 'ruinas']) {
    test('$kind: todas las zonas conectadas y numeradas', () {
      for (var seed = 1; seed <= 25; seed++) {
        final m = DungeonGenerator.generate(kind: kind, seed: seed);
        expect(m.rooms, isNotEmpty, reason: 'semilla $seed');
        expect(DungeonGenerator.isFullyConnected(m), isTrue, reason: '$kind semilla $seed');
        expect(m.rooms.map((r) => r.number).toList(), List.generate(m.rooms.length, (i) => i + 1));
      }
    });
  }

  test('es determinista para la misma semilla', () {
    final a = DungeonGenerator.generate(kind: 'mazmorra', seed: 7);
    final b = DungeonGenerator.generate(kind: 'mazmorra', seed: 7);
    expect(a.tiles, b.tiles);
  });

  test('interpreta tipos de mapa en lenguaje natural', () {
    expect(DungeonGenerator.normalizeKind('Caverna húmeda'), 'cueva');
    expect(DungeonGenerator.normalizeKind('catacumbas'), 'cripta');
    expect(DungeonGenerator.normalizeKind('fortaleza'), 'mazmorra');
    expect(DungeonGenerator.normalizeKind('Ruinas de Velmor'), 'ruinas');
    expect(DungeonGenerator.normalizeKind('laberinto'), 'ruinas');
    expect(DungeonGenerator.normalizeKind('Aldea de Robledal'), 'pueblo');
    expect(DungeonGenerator.normalizeKind('la ciudad portuaria'), 'pueblo');
  });

  test('ruinas (WFC): salas enlazadas y distintas con cada semilla', () {
    final a = DungeonGenerator.generate(kind: 'ruinas', seed: 11);
    final b = DungeonGenerator.generate(kind: 'ruinas', seed: 12);
    expect(a.kind, 'ruinas');
    expect(a.rooms.length, greaterThanOrEqualTo(5));
    expect(a.links, isNotEmpty);
    expect(a.tiles, isNot(b.tiles));
    expect(a.tiles, DungeonGenerator.generate(kind: 'ruinas', seed: 11).tiles);
  });

  test('pueblo: muralla, puertas, calles, casas y lugares con nombre', () {
    for (var seed = 1; seed <= 15; seed++) {
      final m = DungeonGenerator.generate(kind: 'pueblo', seed: seed);
      final all = m.tiles.expand((r) => r).toSet();
      expect(all, containsAll([Tile.townWall, Tile.gate, Tile.road, Tile.plaza, Tile.building]), reason: 'semilla $seed');
      expect(m.buildings.length, greaterThan(15), reason: 'semilla $seed');
      expect(m.rooms.length, greaterThanOrEqualTo(6), reason: 'semilla $seed');
      expect(m.labels.values, contains('Plaza mayor'));
      expect(m.rooms.map((r) => r.number).toList(), List.generate(m.rooms.length, (i) => i + 1));
      // Ninguna casa pisa una calle.
      for (final b in m.buildings) {
        for (var y = b.y; y < b.y + b.h; y++) {
          for (var x = b.x; x < b.x + b.w; x++) {
            expect(m.at(x, y), Tile.building);
          }
        }
      }
    }
  });

  testWidgets('renderiza el mapa a PNG', (tester) async {
    final m = DungeonGenerator.generate(kind: 'mazmorra', seed: 3, width: 40, height: 30, rooms: 6);
    final png = await tester.runAsync(() => MapRenderer.renderPng(m, 'Prueba'));
    expect(png, isNotNull);
    expect(png!.length, greaterThan(1000));
    expect(png.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
  });

  testWidgets('renderiza pueblo y ruinas', (tester) async {
    for (final kind in ['pueblo', 'ruinas']) {
      final m = DungeonGenerator.generate(kind: kind, seed: 5);
      final png = await tester.runAsync(() => MapRenderer.renderPng(m, kind == 'pueblo' ? 'Robledal' : 'Ruinas de Velmor'));
      expect(png!.length, greaterThan(1000));
      final out = Platform.environment['MAPAS_DIR'];
      if (out != null) File('$out/$kind.png').writeAsBytesSync(png);
    }
  });
}
