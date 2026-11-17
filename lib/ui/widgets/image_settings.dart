import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/downloader.dart';
import '../../core/settings.dart';
import '../../images/image_library.dart';
import '../../images/image_models.dart';

/// Apartado «Imágenes» de Ajustes: qué motor dibuja los retratos, cuerpos
/// enteros y escenas, el modelo local y el servicio opcional.
class ImageSettingsSection extends StatelessWidget {
  const ImageSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final lib = context.watch<ImageLibrary>();
    final s = context.read<AppServices>();
    final problem = lib.engineProblem;
    final engineId = st.imageEngine;
    final local = engineId == 'local' || (engineId.isEmpty && lib.localSupported);
    final remote = engineId == 'openai' || engineId == 'a1111';
    final mobile = Platform.isAndroid;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        leading: Icon(problem == null ? Icons.check_circle : Icons.info_outline, color: problem == null ? Colors.green : null),
        title: Text(problem ?? 'Generador listo: ${lib.engine!.label}'),
        subtitle: const Text('Dibuja el retrato y el cuerpo entero de cada personaje y las escenas de la historia. '
            'Siempre puedes poner tus propias imágenes desde la pestaña Imágenes de cada campaña.'),
      ),
      ListTile(
        title: const Text('Motor de imágenes'),
        trailing: DropdownButton<String>(
          value: const ['', 'local', 'openai', 'a1111', 'none'].contains(engineId) ? engineId : '',
          items: const [
            DropdownMenuItem(value: '', child: Text('Automático')),
            DropdownMenuItem(value: 'local', child: Text('En este equipo')),
            DropdownMenuItem(value: 'openai', child: Text('Servicio (API OpenAI)')),
            DropdownMenuItem(value: 'a1111', child: Text('Servidor A1111/Forge')),
            DropdownMenuItem(value: 'none', child: Text('Sólo a mano')),
          ],
          onChanged: (v) => st.imageEngine = v ?? '',
        ),
      ),
      if (local) ...[
        if (!lib.localSupported)
          const ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('Esta versión de la app no trae el generador local'),
            subtitle: Text('Usa la última versión compilada o elige un servicio.'),
          ),
        for (final m in imageModelPresets)
          Card(
            child: ListTile(
              title: Text(m.label + ((m.target == 'móvil') == mobile ? '  · recomendado aquí' : '')),
              subtitle: Text('${m.description}\n${m.sizeGb.toStringAsFixed(1)} GB · ${m.target}'),
              isThreeLine: true,
              trailing: _presetAction(context, lib, st, m, s),
            ),
          ),
        if (lib.downloadProgress != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: lib.downloadProgress),
              Text('Descargando ${lib.downloadLabel} · ${(lib.downloadProgress! * 100).toStringAsFixed(0)} %'),
            ]),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Usar un modelo propio (.gguf / .safetensors)'),
          subtitle: Text(st.sdModel.isEmpty ? 'SD 1.5, SDXL, SD-Turbo… de un solo fichero' : p.basename(st.sdModel)),
          onTap: () async {
            final f = await FilePicker.pickFile(dialogTitle: 'Modelo de imágenes');
            final path = f?.path;
            if (path == null) return;
            st
              ..sdModel = s.dataRoot.toStored(path)
              ..sdVae = ''
              ..sdLlm = ''
              ..sdSteps = 20
              ..sdCfg = 7.0;
          },
        ),
        ListTile(
          title: const Text('Pasos'),
          subtitle: Text('${st.sdSteps} (más pasos = más detalle y más lento)'),
          trailing: SizedBox(
            width: 180,
            child: Slider(value: st.sdSteps.toDouble().clamp(1, 40), min: 1, max: 40, divisions: 39, onChanged: (v) => st.sdSteps = v.round()),
          ),
        ),
        if (!mobile)
          SwitchListTile(
            title: const Text('Ahorrar memoria de vídeo'),
            subtitle: const Text('Más lento, pero funciona con gráficas de 4-6 GB'),
            value: st.sdLowVram,
            onChanged: (v) => st.sdLowVram = v,
          ),
      ],
      if (remote || engineId == 'openai' || engineId == 'a1111') ...[
        _textTile(
          context,
          engineId == 'a1111' ? 'Dirección del servidor (p. ej. http://192.168.1.20:7860)' : 'Dirección del servicio (p. ej. https://api.openai.com)',
          st.imageApiUrl,
          (v) => st.imageApiUrl = v.trim(),
        ),
        if (engineId == 'openai') ...[
          _textTile(context, 'Clave de la API (se guarda sólo en este equipo)', st.imageApiKey, (v) => st.imageApiKey = v.trim(), secret: true),
          _textTile(context, 'Modelo (p. ej. gpt-image-1; vacío = el del servicio)', st.imageApiModel, (v) => st.imageApiModel = v.trim()),
        ],
      ],
      if (engineId != 'none') ...[
        _textTile(context, 'Estilo de todas las imágenes', st.imageStyle, (v) => st.imageStyle = v.trim(), multiline: true),
        SwitchListTile(
          title: const Text('Dibujar sola cada escena nueva al jugar'),
          subtitle: const Text('Cuando el grupo llega a un lugar sin imagen, se genera en segundo plano'),
          value: st.imageAuto,
          onChanged: (v) => st.imageAuto = v,
        ),
        if (!mobile)
          SwitchListTile(
            title: const Text('Imágenes grandes'),
            subtitle: const Text('1024 px de lado largo en vez de 768: más detalle, el doble de lento'),
            value: st.imageLarge,
            onChanged: (v) => st.imageLarge = v,
          ),
      ],
    ]);
  }

  Widget _presetAction(BuildContext context, ImageLibrary lib, AppSettings st, ImageModelPreset m, AppServices s) {
    final installed = lib.presetInstalled(m);
    final selected = installed && st.sdModel == s.dataRoot.toStored(p.join(s.dataRoot.imageModels, m.files.firstWhere((f) => f.role == 'model').name));
    if (selected) return const Icon(Icons.check, color: Colors.green);
    if (installed) return FilledButton.tonal(onPressed: () => lib.usePreset(m), child: const Text('Usar'));
    return FilledButton.tonal(
      onPressed: lib.downloadProgress != null
          ? null
          : () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await lib.installPreset(m);
                messenger.showSnackBar(SnackBar(content: Text('${m.label} listo')));
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('No se pudo descargar: ${ResumableDownloader.describe(e)}')));
              }
            },
      child: const Text('Descargar'),
    );
  }

  Widget _textTile(BuildContext context, String label, String value, ValueChanged<String> onSave, {bool secret = false, bool multiline = false}) {
    return ListTile(
      title: Text(label),
      subtitle: Text(value.isEmpty ? '(vacío)' : (secret ? '•' * value.length.clamp(4, 12) : value), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.edit, size: 18),
      onTap: () async {
        final ctrl = TextEditingController(text: value);
        final v = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(label),
            content: TextField(controller: ctrl, autofocus: true, obscureText: secret, minLines: 1, maxLines: multiline ? 4 : 1),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
            ],
          ),
        );
        if (v != null) onSave(v);
      },
    );
  }
}
