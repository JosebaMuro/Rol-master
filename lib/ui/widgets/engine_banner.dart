import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ai/llama_service.dart';

/// Franja superior con el estado del motor de IA (descarga, carga, errores).
class EngineBanner extends StatelessWidget {
  const EngineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final llm = context.watch<LlamaService>();
    if (llm.status == EngineStatus.ready) return const SizedBox.shrink();
    final color = switch (llm.status) {
      EngineStatus.error => Colors.red.shade900,
      EngineStatus.empty => Colors.brown.shade800,
      _ => Colors.blueGrey.shade800,
    };
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(llm.message, style: const TextStyle(fontSize: 13)),
            if (llm.status == EngineStatus.downloading || llm.status == EngineStatus.loading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(value: llm.progress),
              ),
          ],
        ),
      ),
    );
  }
}
