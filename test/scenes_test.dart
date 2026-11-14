import 'package:director_de_rol/ai/narration_parser.dart';
import 'package:director_de_rol/core/scenes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deduce el tipo de escena del nombre del lugar', () {
    expect(Scenes.detect('Las catacumbas de San Ulrico')?.id, 'cripta');
    expect(Scenes.detect('Castillo de Roca Negra')?.id, 'castillo');
    expect(Scenes.detect('Taberna del Castillo')?.id, 'taberna');
    expect(Scenes.detect('La Gruta Helada')?.id, 'cueva');
    expect(Scenes.detect('Montaña del Dragón')?.id, 'montana');
    expect(Scenes.detect('Calabozos del rey')?.id, 'mazmorra');
    expect(Scenes.detect('Ningún sitio conocido'), isNull);
    expect(Scenes.byId('Montaña')?.id, 'montana');
  });

  test('lee la etiqueta de escena', () {
    final p = parseNarration('Entráis.\n[[lugar: Fortaleza de Hierro]]\n[[escena: castillo]]');
    expect(p.scene, 'castillo');
    expect(p.location, 'Fortaleza de Hierro');
    expect(p.cleanText, 'Entráis.');
  });
}
