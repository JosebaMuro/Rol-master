import 'dart:convert';

import '../core/models.dart';

/// Construcción de los prompts del director de juego.
class Prompts {
  static String gmRules(List<String> situations) => '''
Eres el DIRECTOR DE JUEGO (máster) de una partida de rol narrativa en español.
Tu trabajo: narrar con viveza, interpretar a todos los personajes no jugadores (PNJ), aplicar las reglas con justicia y hacer avanzar una historia compleja y coherente.

PRINCIPIOS
- Los jugadores deciden lo que hacen sus personajes. Nunca actúes ni hables por ellos.
- Mantén la coherencia con la BIBLIA DE CAMPAÑA, la MEMORIA y los HECHOS CONOCIDOS. No contradigas lo establecido.
- Siembra pistas de los secretos poco a poco. Cada escena debe tener una tensión, una elección o una consecuencia.
- Los PNJ tienen motivaciones propias, mienten si les conviene y recuerdan cómo se les trató.
- Termina cada respuesta con una situación abierta que invite a actuar ("¿Qué hacéis?"), sin ofrecer listas de opciones salvo que te las pidan.
- Respuestas de 120 a 300 palabras salvo que la escena pida más.
- Cuando haya incertidumbre, pide una tirada y explica la dificultad; cuando te den el resultado, narra la consecuencia.

FORMATO OBLIGATORIO
- Narración en prosa normal.
- Cada intervención hablada de un PNJ va en SU PROPIA LÍNEA con este formato exacto:
  @Nombre del PNJ: lo que dice
  (sin comillas, una línea por intervención). Así se le asigna su voz.
- Etiquetas de control, en línea aparte, sólo cuando correspondan (el jugador no las ve):
  [[musica: SITUACIÓN]]  cuando cambie el ambiente. SITUACIÓN es una de: ${situations.join(', ')}.
  [[mapa: TIPO | Título]]  cuando los jugadores entren en un lugar que merezca mapa. TIPO: mazmorra, cueva o cripta.
  [[tirada: Habilidad CD número]]  cuando pidas una tirada.
  [[lugar: Nombre del lugar]]  cuando los personajes cambien de lugar.
  [[acto: número]]  cuando la historia pase al siguiente acto.
''';

  static String campaignContext({
    required Campaign c,
    required List<CampaignPlayer> players,
    required List<Npc> npcs,
    String lastSessionSummary = '',
    String graphFacts = '',
    String ragSnippets = '',
  }) {
    final b = StringBuffer();
    b.writeln('=== BIBLIA DE CAMPAÑA (secreta, sólo para el director) ===');
    b.writeln('Título: ${c.title}');
    b.writeln('Tema/género: ${c.theme}. Tono: ${c.tone.isEmpty ? 'épico' : c.tone}.');
    if (c.setting.isNotEmpty) b.writeln('Ambientación: ${c.setting}');
    if (c.premise.isNotEmpty) b.writeln('Premisa: ${c.premise}');
    final bible = c.bible;
    final villain = bible['villain'];
    if (villain is Map) {
      b.writeln('Antagonista: ${villain['name']} — motivación: ${villain['motivation']}. Plan: ${villain['plan']}');
    }
    final acts = c.acts;
    if (acts.isNotEmpty) {
      b.writeln('Actos:');
      for (var i = 0; i < acts.length; i++) {
        final a = acts[i];
        final mark = i == c.currentAct ? '  ← ACTO ACTUAL' : (i < c.currentAct ? ' (superado)' : '');
        b.writeln('  ${i + 1}. ${a['title']}: ${a['summary']} Objetivo: ${a['goal']}. Giro: ${a['twist']}$mark');
      }
    }
    final secrets = bible['secrets'];
    if (secrets is List && secrets.isNotEmpty) b.writeln('Secretos: ${secrets.join(' | ')}');
    final clues = bible['clues'];
    if (clues is List && clues.isNotEmpty) b.writeln('Pistas a sembrar: ${clues.join(' | ')}');
    final endings = bible['endings'];
    if (endings is List && endings.isNotEmpty) b.writeln('Finales posibles: ${endings.join(' | ')}');

    b.writeln();
    b.writeln('=== JUGADORES ===');
    for (final p in players) {
      final ch = p.characterName.isEmpty ? '(personaje sin nombre)' : p.characterName;
      b.writeln('- ${p.playerName} juega con $ch${p.characterSheet.isEmpty ? '' : ': ${p.characterSheet}'}');
    }

    if (npcs.isNotEmpty) {
      b.writeln();
      b.writeln('=== PNJ CONOCIDOS (usa estos nombres exactos con @) ===');
      for (final n in npcs.take(25)) {
        b.writeln('- ${n.name}${n.description.isEmpty ? '' : ': ${n.description}'}');
      }
    }

    if (c.location.isNotEmpty) {
      b.writeln();
      b.writeln('Ubicación actual: ${c.location}');
    }
    if (lastSessionSummary.isNotEmpty) {
      b.writeln();
      b.writeln('=== RESUMEN DE LA SESIÓN ANTERIOR ===');
      b.writeln(lastSessionSummary);
    }
    if (c.memory.isNotEmpty) {
      b.writeln();
      b.writeln('=== MEMORIA (lo ocurrido hasta ahora) ===');
      b.writeln(c.memory);
    }
    if (graphFacts.isNotEmpty) {
      b.writeln();
      b.writeln('=== HECHOS CONOCIDOS (grafo) ===');
      b.writeln(graphFacts);
    }
    if (ragSnippets.isNotEmpty) {
      b.writeln();
      b.writeln('=== RECUERDOS RELEVANTES ===');
      b.writeln(ragSnippets);
    }
    return b.toString();
  }

