import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../core/models.dart';

/// Grafo de conocimiento: vista visual + lista editable + importación de lore
/// a la memoria RAG.
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  bool _visual = true;
  bool _showPast = false;
  Entity? _selected;

  static const typeColors = {
    'personaje': Color(0xFF4FA3D4),
    'pnj': Color(0xFFD4A84F),
    'lugar': Color(0xFF6DBE6D),
    'facción': Color(0xFFB067C9),
    'objeto': Color(0xFFE0E0E0),
    'misión': Color(0xFFE07B39),
    'criatura': Color(0xFFC94F4F),
    'evento': Color(0xFF8C9EFF),
    'otro': Color(0xFF9E9E9E),
  };

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final entities = s.db.entities(widget.campaignId);
    final all = s.db.relations(widget.campaignId);
    final relations = all.where((r) => !r.ended).toList();
    final past = all.where((r) => r.ended).toList();
    final chunks = s.db.chunkCount(widget.campaignId);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${entities.length} entidades · ${relations.length} hechos vigentes · ${past.length} pasados · $chunks recuerdos (RAG)'),
          if (!_visual)
            FilterChip(
              label: const Text('Ver hechos pasados'),
              selected: _showPast,
              onSelected: (v) => setState(() => _showPast = v),
            ),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.hub), label: Text('Grafo')),
              ButtonSegment(value: false, icon: Icon(Icons.list), label: Text('Lista')),
            ],
            selected: {_visual},
            onSelectionChanged: (v) => setState(() => _visual = v.first),
          ),
          IconButton(tooltip: 'Añadir hecho', icon: const Icon(Icons.add_link), onPressed: () => _addFact(s)),
          IconButton(tooltip: 'Importar lore (txt/md) a la memoria', icon: const Icon(Icons.upload_file), onPressed: () => _importLore(s)),
          if (s.llm.canEmbed)
            IconButton(
              tooltip: 'Calcular embeddings pendientes',
              icon: const Icon(Icons.bolt),
              onPressed: () async {
                final n = await s.rag.backfill(widget.campaignId);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n recuerdos indexados')));
                }
              },
            ),
        ]),
      ),
      Expanded(
        child: entities.isEmpty
            ? const Center(child: Text('El grafo se irá llenando a medida que jugáis.'))
            : _visual
                ? _GraphView(
                    entities: entities,
                    relations: relations,
                    selected: _selected,
                    onSelect: (e) => setState(() => _selected = e),
                  )
                : _list(s, entities, _showPast ? all : relations),
      ),
      if (_selected != null && _visual)
        Card(
          child: ListTile(
            title: Text('${_selected!.name} · ${_selected!.type}'),
            subtitle: Text(_selected!.description.isEmpty ? 'Sin descripción' : _selected!.description),
            trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _edit(s, _selected!)),
          ),
        ),
    ]);
  }

  Widget _list(AppServices s, List<Entity> entities, List<Relation> relations) {
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      for (final e in entities)
        ListTile(
          leading: CircleAvatar(backgroundColor: typeColors[e.type] ?? Colors.grey, radius: 8),
          title: Text(e.name),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text([e.type, if (e.description.isNotEmpty) e.description].join('\n')),
            for (final r in relations.where((r) => r.sourceId == e.id))
              InkWell(
                onLongPress: () {
                  // Mantener pulsado: el hecho pasa a ser pasado (o vuelve a ser cierto).
                  r.ended ? s.db.reopenRelation(r.id!) : s.db.endRelation(r.id!);
                  setState(() {});
                },
                child: Text(
                  '${r.ended ? '✗' : '→'} ${r.relation} ${r.targetName}'
                  '${r.ended ? ' (ya no${r.untilSession > 0 ? ', desde la sesión ${r.untilSession}' : ''})' : ''}',
                  style: r.ended ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.white54) : null,
                ),
              ),
          ]),
          onTap: () => _edit(s, e),
        ),
    ]);
  }

  Future<void> _edit(AppServices s, Entity e) async {
    final name = TextEditingController(text: e.name);
    final desc = TextEditingController(text: e.description);
    var type = e.type;
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Editar entidad'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: typeColors.containsKey(type) ? type : 'otro',
                items: [for (final t in typeColors.keys) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => setD(() => type = v ?? type),
              ),
              const SizedBox(height: 8),
              TextField(controller: desc, maxLines: 5, decoration: const InputDecoration(labelText: 'Descripción')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Borrar')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (res == 'save') {
      e
        ..name = name.text.trim()
        ..description = desc.text.trim()
        ..type = type;
      s.db.updateEntity(e);
    } else if (res == 'delete') {
      s.db.deleteEntity(e.id!);
      _selected = null;
    }
    setState(() {});
  }

  Future<void> _addFact(AppServices s) async {
    final a = TextEditingController(), r = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo hecho'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, decoration: const InputDecoration(labelText: 'Sujeto (p. ej. Lady Morwen)')),
          TextField(controller: r, decoration: const InputDecoration(labelText: 'Relación (p. ej. traicionó a)')),
          TextField(controller: b, decoration: const InputDecoration(labelText: 'Objeto (p. ej. la Orden del Alba)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Añadir')),
        ],
      ),
    );
    if (ok == true) {
      s.graph.addFact(widget.campaignId, a.text, r.text, b.text);
      setState(() {});
    }
  }

  Future<void> _importLore(AppServices s) async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['txt', 'md']);
    if (f == null) return;
    String text;
    final path = f.path;
    if (path != null) {
      text = await File(path).readAsString();
    } else {
      text = await f.xFile.readAsString();
    }
    final n = await s.rag.addText(widget.campaignId, 'lore · ${f.name}', text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n fragmentos añadidos a la memoria')));
      setState(() {});
    }
  }
}

