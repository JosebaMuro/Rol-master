import 'package:director_de_rol/maps/dungeon_generator.dart';
import 'package:director_de_rol/maps/map_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final kind in ['mazmorra', 'cripta', 'cueva']) {
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
  });

  testWidgets('renderiza el mapa a PNG', (tester) async {
    final m = DungeonGenerator.generate(kind: 'mazmorra', seed: 3, width: 40, height: 30, rooms: 6);
    final png = await tester.runAsync(() => MapRenderer.renderPng(m, 'Prueba'));
    expect(png, isNotNull);
    expect(png!.length, greaterThan(1000));
    expect(png.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
  });
}
