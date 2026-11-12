import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../theme.dart';

/// Convierte un Markdown mínimo (**negrita**, *cursiva*, _cursiva_) en spans.
List<InlineSpan> markdownSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|_(.+?)_');
  var i = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
    if (m.group(1) != null) {
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.bold, color: kGold)));
    } else {
      spans.add(TextSpan(text: m.group(2) ?? m.group(3), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return spans;
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, this.onSpeak, this.showThinking = false})
      : streamingText = null,
        streamingThinking = null;

  const MessageBubble.streaming({super.key, required String text, required String thinking, this.showThinking = false})
      : message = null,
        onSpeak = null,
        streamingText = text,
        streamingThinking = thinking;

  final ChatMessage? message;
  final VoidCallback? onSpeak;
  final bool showThinking;
  final String? streamingText;
  final String? streamingThinking;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final isPlayer = m?.role == MessageRole.player;
    final isSystem = m?.role == MessageRole.system;
    final scheme = Theme.of(context).colorScheme;
    final text = m?.content ?? streamingText ?? '';
    final thinking = m?.thinking ?? streamingThinking ?? '';
    final base = Theme.of(context).textTheme.bodyLarge!.copyWith(height: 1.45);

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: isPlayer ? 560 : 860),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isPlayer
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : isSystem
                ? scheme.tertiaryContainer.withValues(alpha: 0.4)
                : kPanel,
        borderRadius: BorderRadius.circular(14),
        border: isPlayer ? null : Border.all(color: kGold.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(
            isPlayer ? (m!.speaker) : (isSystem ? m!.speaker : 'Director'),
            style: TextStyle(fontWeight: FontWeight.bold, color: isPlayer ? scheme.onPrimaryContainer : kGold),
          ),
          const Spacer(),
          if (onSpeak != null)
            InkWell(onTap: onSpeak, child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.volume_up, size: 18))),
        ]),
        if (thinking.isNotEmpty && (showThinking || m == null))
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              initiallyExpanded: m == null && showThinking,
              leading: const Icon(Icons.psychology, size: 18),
              title: Text(m == null && text.isEmpty ? 'Razonando…' : 'Razonamiento del director',
                  style: Theme.of(context).textTheme.bodySmall),
              children: [
                Text(thinking, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
        if (text.isEmpty && m == null && thinking.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
        else
          SelectableText.rich(TextSpan(style: base, children: markdownSpans(text, base))),
      ]),
    );
    return Align(alignment: isPlayer ? Alignment.centerRight : Alignment.centerLeft, child: bubble);
  }
}