class _GraphView extends StatefulWidget {
  const _GraphView({required this.entities, required this.relations, required this.selected, required this.onSelect});
  final List<Entity> entities;
  final List<Relation> relations;
  final Entity? selected;
  final ValueChanged<Entity> onSelect;

  @override
  State<_GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<_GraphView> {
  late Map<int, Offset> _pos;
  static const _size = Size(1600, 1200);

  @override
  void initState() {
    super.initState();
    _pos = _layout();
  }

  @override
  void didUpdateWidget(covariant _GraphView old) {
    super.didUpdateWidget(old);
    if (old.entities.length != widget.entities.length || old.relations.length != widget.relations.length) {
      _pos = _layout();
    }
  }

  /// Disposición por fuerzas (Fruchterman–Reingold) calculada una vez.
  Map<int, Offset> _layout() {
    final r = Random(42);
    final ids = widget.entities.map((e) => e.id!).toList();
    final pos = {for (final id in ids) id: Offset(200 + r.nextDouble() * 1200, 150 + r.nextDouble() * 900)};
    final k = sqrt(_size.width * _size.height / max(1, ids.length)) * 0.6;
    var temp = 200.0;
    for (var it = 0; it < 220; it++) {
      final disp = {for (final id in ids) id: Offset.zero};
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          var d = pos[ids[i]]! - pos[ids[j]]!;
          var dist = d.distance;
          if (dist < 0.01) {
            d = const Offset(0.1, 0.1);
            dist = 0.15;
          }
          final f = (k * k / dist);
          final v = d / dist * f;
          disp[ids[i]] = disp[ids[i]]! + v;
          disp[ids[j]] = disp[ids[j]]! - v;
        }
      }
      for (final rel in widget.relations) {
        final a = pos[rel.sourceId], b = pos[rel.targetId];
        if (a == null || b == null) continue;
        final d = a - b;
        final dist = max(d.distance, 0.01);
        final v = d / dist * (dist * dist / k);
        disp[rel.sourceId] = disp[rel.sourceId]! - v;
        disp[rel.targetId] = disp[rel.targetId]! + v;
      }
      for (final id in ids) {
        final d = disp[id]!;
        final len = max(d.distance, 0.01);
        var p = pos[id]! + d / len * min(len, temp);
        p = Offset(p.dx.clamp(60, _size.width - 60), p.dy.clamp(60, _size.height - 60));
        pos[id] = p;
      }
      temp *= 0.97;
    }
    return pos;
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      constrained: false,
      minScale: 0.2,
      maxScale: 3,
      boundaryMargin: const EdgeInsets.all(400),
      child: GestureDetector(
        onTapUp: (d) {
          for (final e in widget.entities) {
            if ((_pos[e.id]! - d.localPosition).distance < 26) {
              widget.onSelect(e);
              return;
            }
          }
        },
        child: CustomPaint(
          size: _size,
          painter: _GraphPainter(widget.entities, widget.relations, _pos, widget.selected),
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.entities, this.relations, this.pos, this.selected);
  final List<Entity> entities;
  final List<Relation> relations;
  final Map<int, Offset> pos;
  final Entity? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.4;
    for (final r in relations) {
      final a = pos[r.sourceId], b = pos[r.targetId];
      if (a == null || b == null) continue;
      final highlight = selected != null && (r.sourceId == selected!.id || r.targetId == selected!.id);
      canvas.drawLine(a, b, highlight ? (Paint()..color = const Color(0xFFD4A84F)..strokeWidth = 2.2) : edge);
      // Flecha.
      final dir = (b - a) / max((b - a).distance, 0.01);
      final tip = b - dir * 20;
      final n = Offset(-dir.dy, dir.dx);
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo((tip - dir * 9 + n * 5).dx, (tip - dir * 9 + n * 5).dy)
          ..lineTo((tip - dir * 9 - n * 5).dx, (tip - dir * 9 - n * 5).dy)
          ..close(),
        Paint()..color = highlight ? const Color(0xFFD4A84F) : Colors.white38,
      );
      _label(canvas, r.relation, (a + b) / 2, 10, Colors.white60);
    }
    for (final e in entities) {
      final p = pos[e.id]!;
      final color = _GraphScreenState.typeColors[e.type] ?? Colors.grey;
      canvas.drawCircle(p, 18, Paint()..color = color.withValues(alpha: 0.85));
      if (selected?.id == e.id) {
        canvas.drawCircle(p, 23, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
      }
      _label(canvas, e.name, p + const Offset(0, 30), 13, Colors.white);
    }
  }

  void _label(Canvas canvas, String s, Offset c, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 180);
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => true;
}
