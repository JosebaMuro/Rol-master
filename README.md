# Director de Rol

Director de partidas de rol con IA que funciona **en local**, sin servidores ni suscripciones, en **Android (APK)** y **Windows (EXE)**.

La IA inventa campañas completas, narra, interpreta a los PNJ con **voces distintas**, recuerda lo ocurrido entre sesiones (memoria resumida + **RAG** + **grafo de conocimiento**), sugiere música de tu biblioteca, genera **mapas** que se ven a pantalla completa y guarda un **registro** de cada partida organizado por jugador y por tema.

## Qué hace

| Función | Cómo |
| --- | --- |
| Historias completas y complejas | Al crear una campaña la IA escribe una "biblia": premisa, gancho, antagonista con motivación y plan, actos con objetivo y giro, PNJ con secretos, lugares, facciones, pistas y varios finales. El director la sigue acto a acto. |
| Razonamiento | Modelos Qwen3 con modo *thinking*: el director planifica la escena (coherencia, reglas, pistas) antes de narrar. Se puede activar/desactivar y ver el razonamiento. |
| Voces de PNJ | Cada PNJ recibe una voz propia según su género, edad y timbre. Dos motores: TTS del sistema (Windows/Android, variando voz, tono y velocidad) o voces neuronales locales **sherpa-onnx** (Piper, Kokoro con 53 voces). Se editan y prueban en *PNJ y voces*. |
| Continuar la última sesión | Todo se guarda en SQLite. Al terminar una sesión se escribe un resumen; la siguiente empieza con un "Anteriormente…". Si la app se cierra a mitad, se continúa la misma sesión. |
| Memoria larga | Resumen acumulado (compactación automática) + **RAG** híbrido (embeddings EmbeddingGemma + BM25) + **grafo** de entidades y relaciones que la IA actualiza en cada turno. Puedes importar lore (.txt/.md) y editar el grafo. |
| Música por situaciones | Biblioteca propia (mp3/ogg/wav/flac…) asignada a situaciones (Combate, Taberna, Misterio…, editables). Menú de situaciones para elegir qué suena; la IA sólo **sugiere** (opcionalmente puede ponerla sola). Fundido cruzado y bajada de volumen cuando hablan las voces. Importar una carpeta con subcarpetas con nombre de situación las asigna solas. |
| Mapas | Mazmorras, criptas simétricas y cuevas procedurales en estilo pergamino, con salas numeradas y leyenda escrita por la IA. Se generan solos cuando el director entra en un lugar (`[[mapa: …]]`) o a mano. Visor a pantalla completa con zoom. |
| Registro de partidas | Pestaña *Registro* por jugador y por tema, lector de sesiones, exportación a Markdown y preguntas a la IA sobre partidas pasadas ("¿qué nos dijo el herrero en la sesión 2?"). Además se escribe en `Documentos/DirectorDeRol/logs/<Jugador>/<Tema>/<Campaña>/sesion-NN.md`. |

## Motores de inferencia incluidos

- **llama.cpp** (vía [llamadart](https://pub.dev/packages/llamadart)) para el texto y los embeddings:
  - Windows x64: CPU (AVX2/AVX-512) + **Vulkan** (GPU NVIDIA, AMD e Intel). CUDA opcional (ver abajo).
  - Android arm64: CPU ARM optimizada (NEON, dotprod, i8mm) + **Vulkan** (experimental, se elige en Ajustes).
- **sherpa-onnx** (ONNX Runtime) para las voces neuronales, en CPU de móvil y PC.
- TTS del sistema como alternativa sin descargas.

## Modelos recomendados

| Modelo | Tamaño | Dónde |
| --- | --- | --- |
| Qwen3 1.7B Q4_K_M | 1,1 GB | Móviles de gama media (4 GB RAM) |
| Qwen3 4B Q4_K_M | 2,5 GB | Móviles de gama alta y PC (recomendado) |
| Qwen3 8B Q4_K_M | 5 GB | PC con GPU |
| Qwen3 14B Q4_K_M | 9 GB | PC con GPU de 12 GB o más |
| EmbeddingGemma 300M | 0,3 GB | Memoria semántica (opcional) |

Se descargan desde la app (Ajustes → *Usar*) la primera vez y quedan en caché. También puedes cargar cualquier `.gguf` propio o una URL `hf://`.

## Primeros pasos

1. Instala el APK (Android) o ejecuta el instalador `DirectorDeRol-windows-x64-setup.exe` (Windows).
2. **Ajustes** → elige un modelo → *Usar* (espera a la descarga).
3. Opcional: activa la memoria semántica, descarga voces neuronales, añade tu música en **Música**.
4. **Campañas** → *Nueva campaña* → tema, tono, jugadores y personajes → *Que la IA invente la campaña*.
5. *Empezar partida*. Escribe lo que hacen los personajes; usa 🎲 para tiradas, 🎵 para la música, 🗺️ para mapas y 🏁 para terminar la sesión.

## Compilar

Requisitos: Flutter 3.50 (stable).

```bash
flutter pub get
flutter test
flutter build apk --release --target-platform android-arm64   # APK
flutter build windows --release                                # EXE (en Windows)
```

La primera compilación descarga los binarios nativos de llama.cpp (no hace falta compilador de C++).

El workflow `.github/workflows/build.yml` compila ambos en GitHub Actions en cada push a `main` (artefactos descargables) y publica una *release* con el APK, el instalador EXE y un ZIP portable cuando se sube una etiqueta `v*`. Al lanzarlo a mano (*Run workflow*) se puede marcar **CUDA** para incluir ese backend en Windows.

## Estructura

```
lib/
  ai/            motor (llama_service), director, generador de campañas, prompts, parser
  ai/memory/     RAG, grafo de conocimiento, extractor de hechos
  voice/         TTS del sistema + sherpa-onnx, paquetes de voces
  music/         biblioteca y reproductor por situaciones
  maps/          generador procedimental y renderizado a PNG
  logs/          registro en Markdown
  core/          base de datos SQLite, modelos y ajustes
  ui/            pantallas
test/            pruebas (director, memoria, mapas, parser)
```

## Formato que usa el director

- Diálogo de PNJ: una línea `@Nombre: lo que dice` (así se asigna su voz).
- Etiquetas ocultas: `[[musica: Combate]]`, `[[mapa: cueva | Gruta del Eco]]`, `[[tirada: Sigilo CD 14]]`, `[[lugar: …]]`, `[[acto: 2]]`.
