import 'package:material_ui/material_ui.dart';

import '../../ai/director.dart';
import '../../core/db.dart';
import '../../core/models.dart';
import '../../game/world.dart';
import '../theme.dart';

/// Hoja inferior alta y desplazable, común a fichas y mundo.
Future<void> _sheet(BuildContext context, Widget Function(BuildContext, ScrollController) builder) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: builder,
      ),
    );

Future<String?> _ask(BuildContext context, String title, {String initial = '', String label = '', bool multiline = false}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 6 : 1,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label),
        onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Aceptar')),
      ],
    ),
  );
}

// =====================================================================
// Fichas de los personajes
// =====================================================================

Future<void> showCharacterSheets(BuildContext context, AppDatabase db, int campaignId) =>
    _sheet(context, (ctx, scroll) => _CharacterSheets(db: db, campaignId: campaignId, scroll: scroll));

class _CharacterSheets extends StatefulWidget {
  const _CharacterSheets({required this.db, required this.campaignId, required this.scroll});
  final AppDatabase db;
  final int campaignId;
  final ScrollController scroll;

  @override
  State<_CharacterSheets> createState() => _CharacterSheetsState();
}

class _CharacterSheetsState extends State<_CharacterSheets> {
  AppDatabase get db => widget.db;

  void _save(CharacterState c) {
    db.saveCharState(c);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chars = db.charStates(widget.campaignId);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        Text('Fichas', style: Theme.of(context).textTheme.titleLarge),
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 8),
          child: Text('La app lleva la cuenta: el director propone cambios y se aplican aquí. Puedes corregir lo que quieras.'),
        ),
        for (final c in chars) _card(c),
        OutlinedButton.icon(
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Añadir compañero o mascota'),
          onPressed: () async {
            final name = await _ask(context, 'Nuevo personaje', label: 'Nombre');
            if (name != null && name.trim().isNotEmpty) {
              _save(CharacterState(campaignId: widget.campaignId, name: name.trim()));
            }
          },
        ),
      ],
    );
  }

  Widget _card(CharacterState c) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = c.maxHp <= 0 ? 0.0 : (c.hp / c.maxHp).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                c.player.isEmpty || c.player == c.name ? c.name : '${c.name} · ${c.player}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: kGold, fontSize: 16),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'name':
                    final n = await _ask(context, 'Nombre', initial: c.name);
                    if (n != null && n.trim().isNotEmpty) _save(c..name = n.trim());
                  case 'notes':
                    final n = await _ask(context, 'Notas', initial: c.notes, multiline: true);
                    if (n != null) _save(c..notes = n.trim());
                  case 'delete':
                    db.deleteCharState(c.id!);
                    setState(() {});
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'name', child: Text('Cambiar nombre')),
                PopupMenuItem(value: 'notes', child: Text('Notas')),
                PopupMenuItem(value: 'delete', child: Text('Quitar ficha')),
              ],
            ),
          ]),
          // Puntos de vida.
          Row(children: [
            const Icon(Icons.favorite, size: 18, color: Colors.redAccent),
            const SizedBox(width: 6),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 10,
                  color: ratio > 0.5 ? Colors.green : (ratio > 0.25 ? Colors.orange : Colors.red),
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove), onPressed: () => _save(c..hp -= 1)),
            InkWell(
              onTap: () async {
                final v = await _ask(context, 'Puntos de vida', initial: '${c.hp}/${c.maxHp}', label: 'actual/máximo');
                final m = v == null ? null : RegExp(r'(-?\d+)\s*(?:/\s*(\d+))?').firstMatch(v);
                if (m != null) {
                  c.hp = int.parse(m.group(1)!);
                  if (m.group(2) != null) c.maxHp = int.parse(m.group(2)!);
                  _save(c);
                }
              },
              child: Text('${c.hp}/${c.maxHp}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add), onPressed: () => _save(c..hp = (c.hp + 1).clamp(-999, c.maxHp))),
          ]),
          // Oro.
          Row(children: [
            const Text('🪙'),
            const SizedBox(width: 6),
            Text('Oro: ${c.gold}'),
            const Spacer(),
            TextButton(
              onPressed: () async {
                final v = await _ask(context, 'Oro', initial: '${c.gold}');
                final n = int.tryParse(v?.trim() ?? '');
                if (n != null) _save(c..gold = n);
              },
              child: const Text('Cambiar'),
            ),
          ]),
          // Estados.
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final cond in c.conditions) InputChip(label: Text(cond), onDeleted: () => _save(c..conditions.remove(cond))),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Estado'),
              onPressed: () async {
                final v = await _ask(context, 'Nuevo estado', label: 'envenenado, cansado, asustado…');
                if (v != null && v.trim().isNotEmpty) _save(c..conditions.add(v.trim().toLowerCase()));
              },
            ),
          ]),
          const SizedBox(height: 6),
          // Inventario.
          Text('Inventario', style: Theme.of(context).textTheme.labelLarge),
          for (final item in c.inventory)
            Row(children: [
              Expanded(child: Text('• ${item.name}${item.qty > 1 ? ' ×${item.qty}' : ''}')),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                onPressed: () {
                  item.qty--;
                  if (item.qty <= 0) c.inventory.remove(item);
                  _save(c);
                },
              ),
            ]),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Añadir objeto'),
            onPressed: () async {
              final v = await _ask(context, 'Nuevo objeto', label: 'Nombre (p. ej. «Antorcha x3»)');
              if (v == null || v.trim().isEmpty) return;
              final m = RegExp(r'^(.*?)\s*[x×]\s*(\d+)$').firstMatch(v.trim());
              _save(c..inventory.add(m == null ? InventoryItem(v.trim()) : InventoryItem(m.group(1)!, int.parse(m.group(2)!))));
            },
          ),
          // Modificadores para las tiradas.
          InkWell(
            onTap: () async {
              final v = await _ask(
                context,
                'Modificadores de tirada',
                initial: c.mods.entries.map((e) => '${e.key} ${e.value >= 0 ? '+' : ''}${e.value}').join(', '),
                label: 'Percepción +2, Sigilo +1, Fuerza -1',
                multiline: true,
              );
              if (v == null) return;
              final mods = <String, int>{};
              for (final part in v.split(RegExp(r'[,;\n]'))) {
                final m = RegExp(r'^\s*(.+?)\s*([+\-−]?\s*\d+)\s*$').firstMatch(part);
                if (m != null) mods[m.group(1)!.trim()] = int.parse(m.group(2)!.replaceAll(RegExp(r'\s'), '').replaceAll('−', '-'));
              }
              _save(c..mods = mods);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                c.mods.isEmpty
                    ? '🎲 Sin modificadores (toca para añadir: Percepción +2…)'
                    : '🎲 ${c.mods.entries.map((e) => '${e.key} ${e.value >= 0 ? '+' : ''}${e.value}').join(' · ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (c.notes.isNotEmpty) Text(c.notes, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

// =====================================================================
// El mundo: asuntos pendientes, recuerdos fijados, relojes y tiempo
// =====================================================================

Future<void> showWorldSheet(
  BuildContext context, {
  required AppDatabase db,
  required Campaign campaign,
  required GameSession session,
  required Director director,
  VoidCallback? onChanged,
}) =>
    _sheet(
      context,
      (ctx, scroll) => _WorldSheet(
        db: db,
        campaign: campaign,
        session: session,
        director: director,
        scroll: scroll,
        onChanged: onChanged,
      ),
    );

class _WorldSheet extends StatefulWidget {
  const _WorldSheet({
    required this.db,
    required this.campaign,
    required this.session,
    required this.director,
    required this.scroll,
    this.onChanged,
  });
  final AppDatabase db;
  final Campaign campaign;
  final GameSession session;
  final Director director;
  final ScrollController scroll;
  final VoidCallback? onChanged;

  @override
  State<_WorldSheet> createState() => _WorldSheetState();
}

class _WorldSheetState extends State<_WorldSheet> {
  AppDatabase get db => widget.db;
  int get cid => widget.campaign.id!;
  bool _showClosed = false;

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final threads = db.plotThreads(cid, open: _showClosed ? null : true);
    final pins = db.pins(cid);
    final clocks = db.clocks(cid);
    final events = WorldEngine.pendingEvents(widget.campaign);
    final title = Theme.of(context).textTheme.titleMedium?.copyWith(color: kGold);
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        // ---------------------------------------------------- pendientes
        Row(children: [
          Expanded(child: Text('Asuntos pendientes', style: title)),
          FilterChip(label: const Text('Ver resueltos'), selected: _showClosed, onSelected: (v) => setState(() => _showClosed = v)),
          IconButton(tooltip: 'Añadir', icon: const Icon(Icons.add), onPressed: _addThread),
        ]),
        if (threads.isEmpty) const Text('Nada pendiente. Las promesas, deudas y amenazas aparecerán aquí solas.'),
        for (final t in threads)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: !t.open,
            onChanged: (v) {
              db.updatePlotThread(t..open = v != true);
              _changed();
            },
            title: Text('${t.icon} ${t.text}',
                style: t.open ? null : const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.white54)),
            subtitle: Text('${t.kind}${t.session > 0 ? ' · sesión ${t.session}' : ''}'),
            secondary: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () {
                db.deletePlotThread(t.id!);
                _changed();
              },
            ),
          ),
        const Divider(height: 24),

        // ------------------------------------------------------ fijados
        Row(children: [
          Expanded(child: Text('Recuerdos fijados', style: title)),
          IconButton(
            tooltip: 'Fijar un recuerdo',
            icon: const Icon(Icons.push_pin_outlined),
            onPressed: () async {
              final v = await _ask(context, 'Fijar recuerdo', label: 'El director lo tendrá siempre presente', multiline: true);
              if (v != null && v.trim().isNotEmpty) {
                db.addPin(PinnedMemory(campaignId: cid, text: v.trim()));
                _changed();
              }
            },
          ),
        ]),
        if (pins.isEmpty) const Text('Mantén pulsado un mensaje de la partida (o usa la chincheta) para que el director no lo olvide nunca.'),
        for (final p in pins)
          ListTile(
            dense: true,
            leading: const Icon(Icons.push_pin, size: 18, color: kGold),
            title: Text(p.text, maxLines: 4, overflow: TextOverflow.ellipsis),
            onTap: () async {
              final v = await _ask(context, 'Editar recuerdo', initial: p.text, multiline: true);
              if (v != null && v.trim().isNotEmpty) {
                db.updatePin(p..text = v.trim());
                _changed();
              }
            },
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                db.deletePin(p.id!);
                _changed();
              },
            ),
          ),
        const Divider(height: 24),

        // ------------------------------------------------------ relojes
        Row(children: [
          Expanded(child: Text('El mundo se mueve', style: title)),
          IconButton(tooltip: 'Nueva trama', icon: const Icon(Icons.add_alarm), onPressed: () => _editClock(null)),
        ]),
        const Text('Tramas de facciones y villanos. Avanzan solas cada pocos turnos con una tirada; si se llenan, '
            'su consecuencia ocurre y el director la mostrará.'),
        if (events.isNotEmpty)
          Card(
            color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Por narrar:\n${events.map((e) => '• $e').join('\n')}'),
            ),
          ),
        for (final k in clocks) _clock(k),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.hourglass_bottom),
          label: const Text('Salto de tiempo…'),
          onPressed: _timeSkip,
        ),
      ],
    );
  }

  Widget _clock(WorldClock k) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                '${k.owner.isEmpty ? '' : '${k.owner}: '}${k.name}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  decoration: k.active ? null : TextDecoration.lineThrough,
                ),
              ),
            ),
            IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.edit, size: 18), onPressed: () => _editClock(k)),
          ]),
          Row(children: [
            for (var i = 0; i < k.segments; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    k.filled = i + 1 == k.filled ? i : i + 1;
                    k.active = !k.full;
                    db.saveClock(k);
                    _changed();
                  },
                  child: Container(
                    height: 14,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: i < k.filled ? (k.full ? Colors.redAccent : kGold) : Colors.white12,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 6),
            Text('${k.filled}/${k.segments}'),
            const SizedBox(width: 8),
          ]),
          Row(children: [
            const Text('El grupo: '),
            DropdownButton<String>(
              value: WorldClock.stances.contains(k.stance) ? k.stance : 'desconocen',
              isDense: true,
              items: [for (final s in WorldClock.stances) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) {
                if (v == null) return;
                db.saveClock(k..stance = v);
                _changed();
              },
            ),
            const Spacer(),
            if (!k.active && !k.full)
              const Text('en pausa  ', style: TextStyle(color: Colors.white54)),
          ]),
          if (k.consequence.isNotEmpty)
            Text('Si se llena: ${k.consequence}', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  Future<void> _addThread() async {
    final ctrl = TextEditingController();
    var kind = 'promesa';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Nuevo asunto pendiente'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 6, children: [
              for (final k in PlotThread.kinds)
                ChoiceChip(
                  label: Text('${PlotThread.icons[k]} $k'),
                  selected: kind == k,
                  onSelected: (_) => setD(() => kind = k),
                ),
            ]),
            TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Descripción')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Añadir')),
          ],
        ),
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      db.addPlotThread(PlotThread(campaignId: cid, kind: kind, text: ctrl.text.trim(), session: widget.session.number));
      _changed();
    }
  }

  Future<void> _editClock(WorldClock? k) async {
    final name = TextEditingController(text: k?.name ?? '');
    final owner = TextEditingController(text: k?.owner ?? '');
    final cons = TextEditingController(text: k?.consequence ?? '');
    var segments = k?.segments ?? 6;
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(k == null ? 'Nueva trama' : 'Editar trama'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: owner, decoration: const InputDecoration(labelText: 'Quién la empuja (facción, PNJ…)')),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Qué intenta conseguir')),
              TextField(controller: cons, maxLines: 3, decoration: const InputDecoration(labelText: 'Qué pasa si lo consigue')),
              const SizedBox(height: 8),
              Row(children: [
                const Text('Segmentos'),
                Expanded(
                  child: Slider(
                    value: segments.toDouble(),
                    min: 3,
                    max: 12,
                    divisions: 9,
                    label: '$segments',
                    onChanged: (v) => setD(() => segments = v.round()),
                  ),
                ),
                Text('$segments'),
              ]),
            ]),
          ),
          actions: [
            if (k != null) TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Borrar')),
            if (k != null)
              TextButton(onPressed: () => Navigator.pop(ctx, 'toggle'), child: Text(k.active ? 'Pausar' : 'Reanudar')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (res == null) return;
    if (res == 'delete') {
      db.deleteClock(k!.id!);
    } else if (res == 'toggle') {
      db.saveClock(k!..active = !k.active);
    } else if (name.text.trim().isNotEmpty) {
      final c = k ?? WorldClock(campaignId: cid, name: '');
      c
        ..name = name.text.trim()
        ..owner = owner.text.trim()
        ..consequence = cons.text.trim()
        ..segments = segments
        ..filled = c.filled.clamp(0, segments);
      db.saveClock(c);
    }
    _changed();
  }

  Future<void> _timeSkip() async {
    const options = <(String, int)>[
      ('Un día', 1),
      ('Unos días', 3),
      ('Una semana', 7),
      ('Dos semanas', 14),
      ('Un mes', 30),
      ('Una estación', 90),
      ('Un año', 365),
    ];
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Cuánto tiempo pasa?'),
        children: [
          for (final (label, d) in options) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, d), child: Text(label)),
        ],
      ),
    );
    if (days == null) return;
    final notes = widget.director.skipTime(widget.campaign, widget.session, days);
    _changed();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notes.join('\n'))));
    }
  }
}