  static const campaignSchema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'setting': {'type': 'string'},
      'premise': {'type': 'string'},
      'hook': {'type': 'string'},
      'villain': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'motivation': {'type': 'string'},
          'plan': {'type': 'string'},
        },
        'required': ['name', 'motivation', 'plan'],
      },
      'acts': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'summary': {'type': 'string'},
            'goal': {'type': 'string'},
            'twist': {'type': 'string'},
          },
          'required': ['title', 'summary', 'goal', 'twist'],
        },
      },
      'npcs': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'role': {'type': 'string'},
            'personality': {'type': 'string'},
            'secret': {'type': 'string'},
            'gender': {'type': 'string', 'enum': ['hombre', 'mujer', 'otro']},
            'age': {'type': 'string', 'enum': ['niño', 'joven', 'adulto', 'anciano']},
            'voice': {'type': 'string'},
          },
          'required': ['name', 'role', 'personality', 'secret', 'gender', 'age', 'voice'],
        },
      },
      'locations': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'description': {'type': 'string'},
          },
          'required': ['name', 'description'],
        },
      },
      'factions': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'goal': {'type': 'string'},
          },
          'required': ['name', 'goal'],
        },
      },
      'secrets': {'type': 'array', 'items': {'type': 'string'}},
      'clues': {'type': 'array', 'items': {'type': 'string'}},
      'endings': {'type': 'array', 'items': {'type': 'string'}},
      'opening': {'type': 'string'},
    },
    'required': [
      'title', 'setting', 'premise', 'hook', 'villain', 'acts', 'npcs', 'locations', 'factions', 'secrets', 'clues',
      'endings', 'opening',
    ],
  };

  static String campaignRequest({
    required String theme,
    required String tone,
    required int acts,
    required String ideas,
    required List<CampaignPlayer> players,
    String title = '',
  }) {
    final ps = players
        .map((p) => '${p.playerName} (${p.characterName.isEmpty ? 'personaje por definir' : p.characterName}'
            '${p.characterSheet.isEmpty ? '' : ', ${p.characterSheet}'})')
        .join('; ');
    return '''
Diseña una campaña de rol COMPLETA y COMPLEJA en español.
- Género/tema: $theme
- Tono: $tone
- Número de actos: $acts
${title.isEmpty ? '' : '- Título deseado: $title\n'}- Jugadores y personajes: $ps
- Ideas del grupo: ${ideas.isEmpty ? '(libre)' : ideas}

Requisitos: un antagonista con motivación comprensible, $acts actos con objetivo y giro argumental cada uno, entre 5 y 8 PNJ memorables (cada uno con secreto y una descripción breve de su voz), 4-6 lugares, 2-3 facciones con intereses en conflicto, secretos, pistas que conduzcan a ellos, varios finales posibles según lo que hagan los jugadores, y una escena de apertura ("opening") de 150-250 palabras que enganche a los personajes de los jugadores. Teje los trasfondos de los personajes en la trama.
''';
  }

  static String summarizeRequest(String transcript) => '''
Resume lo ocurrido en esta parte de la partida para la memoria del director: decisiones de los jugadores, PNJ conocidos y su actitud, pistas descubiertas, objetos obtenidos, heridas, deudas, promesas y cabos sueltos. Usa viñetas concisas en español. No inventes nada.

$transcript''';

  static String sessionSummaryRequest(String transcript) => '''
Escribe el resumen de esta sesión de rol en español, en 2-4 párrafos, como el "anteriormente en..." que se leerá al empezar la próxima sesión. Termina con una línea "Situación actual:" que describa dónde están los personajes y qué tienen pendiente.

$transcript''';

  static String transcript(List<ChatMessage> msgs) => msgs
      .where((m) => m.role != MessageRole.system)
      .map((m) => m.role == MessageRole.player ? '[${m.speaker}] ${m.content}' : '[Director] ${m.content}')
      .join('\n\n');

  static String prettyBible(Map<String, dynamic> bible) => const JsonEncoder.withIndent('  ').convert(bible);
}
