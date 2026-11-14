# Director de Rol

Director de partidas de rol con IA que funciona **en local**, sin servidores ni suscripciones, en **Android (APK)** y **Windows (EXE)**.

La IA inventa campañas completas, narra, interpreta a los PNJ con **voces distintas**, recuerda lo ocurrido entre sesiones (memoria resumida + **RAG** + **grafo de conocimiento**), sugiere música de tu biblioteca, genera **mapas** que se ven a pantalla completa y guarda un **registro** de cada partida organizado por jugador y por tema.

## Qué hace

| Función | Cómo |
| --- | --- |
| Historias completas y complejas | Al crear una campaña la IA escribe una "biblia": premisa, gancho, antagonista con motivación y plan, actos con objetivo y giro, PNJ con secretos, lugares, facciones, pistas y varios finales. El director la sigue acto a acto. |
| Razonamiento | Modelos Qwen3 con modo *thinking*: el director planifica la escena (coherencia, reglas, pistas) antes de narrar. Se puede activar/desactivar y ver el razonamiento. |
| Voces de PNJ | Cada PNJ recibe una voz propia según su género, edad y timbre. Dos motores: TTS del sistema (Windows con las voces de Configuración › Voz, Android con TextToSpeech; variando voz, tono y velocidad) o voces neuronales locales **sherpa-onnx** (Piper, Kokoro con 53 voces). Se editan y prueban en *PNJ y voces*. |
| Continuar la última sesión | Todo se guarda en SQLite. Al terminar una sesión se escribe un resumen; la siguiente empieza con un "Anteriormente…". Si la app se cierra a mitad, se continúa la misma sesión. |
| Memoria larga | Resumen acumulado (compactación automática) + **RAG** híbrido (embeddings EmbeddingGemma + BM25) + **grafo** de entidades y relaciones que la IA actualiza en cada turno. Puedes importar lore (.txt/.md) y editar el grafo. |
| Música por situaciones | Biblioteca propia (mp3/ogg/wav/flac…) asignada a situaciones (Combate, Taberna, Misterio…, editables). Menú de situaciones para elegir qué suena; la IA sólo **sugiere** (opcionalmente puede ponerla sola). Fundido cruzado y bajada de volumen cuando hablan las voces. Importar una carpeta con subcarpetas con nombre de situación las asigna solas. |
| Estado de juego que lleva la app | Cada personaje tiene su **ficha** (PV, objetos, oro, estados y modificadores de tirada). El director sólo **propone** cambios con etiquetas (`[[pv: Kael -4]]`, `[[objeto: Mira +Llave]]`…) y la app los aplica; el estado real entra en cada prompt, así la IA no "olvida" heridas ni objetos. Botón *Fichas* en la partida para verlas y corregirlas. |
| Tiradas que resuelve la app | Cuando el director pide `[[tirada: Kael \| Percepción CD 15]]`, aparece una ficha: al tocarla la app tira d20 + el modificador del personaje contra la CD y le envía el resultado con su grado (pifia, fallo, éxito por los pelos, éxito, crítico). Mantener pulsado = tirar a mano. |
| Grafo con caducidad | Los hechos dejan de ser ciertos: si alguien cambia de sitio, entrega un objeto o muere, el hecho antiguo pasa a *pasado* (con la sesión) en vez de contradecir al nuevo. El archivista de la IA también marca lo que ya no es verdad. En el grafo se ven tachados. |
| Recuerdos fijados y asuntos pendientes | Chincheta en cualquier mensaje para que el director lo tenga **siempre** presente. Registro de promesas, deudas, amenazas, misiones y pistas que la IA abre y cierra sola (y tú puedes editar). Botón *Mundo* 🌐 en la partida. |
| El mundo avanza solo | El villano y cada facción tienen un **reloj** (tramas en marcha) que tira dados cada pocos turnos y avanza aunque el grupo no haga nada; si se llena, ocurre su consecuencia y el director la muestra. Postura del grupo ante cada trama y **saltos de tiempo** ("tres semanas después"). |
| PNJ vivos | Cada PNJ tiene un **objetivo**, una **actitud** hacia el grupo (de −3 enemigo a +3 leal) y recuerda **sólo lo que ha presenciado**. La IA los actualiza tras cada turno; se ajustan en *PNJ y voces*. |
| Jugar hablando | Botón 🎤 en la partida: hablas, vuelves a pulsar y el texto aparece en la caja. Reconocimiento **local** con Whisper (sherpa-onnx), modelos tiny/base/small descargables en Ajustes. |
| Mapas | Mazmorras, criptas simétricas, cuevas, **ruinas** (Wave Function Collapse) y **pueblos amurallados** (calles, plaza, casas, río con puentes, campos) en estilo pergamino, con salas numeradas y leyenda escrita por la IA. Se generan solos cuando el director entra en un lugar (`[[mapa: …]]`) o a mano. Visor a pantalla completa con zoom. |
| Registro de partidas | Pestaña *Registro* por jugador y por tema, lector de sesiones, exportación a Markdown y preguntas a la IA sobre partidas pasadas ("¿qué nos dijo el herrero en la sesión 2?"). Además se escribe en `datos/registros/<Jugador>/<Tema>/<Campaña>/sesion-NN.md`. |
| Pantalla de partida | Arriba, un panel de imagen; abajo, el texto, a media pantalla cada uno. Asignas una imagen de fondo a cada tipo de lugar (mazmorra, cripta, cueva, castillo, ciudad, taberna, templo, bosque…) y cambia sola cuando el director cambia de lugar (`[[escena: …]]`). También se puede fijar una escena a mano o ver ahí el mapa generado. El panel se oculta con un botón. |
| Documentación que aprende | Pestaña **Docs**: añade reglamentos, ambientaciones, módulos o apuntes (PDF, Word, EPUB, ODT, HTML, RTF, TXT, Markdown…), para todas las campañas o sólo para una. La IA los trocea en su memoria (RAG): el director los consulta en cada turno y al crear campañas, y puedes preguntarles directamente. Igual en Windows y Android, sin Internet; las copias quedan en `datos/documentos`. |
| Exportar e importar historias | Menú ⋮ de la campaña → *Exportar historia* (con las partidas jugadas o sin jugar, para que otro grupo la empiece) a un único fichero `.rolpack`. En **Campañas** → 📂 se importa como una campaña nueva, con biblia, PNJ y voces, grafo, memoria, mapas y sesiones. |

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

