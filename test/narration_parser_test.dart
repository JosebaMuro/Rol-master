import 'package:director_de_rol/ai/llm.dart';
import 'package:director_de_rol/ai/narration_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('separa narración, diálogos de PNJ y etiquetas', () {
    const raw = '''
La puerta se abre con un chirrido.
@Bran el tabernero: "¿Otra vez vosotros?"
Detrás de la barra, algo se mueve.
@Sor Elia: «Que la luz os guarde.»
[[musica: Misterio]]
[[mapa: cripta | La Cripta de los Reyes]]
[[tirada: Percepción CD 15]]
[[lugar: Taberna del Cuervo]]
[[acto: 2]]
¿Qué hacéis?''';
    final p = parseNarration(raw);
    expect(p.speakers, {'Bran el tabernero', 'Sor Elia'});
    expect(p.segments.where((s) => s.isDialogue).first.text, '¿Otra vez vosotros?');
    expect(p.segments.where((s) => s.isDialogue).last.text, 'Que la luz os guarde.');
    expect(p.musicSuggestion, 'Misterio');
    expect(p.mapRequest!.kind, 'cripta');
    expect(p.mapRequest!.title, 'La Cripta de los Reyes');
    expect(p.rolls, ['Percepción CD 15']);
    expect(p.location, 'Taberna del Cuervo');
    expect(p.act, 2);
    expect(p.cleanText, isNot(contains('[[')));
    expect(p.cleanText, contains('**Bran el tabernero:** «¿Otra vez vosotros?»'));
    expect(p.segments.first.isDialogue, isFalse);
  });

  test('acepta diálogo en formato **Nombre**:', () {
    final p = parseNarration('**Kael**: Ni un paso más.');
    expect(p.speakers, {'Kael'});
  });

  test('oculta etiquetas a medio escribir durante el streaming', () {
    expect(stripTagsForDisplay('Texto [[musi'), 'Texto ');
    expect(stripTagsForDisplay('Texto [[musica: Combate]] más'), 'Texto  más');
    expect(stripTagsForDisplay('<think>plan</think>Hola'), 'Hola');
  });

  test('extrae JSON de texto libre', () {
    expect(extractJsonObject('Claro: ```json\n{"a": {"b": "}"}}\n``` fin'), {
      'a': {'b': '}'},
    });
    expect(extractJsonObject('nada'), isEmpty);
  });
}
