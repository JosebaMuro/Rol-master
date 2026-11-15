import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../ai/llama_service.dart';
import '../ai/model_catalog.dart';
import '../app_services.dart';
import '../core/scenes.dart';
import '../core/settings.dart';
import '../voice/speech_input.dart';
import '../voice/voice_packs.dart';
import '../voice/voice_service.dart';
import 'widgets/image_settings.dart';
import 'widgets/file_utils.dart';
import 'widgets/scene_panel.dart';
import 'widgets/voice_diagnostics.dart';
import 'widgets/voice_editor.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final llm = context.watch<LlamaService>();
    final packs = context.watch<VoicePackManager>();
    final speech = context.watch<SpeechInput>();
    final s = context.read<AppServices>();
    final t = Theme.of(context).textTheme;

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(text, style: t.titleLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        header('Motor de IA (local)'),
        ListTile(
          leading: Icon(llm.isReady ? Icons.check_circle : Icons.info_outline, color: llm.isReady ? Colors.green : null),
          title: Text(llm.isReady ? 'Modelo cargado' : llm.message),
          subtitle: Text(
            llm.isReady ? '${p.basename(llm.loadedModel)}\n${llm.backendName}' : LlamaService.platformHint(),
          ),
        ),
        for (final m in chatPresets)
          Card(
            child: ListTile(
              title: Text(m.label),
              subtitle: Text('${m.description}\n${m.sizeGb} GB · RAM ≥ ${m.minRamGb} GB · ${m.target}${m.reasoning ? ' · razona' : ''}'),
              isThreeLine: true,
              trailing: llm.loadedModel == m.uri && llm.isReady
                  ? const Icon(Icons.check, color: Colors.green)
                  : FilledButton.tonal(
                      onPressed: llm.status == EngineStatus.downloading || llm.status == EngineStatus.loading
                          ? null
                          : () => llm.loadChatModel(m.uri),
                      child: const Text('Usar'),
                    ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Usar un .gguf de mi equipo'),
              onPressed: () async {
                final f = await FilePicker.pickFile(type: FileType.any);
                if (f == null) return;
                final picked = await localPathFor(f, s.dataRoot.models);
                if (picked == null) return;
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copiando el modelo a la carpeta de la app…')),
                  );
                }
                // Se copia a datos/modelos para que viaje con la app.
                final path = await s.dataRoot.adopt(picked, s.dataRoot.models);
                llm.loadChatModel(path);
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('Otro modelo (hf:// o URL)'),
              onPressed: () async {
                final ctrl = TextEditingController(text: 'hf://');
                final uri = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Modelo GGUF'),
                    content: TextField(
                      controller: ctrl,
                      decoration: const InputDecoration(helperText: 'hf://usuario/repositorio/fichero.gguf o https://…'),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Cargar')),
                    ],
                  ),
                );
                if (uri != null && uri.length > 6) llm.loadChatModel(uri);
              },
            ),
          ]),
        ),
        ListTile(
          title: const Text('Dispositivo de cálculo'),
          subtitle: const Text('Auto elige GPU en PC (Vulkan) y CPU en móvil'),
          trailing: DropdownButton<String>(
            value: st.device,
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Auto')),
              DropdownMenuItem(value: 'gpu', child: Text('GPU')),
              DropdownMenuItem(value: 'cpu', child: Text('CPU')),
            ],
            onChanged: (v) => st.device = v!,
          ),
        ),
        ListTile(
          title: const Text('Backend de GPU'),
          subtitle: const Text('Vulkan: NVIDIA/AMD/Intel y móviles compatibles'),
          trailing: DropdownButton<String>(
            value: st.backend,
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Auto')),
              DropdownMenuItem(value: 'vulkan', child: Text('Vulkan')),
              DropdownMenuItem(value: 'cuda', child: Text('CUDA')),
              DropdownMenuItem(value: 'opencl', child: Text('OpenCL')),
              DropdownMenuItem(value: 'cpu', child: Text('CPU')),
            ],
            onChanged: (v) => st.backend = v!,
          ),
        ),
        _sliderTile('Capas en GPU', st.gpuLayers.toDouble(), 0, 99, (v) => st.gpuLayers = v.round(), divisions: 99),
        _sliderTile('Contexto (tokens)', st.contextSize.toDouble(), 2048, 32768, (v) => st.contextSize = (v / 1024).round() * 1024,
            divisions: 30),
        _sliderTile('Creatividad (temperatura)', st.temperature, 0.2, 1.4, (v) => st.temperature = v),
        _sliderTile('Longitud máx. respuesta', st.maxTokens.toDouble(), 200, 2000, (v) => st.maxTokens = v.round(), divisions: 18),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Los cambios de dispositivo, backend o contexto se aplican al volver a cargar el modelo.',
              style: TextStyle(fontSize: 12)),
        ),
        SwitchListTile(
          title: const Text('Razonamiento antes de narrar'),
          subtitle: const Text('El director piensa (plan, coherencia, reglas) antes de responder. Más lento, más coherente.'),
          value: st.thinking,
          onChanged: (v) => st.thinking = v,
        ),
        if (st.thinking)
          _sliderTile('Presupuesto de razonamiento', st.thinkingBudget.toDouble(), 128, 4096, (v) => st.thinkingBudget = v.round(),
              divisions: 31),
        SwitchListTile(
          title: const Text('Mostrar el razonamiento'),
          value: st.showThinking,
          onChanged: (v) => st.showThinking = v,
        ),

        header('Memoria semántica (RAG)'),
        ListTile(
          title: const Text('Modelo de embeddings'),
          subtitle: Text(llm.canEmbed
              ? 'Activo: ${p.basename(llm.loadedEmbedModel)}'
              : 'Sin modelo: se usa búsqueda léxica (BM25). Con embeddings la memoria entiende sinónimos.'),
          trailing: llm.canEmbed
              ? TextButton(onPressed: llm.unloadEmbedModel, child: const Text('Quitar'))
              : FilledButton.tonal(
                  onPressed: llm.embedStatus == EngineStatus.downloading ? null : () => llm.loadEmbedModel(embedPresets.first.uri),
                  child: Text(llm.embedStatus == EngineStatus.downloading ? 'Cargando…' : 'Activar (330 MB)'),
                ),
        ),

        header('Voces'),
        SwitchListTile(title: const Text('Voces activadas'), value: st.voiceEnabled, onChanged: (v) => st.voiceEnabled = v),
        ListTile(
          leading: const Icon(Icons.troubleshoot),
          title: const Text('Diagnóstico de voces'),
          subtitle: const Text('Prueba el altavoz, la voz del sistema y las neuronales, y da un informe para copiar'),
          onTap: () => showVoiceDiagnostics(context, context.read<VoiceService>()),
        ),
        SwitchListTile(
          title: const Text('Leer también la narración'),
          subtitle: const Text('Si está apagado, sólo hablan los PNJ'),
          value: st.narrateNarration,
          onChanged: (v) => st.narrateNarration = v,
        ),
        ListTile(
          title: const Text('Motor para PNJ nuevos'),
          trailing: DropdownButton<String>(
            value: st.defaultVoiceEngine,
            items: const [
              DropdownMenuItem(value: 'system', child: Text('Sistema')),
              DropdownMenuItem(value: 'neural', child: Text('Neuronal local')),
            ],
            onChanged: (v) => st.defaultVoiceEngine = v!,
          ),
        ),
        if (st.defaultVoiceEngine == 'neural' && packs.installed.isNotEmpty)
          ListTile(
            title: const Text('Paquete por defecto'),
            trailing: DropdownButton<String>(
              value: packs.byId(st.defaultNeuralPack) != null ? st.defaultNeuralPack : packs.installed.first.id,
              items: [for (final x in packs.installed) DropdownMenuItem(value: x.id, child: Text(x.id))],
              onChanged: (v) => st.defaultNeuralPack = v!,
            ),
          ),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.campaign),
            title: const Text('Voz del narrador'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              VoiceEditor(
                voice: st.narratorVoice,
                sample: 'La niebla cubre el valle mientras las campanas de la abadía doblan a muerto.',
                onChanged: (v) => st.narratorVoice = v,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Voces neuronales (sherpa-onnx, funcionan sin Internet). Las marcadas con ✓ vienen con la app.'),
        ),
        ListenableBuilder(
          listenable: s.bundled,
          builder: (context, _) {
            final b = s.bundled;
            if (!b.busy && b.error == null) return const SizedBox.shrink();
            return ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(b.busy ? 'Preparando las voces incluidas…' : b.error!),
              subtitle: b.busy ? LinearProgressIndicator(value: b.progress) : const Text('Se reintentará al abrir la app'),
            );
          },
        ),
        for (final info in voicePackCatalog) _packTile(context, packs, info),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.archive),
            label: const Text('Instalar paquete desde archivo .tar.bz2'),
            onPressed: () async {
              final f = await FilePicker.pickFile(type: FileType.any);
              if (f == null) return;
              final path = await localPathFor(f, s.dataRoot.tmp);
              if (path != null) {
                await packs.installFromFile(path, f.name.contains('kokoro') ? 'kokoro' : 'vits');
              }
            },
          ),
        ),

        header('Jugar hablando'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Pulsa el micrófono en la partida, habla y vuelve a pulsar: el texto aparece en la caja para '
              'revisarlo. El reconocimiento es local (Whisper con sherpa-onnx), sin Internet una vez descargado.'),
        ),
        for (final info in speechModelCatalog) _speechTile(speech, st, info),
        SwitchListTile(
          title: const Text('Enviar al director nada más reconocer la voz'),
          subtitle: const Text('Apagado: el texto queda en la caja para corregirlo antes de enviar'),
          value: st.speechAutoSend,
          onChanged: (v) => st.speechAutoSend = v,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.archive),
            label: const Text('Instalar modelo desde archivo .tar.bz2'),
            onPressed: () async {
              final f = await FilePicker.pickFile(type: FileType.any);
              if (f == null) return;
              final path = await localPathFor(f, s.dataRoot.tmp);
              if (path != null) await speech.installFromFile(path);
            },
          ),
        ),

        header('Imágenes de escenas y personajes'),
        const ImageSettingsSection(),

        header('El mundo'),
        ListTile(
          leading: const Icon(Icons.hourglass_top),
          title: const Text('El mundo avanza solo'),
          subtitle: Text(st.worldEvery == 0
              ? 'Apagado: las tramas sólo avanzan con saltos de tiempo o a mano'
              : 'Cada ${st.worldEvery} turnos las facciones y el villano tiran dados para avanzar sus planes'),
          trailing: DropdownButton<int>(
            value: [0, 2, 3, 4, 6, 8, 12].contains(st.worldEvery) ? st.worldEvery : 4,
            items: [
              for (final n in [0, 2, 3, 4, 6, 8, 12]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'Nunca' : 'Cada $n')),
            ],
            onChanged: (v) => st.worldEvery = v ?? 4,
          ),
        ),

        header('Música'),
        SwitchListTile(
          title: const Text('Poner sola la música que sugiere la IA'),
          subtitle: const Text('Apagado: la IA sólo sugiere y tú eliges en el menú de situaciones'),
          value: st.autoMusic,
          onChanged: (v) => st.autoMusic = v,
        ),
        SwitchListTile(
          title: const Text('Bajar la música cuando hablan las voces'),
          value: st.duckMusic,
          onChanged: (v) => st.duckMusic = v,
        ),

        header('Pantalla de partida'),
        SwitchListTile(
          title: const Text('Panel de imagen arriba y texto abajo'),
          subtitle: const Text('Media pantalla cada uno. El fondo cambia solo según el tipo de lugar.'),
          value: st.showScenePanel,
          onChanged: (v) => st.showScenePanel = v,
        ),
        ExpansionTile(
          leading: const Icon(Icons.wallpaper),
          title: const Text('Fondos por tipo de lugar'),
          subtitle: Text('${Scenes.kinds.where((k) => sceneBackgroundFile(s, k.id) != null).length} de ${Scenes.kinds.length} con imagen'),
          children: [
            for (final k in Scenes.kinds)
              Builder(builder: (context) {
                final f = sceneBackgroundFile(s, k.id);
                return ListTile(
                  leading: SizedBox(
                    width: 64,
                    height: 40,
                    child: f == null
                        ? Center(child: Text(k.icon, style: const TextStyle(fontSize: 24)))
                        : ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(f, fit: BoxFit.cover)),
                  ),
                  title: Text(k.name),
                  subtitle: Text(f == null ? 'Sin imagen' : p.basename(f.path)),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await pickSceneBackground(context, k);
                    } catch (e) {
                      messenger.showSnackBar(SnackBar(content: Text('No se pudo usar la imagen: $e')));
                    }
                  },
                  trailing: f == null
                      ? const Icon(Icons.add_photo_alternate)
                      : IconButton(
                          tooltip: 'Quitar',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => removeSceneBackground(s, k),
                        ),
                );
              }),
          ],
        ),

        header('Datos'),
        ListTile(
          leading: const Icon(Icons.folder),
          title: const Text('Carpeta de datos (portable)'),
          subtitle: Text(
            '${s.dataRoot.root}\n'
            'Contiene base de datos, ajustes, modelos, voces, música, mapas, registros y exportaciones. '
            'Copia la carpeta del programa (con «datos» dentro) a otro equipo o a un USB y lo tendrás todo.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.computer),
          title: const Text('Plataforma'),
          subtitle: Text('${Platform.operatingSystem} · ${Platform.numberOfProcessors} núcleos'),
        ),
      ]),
    );
  }

  Widget _packTile(BuildContext context, VoicePackManager packs, VoicePackInfo info) {
    final installed = packs.byId(info.id) != null;
    final downloading = packs.downloading.containsKey(info.id);
    final err = packs.errors[info.id];
    return ListTile(
      title: Text(info.label),
      subtitle: Text('${info.description} · ${info.sizeMb} MB${err == null ? '' : '\nError: $err'}'),
      trailing: downloading
          ? SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(value: packs.downloading[info.id]),
            )
          : packs.isBundled(info.id)
              ? const Tooltip(message: 'Incluida con la app', child: Icon(Icons.verified_outlined))
              : installed
                  ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => packs.remove(info.id))
                  : IconButton(icon: const Icon(Icons.download), onPressed: () => packs.install(info)),
    );
  }

  Widget _speechTile(SpeechInput speech, AppSettings st, SpeechModelInfo info) {
    final installed = speech.installed.contains(info.id);
    final downloading = speech.downloading.containsKey(info.id);
    final err = speech.errors[info.id];
    final active = speech.activeModel == info.id;
    return ListTile(
      leading: installed
          ? IconButton(
              tooltip: active ? 'En uso' : 'Usar este',
              icon: Icon(active ? Icons.radio_button_checked : Icons.radio_button_off),
              onPressed: () {
                st.speechModel = info.id;
                speech.select(info.id);
              },
            )
          : const Icon(Icons.mic_none),
      title: Text(info.label),
      subtitle: Text('${info.description} · ${info.sizeMb} MB${err == null ? '' : '\nError: $err'}'),
      trailing: downloading
          ? SizedBox(width: 40, height: 40, child: CircularProgressIndicator(value: speech.downloading[info.id]))
          : speech.isBundled(info.id)
              ? const Tooltip(message: 'Incluido con la app', child: Icon(Icons.verified_outlined))
              : installed
                  ? IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => speech.remove(info.id))
                  : IconButton(icon: const Icon(Icons.download), onPressed: () => speech.install(info)),
    );
  }

  Widget _sliderTile(String label, double value, double min, double max, ValueChanged<double> onChanged, {int? divisions}) {
    return ListTile(
      title: Text(label),
      subtitle: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      trailing: Text(value < 10 ? value.toStringAsFixed(2) : value.round().toString()),
    );
  }
}