## Carpeta portable

Todo lo que usa la app vive en **una sola carpeta**, `datos`:

```
datos/
  director.db      campañas, sesiones, PNJ, memoria, música, mapas
  ajustes.json     ajustes
  modelos/         modelos .gguf (descargados o copiados)
  voces/           voces neuronales
  musica/<Situación>/  copias de tus pistas, ordenadas por situación
  fondos/          imágenes de fondo de cada tipo de lugar
  documentos/      copias de la documentación que ha aprendido la IA
  mapas/           imágenes de los mapas
  registros/       registros de partida en Markdown
  exportaciones/   historias .rolpack y registros exportados
```

- **Windows:** `datos` está junto a `director_de_rol.exe`. Con el ZIP portable o el instalador (que instala en tu usuario, `%LOCALAPPDATA%\Programs\Director de Rol`) basta con copiar la carpeta del programa a otro PC o a un USB para llevártelo todo. Si la carpeta del programa no se puede escribir (p. ej. en *Archivos de programa*), se usa `Documentos\DirectorDeRol`.
- **Android:** `Android/data/<paquete>/files/DirectorDeRol`, visible desde el PC por USB.

Las rutas se guardan relativas a `datos`, así que mover la carpeta no rompe nada. La ruta actual se ve en Ajustes.

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
  ai/memory/     RAG, grafo de conocimiento (con caducidad), extractor de hechos
  game/          dados y tiradas, fichas (estado de juego), relojes del mundo
  voice/         TTS del sistema + sherpa-onnx, paquetes de voces, reconocimiento de voz (Whisper)
  music/         biblioteca y reproductor por situaciones
  maps/          generadores (mazmorra, cripta, cueva, ruinas WFC, pueblo) y renderizado a PNG
  logs/          registro en Markdown
  core/          base de datos SQLite, modelos y ajustes
  ui/            pantallas
test/            pruebas (director, memoria, juego, mapas, parser)
```

## Formato que usa el director

- Diálogo de PNJ: una línea `@Nombre: lo que dice` (así se asigna su voz).
- Etiquetas ocultas: `[[musica: Combate]]`, `[[mapa: cueva | Gruta del Eco]]`, `[[tirada: Kael | Sigilo CD 14]]`, `[[lugar: …]]`, `[[acto: 2]]`.
- Estado (lo aplica la app): `[[pv: Kael -4]]`, `[[objeto: Mira +Llave negra]]`, `[[oro: Kael +20]]`, `[[estado: Kael +envenenado]]`, `[[actitud: Bran +1]]`, `[[pendiente: promesa | …]]`, `[[resuelto: …]]`, `[[tiempo: 3 días]]`.
