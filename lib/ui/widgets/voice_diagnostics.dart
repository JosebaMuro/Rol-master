import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../voice/voice_service.dart';

/// Ejecuta el diagnóstico de voces y muestra un informe que se puede copiar.
Future<void> showVoiceDiagnostics(BuildContext context, VoiceService voices) {
  return showDialog<void>(context: context, builder: (_) => _VoiceDiagnosticsDialog(voices));
}

class _VoiceDiagnosticsDialog extends StatefulWidget {
  const _VoiceDiagnosticsDialog(this.voices);
  final VoiceService voices;

  @override
  State<_VoiceDiagnosticsDialog> createState() => _VoiceDiagnosticsDialogState();
}

class _VoiceDiagnosticsDialogState extends State<_VoiceDiagnosticsDialog> {
  String _step = 'Preparando…';
  String? _report;

  @override
  void initState() {
    super.initState();
    widget.voices.diagnose(onStep: (s) {
      if (mounted) setState(() => _step = s);
    }).then((r) {
      if (mounted) setState(() => _report = r);
    }, onError: (Object e) {
      if (mounted) setState(() => _report = 'El diagnóstico falló: $e\n\n${widget.voices.log.join('\n')}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return AlertDialog(
      title: const Text('Diagnóstico de voces'),
      content: SizedBox(
        width: 560,
        child: r == null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(_step),
                const SizedBox(height: 8),
                const Text('Escucha: primero un pitido, luego la voz del sistema y después cada voz neuronal.'),
              ])
            : SingleChildScrollView(
                child: SelectableText(r, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
      ),
      actions: [
        if (r != null)
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: r));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe copiado')));
            },
          ),
        TextButton(
          onPressed: () {
            widget.voices.stop();
            Navigator.pop(context);
          },
          child: Text(r == null ? 'Cancelar' : 'Cerrar'),
        ),
      ],
    );
  }
}
