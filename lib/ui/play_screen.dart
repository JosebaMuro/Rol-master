import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ai/director.dart';
import '../ai/llama_service.dart';
import '../ai/narration_parser.dart';
import '../app_services.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../game/dice.dart';
import '../voice/speech_input.dart';
import '../voice/voice_service.dart';
import 'map_viewer.dart';
import 'widgets/file_utils.dart';
import 'widgets/music_bar.dart';
import 'widgets/rich_message.dart';
import 'widgets/scene_panel.dart';
import 'widgets/table_sheets.dart';

/// Mesa de juego: chat con el director, voces, música, mapas y tiradas.
class PlayScreen extends StatefulWidget {
  const PlayScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  late final AppServices s;
  late Campaign campaign;
  late GameSession session;
  late Director director;
  late List<CampaignPlayer> players;
  final _input = TextEditingController();

  /// Imagen que acompañará al próximo turno (sólo con modelos con visión).
  String? _image;
  final _scroll = ScrollController();
  final _messages = <ChatMessage>[];

  String _speaker = '';
  bool _generating = false;
  String _partial = '';
  String _thinking = '';
  String? _musicSuggestion;
  List<String> _pendingRolls = [];
  MapRecord? _lastMap;
  bool _showMap = false;
  bool _ending = false;
  StreamSubscription<List<String>>? _archiveSub;

  @override
  void initState() {
    super.initState();
    s = context.read<AppServices>();
    campaign = s.db.campaign(widget.campaignId)!;
    _lastMap = s.db.maps(campaignId: campaign.id).firstOrNull;
    players = s.db.campaignPlayers(campaign.id!);
    _speaker = players.isEmpty ? 'Jugador' : _label(players.first);
    director = s.director();
    final last = s.db.lastSession(campaign.id!);
    // Si la última sesión quedó abierta (la app se cerró), se continúa.
    if (last != null && last.endedAt == null) {
      session = last;
    } else {
      session = director.startSession(campaign);
    }
    director.prepare(campaign);
    campaign = s.db.campaign(campaign.id!)!;
    // El archivista trabaja tras cada turno; sus notas aparecen al llegar.
    _archiveSub = director.archiveNotes.listen((_) {
      if (mounted && !_generating) setState(_reload);
    });
    _reload();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final first = _messages.where((m) => m.role != MessageRole.player).lastOrNull;
      if (first != null && _messages.length <= 2) _speak(first);
      _toBottom();
    });
  }

  String _label(CampaignPlayer p) => p.characterName.isEmpty ? p.playerName : p.characterName;

  void _reload() {
    _messages
      ..clear()
      ..addAll(s.db.messagesForSession(session.id!));
    if (_messages.isEmpty) {
      // Muestra también el final de la sesión anterior como contexto.
      _messages.addAll(s.db.recentMessages(campaign.id!, limit: 4));
    }
  }

  void _toBottom() {
    Future.delayed(const Duration(milliseconds: 60), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  List<String> get _situationNames => s.db.situations().map((e) => e.name).toList();

  Future<void> _send([String? override, String? speaker]) async {
    final text = (override ?? _input.text).trim();
    if (text.isEmpty || _generating) return;
    final who = speaker ?? _speaker;
    if (!s.llm.isReady) {
      _snack('Carga un modelo de IA en Ajustes');
      return;
    }
    if (override == null) _input.clear();
    final images = [if (_image != null && s.llm.canSee) _image!];
    await s.voices.stop();
    director.config = s.directorConfig;
    setState(() {
      _generating = true;
      _partial = '';
      _thinking = '';
      _pendingRolls = [];
      _image = null;
      _messages.add(
        ChatMessage(
          campaignId: campaign.id!,
          sessionId: session.id!,
          role: MessageRole.player,
          speaker: who,
          content: Director.withImageNote(text, images),
        ),
      );
    });
    _toBottom();
    await _consume(director.playerTurn(
      campaign: campaign,
      session: session,
      speaker: who,
      text: text,
      situations: _situationNames,
      images: images,
    ));
  }

  /// Elige una imagen (mapa, ficha, foto de la mesa…) para enseñársela al
  /// director en el próximo turno.
  Future<void> _pickImage() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f == null) return;
    final path = await localPathFor(f, s.dataRoot.tmp);
    if (path == null || !mounted) return;
    setState(() => _image = path);
  }

  Future<void> _regenerate() async {
    if (_generating) return;
    await s.voices.stop();
    setState(() {
      _generating = true;
      _partial = '';
      _thinking = '';
      if (_messages.isNotEmpty && _messages.last.role == MessageRole.gm) _messages.removeLast();
    });
    await _consume(director.regenerate(campaign: campaign, session: session, situations: _situationNames));
  }

  Future<void> _consume(Stream<DirectorEvent> events) async {
    try {
      await for (final e in events) {
        if (!mounted) return;
        switch (e) {
          case DirectorThinking(:final thinking):
            setState(() => _thinking = thinking);
          case DirectorPartial(:final text):
            setState(() => _partial = text);
            _toBottom();
          case DirectorDone(:final message, :final parsed):
            setState(() {
              _reload();
              _partial = '';
              _thinking = '';
            });
            _afterResponse(message, parsed);
        }
      }
    } catch (e) {
      _snack('Error del director: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
      _logSession();
    }
  }

  void _afterResponse(ChatMessage m, ParsedNarration parsed) {
    campaign = s.db.campaign(campaign.id!)!;
    _speakParsed(parsed);
    if (parsed.musicSuggestion != null) {
      final sit = s.music.situationByName(parsed.musicSuggestion!);
      if (s.settings.autoMusic && sit != null) {
        s.music.playSituation(sit);
      } else {
        setState(() => _musicSuggestion = parsed.musicSuggestion);
      }
    }
    if (parsed.rolls.isNotEmpty) setState(() => _pendingRolls = parsed.rolls);
    final map = parsed.mapRequest;
    if (map != null) {
      unawaited(
        s.maps.create(kind: map.kind, title: map.title, campaign: campaign).then((rec) {
          if (!mounted) return;
          setState(() {
            _lastMap = rec;
            _showMap = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Mapa listo: ${rec.title}'),
              action: SnackBarAction(label: 'Ver', onPressed: () => openMapFullscreen(context, rec)),
            ),
          );
        }),
      );
    }
    _toBottom();
  }

  void _speakParsed(ParsedNarration parsed) {
    if (!s.settings.voiceEnabled) return;
    s.voices.speakAll(s.voices.linesFor(parsed, s.db.npcs(campaign.id!)));
  }

  void _speak(ChatMessage m) {
    if (m.role == MessageRole.player) return;
    // Reconstruye las líneas de diálogo del texto guardado (**Nombre:** «...»).
    final raw = m.content.replaceAllMapped(RegExp(r'^\*\*(.+?):\*\* «(.*)»$', multiLine: true), (x) => '@${x[1]}: ${x[2]}');
    _speakParsed(parseNarration(raw));
  }

  Future<void> _logSession() async {
    try {
      await s.logs.writeSession(campaign, session);
    } catch (_) {}
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _endSession() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terminar sesión'),
        content: const Text('El director escribirá un resumen para continuar la próxima vez y se guardará el registro.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Seguir jugando')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Terminar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _ending = true);
    await s.voices.stop();
    final summary = await director.endSession(campaign, session);
    await s.logs.writeSession(campaign, session);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sesión ${session.number} guardada'),
        content: SingleChildScrollView(child: Text(summary.isEmpty ? 'Sin resumen.' : summary)),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  /// La app tira por el personaje: d20 + su modificador contra la CD, y
  /// envía el resultado al director para que narre la consecuencia.
  Future<void> _autoRoll(String raw) async {
    if (_generating) return;
    final req = RollRequest.parse(raw);
    final who = req.who.isNotEmpty ? req.who : (_speaker == 'Grupo' ? '' : _speaker);
    final sheet = who.isEmpty ? null : director.state.find(campaign.id!, who);
    final name = sheet?.name ?? (who.isEmpty ? _speaker : who);
    final check = SkillCheck.roll(req, who: name, modifier: sheet?.modFor(req.skill) ?? 0);
    setState(() => _pendingRolls = _pendingRolls.where((r) => r != raw).toList());
    final speaker = players.where((p) => _label(p) == name).isNotEmpty ? name : _speaker;
    await _send(check.describe(), speaker);
  }

  Future<void> _rollDialog([String? request]) async {
    final rnd = Random();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(request == null ? 'Tirar dados' : 'Tirada: $request'),
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in [4, 6, 8, 10, 12, 20, 100])
                ActionChip(
                  label: Text('d$d'),
                  onPressed: () {
                    final v = 1 + rnd.nextInt(d);
                    Navigator.pop(ctx, '${request ?? 'Tirada'}: d$d → $v');
                  },
                ),
            ],
          ),
        ],
      ),
    );
    if (result != null) {
      _input.text = _input.text.isEmpty ? result : '${_input.text} ($result)';
      setState(() => _pendingRolls = _pendingRolls.where((r) => r != request).toList());
    }
  }

  Future<void> _pin(ChatMessage m) async {
    final ctrl = TextEditingController(text: m.content.replaceAll('**', '').trim());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fijar en la memoria'),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 10,
          decoration: const InputDecoration(helperText: 'Recórtalo a lo esencial: el director lo tendrá siempre presente.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fijar')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      s.db.addPin(PinnedMemory(campaignId: campaign.id!, text: ctrl.text.trim()));
      _snack('Recuerdo fijado');
    }
  }

  void _openWorld() => showWorldSheet(
        context,
        db: s.db,
        campaign: campaign,
        session: session,
        director: director,
        onChanged: () {
          if (mounted) setState(_reload);
        },
      );

  Future<void> _toggleMic(SpeechInput speech) async {
    if (speech.transcribing) return;
    if (!speech.recording) {
      await s.voices.stop();
      final err = await speech.start();
      if (err != null) _snack(err);
      return;
    }
    try {
      final text = await speech.stop();
      if (!mounted) return;
      if (text.isEmpty) {
        _snack('No se ha entendido nada. Prueba otra vez, más cerca del micrófono.');
        return;
      }
      _input.text = _input.text.trim().isEmpty ? text : '${_input.text.trim()} $text';
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
      if (s.settings.speechAutoSend) await _send();
    } catch (e) {
      _snack('Error al reconocer la voz: $e');
    }
  }

  void _showMaps() {
    final maps = s.db.maps(campaignId: campaign.id);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Generar mapa nuevo'),
            onTap: () async {
              Navigator.pop(ctx);
              final rec = await showCreateMapDialog(context, campaign: campaign);
              if (rec != null && mounted) {
                setState(() {
                  _lastMap = rec;
                  _showMap = true;
                });
                openMapFullscreen(context, rec);
              }
            },
          ),
          for (final m in maps)
            ListTile(
              leading: const Icon(Icons.map),
              title: Text(m.title),
              subtitle: Text(m.kind),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _lastMap = m;
                  _showMap = true;
                });
                openMapFullscreen(context, m);
              },
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _archiveSub?.cancel();
    s.speech.cancel();
    s.voices.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final llm = context.watch<LlamaService>();
    final voices = context.watch<VoiceService>();
    final act = campaign.acts.isEmpty ? '' : ' · Acto ${campaign.currentAct + 1}';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(campaign.title, overflow: TextOverflow.ellipsis),
            Text(
              'Sesión ${session.number}$act${campaign.location.isEmpty ? '' : ' · ${campaign.location}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: settings.voiceEnabled ? 'Silenciar voces' : 'Activar voces',
            icon: Icon(settings.voiceEnabled ? Icons.record_voice_over : Icons.voice_over_off),
            onPressed: () {
              settings.voiceEnabled = !settings.voiceEnabled;
              if (!settings.voiceEnabled) voices.stop();
            },
          ),
          IconButton(tooltip: 'Fichas', icon: const Icon(Icons.badge_outlined), onPressed: () => showCharacterSheets(context, s.db, campaign.id!)),
          IconButton(tooltip: 'El mundo: pendientes, recuerdos y tramas', icon: const Icon(Icons.public), onPressed: _openWorld),
          IconButton(tooltip: 'Mapas', icon: const Icon(Icons.map), onPressed: _showMaps),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'thinking':
                  settings.thinking = !settings.thinking;
                case 'panel':
                  settings.showScenePanel = !settings.showScenePanel;
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'thinking', checked: settings.thinking, child: const Text('Razonamiento del director')),
              CheckedPopupMenuItem(value: 'panel', checked: settings.showScenePanel, child: const Text('Panel de imagen')),
            ],
          ),
          IconButton(tooltip: 'Terminar sesión', icon: const Icon(Icons.flag), onPressed: _ending ? null : _endSession),
        ],
      ),
      body: Column(
        children: [
          MusicBar(suggestion: _musicSuggestion, onDismissSuggestion: () => setState(() => _musicSuggestion = null)),
          if (_ending) const LinearProgressIndicator(),
          if (settings.showScenePanel)
            // Mitad superior: gráficos (fondo de la escena o mapa).
            Expanded(
              child: ScenePanel(
                campaign: campaign,
                map: _lastMap,
                showMap: _showMap,
                onToggleMap: () => setState(() => _showMap = !_showMap),
                onCampaignChanged: () => setState(() => campaign = s.db.campaign(campaign.id!)!),
                overlay: voices.speaking ? _speakingBar(voices, translucent: true) : null,
              ),
            )
          else if (voices.speaking)
            _speakingBar(voices),
          if (voices.lastError != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.volume_off),
                title: Text(voices.lastError!, maxLines: 3, overflow: TextOverflow.ellipsis),
                subtitle: const Text('Ajustes › Voces › Diagnóstico de voces da más detalle'),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: voices.clearError),
              ),
            ),
          // Mitad inferior: texto de la partida.
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length + (_generating ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _messages.length) {
                        return MessageBubble.streaming(text: _partial, thinking: _thinking, showThinking: settings.showThinking);
                      }
                      final m = _messages[i];
                      return MessageBubble(
                        message: m,
                        showThinking: settings.showThinking,
                        onSpeak: m.role == MessageRole.player ? null : () => _speak(m),
                        onPin: m.role == MessageRole.player ? null : () => _pin(m),
                      );
                    },
                  ),
                ),
                if (_pendingRolls.isNotEmpty || _lastMap != null)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final r in _pendingRolls)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onLongPress: () => _rollDialog(r),
                              child: Tooltip(
                                message: 'Toca y la app tira por el personaje · mantén pulsado para tirar a mano',
                                child: ActionChip(
                                  avatar: const Icon(Icons.casino, size: 18),
                                  label: Text(RollRequest.parse(r).toString()),
                                  onPressed: () => _autoRoll(r),
                                ),
                              ),
                            ),
                          ),
                        if (_lastMap != null)
                          ActionChip(
                            avatar: const Icon(Icons.fullscreen, size: 18),
                            label: Text(_lastMap!.title),
                            onPressed: () => openMapFullscreen(context, _lastMap!),
                          ),
                      ],
                    ),
                  ),
                _inputBar(llm),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _speakingBar(VoiceService voices, {bool translucent = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: translucent ? scheme.secondaryContainer.withValues(alpha: 0.85) : scheme.secondaryContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.graphic_eq),
        title: Text(voices.currentSpeaker == null ? 'Narrando…' : '${voices.currentSpeaker} habla…'),
        trailing: IconButton(icon: const Icon(Icons.stop), onPressed: voices.stop),
      ),
    );
  }

  Widget _micButton() {
    final speech = context.watch<SpeechInput>();
    if (speech.transcribing) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (speech.recording) {
      return IconButton.filled(
        tooltip: 'Terminar y transcribir',
        style: IconButton.styleFrom(backgroundColor: Colors.redAccent.withValues(alpha: 0.6 + min(0.4, speech.level * 20))),
        icon: const Icon(Icons.stop),
        onPressed: () => _toggleMic(speech),
      );
    }
    return IconButton(
      tooltip: speech.available ? 'Hablar (toca para empezar y otra vez para terminar)' : 'Hablar: descarga un modelo de voz en Ajustes',
      icon: Icon(speech.available ? Icons.mic : Icons.mic_none),
      onPressed: () => _toggleMic(speech),
    );
  }

  Widget _inputBar(LlamaService llm) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (players.length > 1)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in players)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(_label(p)),
                          selected: _speaker == _label(p),
                          onSelected: (_) => setState(() => _speaker = _label(p)),
                        ),
                      ),
                    ChoiceChip(
                      label: const Text('Grupo'),
                      selected: _speaker == 'Grupo',
                      onSelected: (_) => setState(() => _speaker = 'Grupo'),
                    ),
                  ],
                ),
              ),
            if (_image != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InputChip(
                    avatar: ClipOval(child: Image.file(File(_image!), width: 24, height: 24, fit: BoxFit.cover)),
                    label: const Text('Imagen para el director'),
                    onDeleted: () => setState(() => _image = null),
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(tooltip: 'Tirar dados', icon: const Icon(Icons.casino), onPressed: () => _rollDialog()),
                _micButton(),
                if (llm.canSee)
                  IconButton(
                    tooltip: 'Enseñar una imagen al director',
                    icon: const Icon(Icons.image_outlined),
                    onPressed: _generating ? null : _pickImage,
                  ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '¿Qué hace $_speaker?',
                      isDense: true,
                      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                    ),
                  ),
                ),
                if (_generating)
                  IconButton(tooltip: 'Detener', icon: const Icon(Icons.stop_circle), onPressed: llm.cancel)
                else ...[
                  IconButton(
                    tooltip: 'Repetir la última respuesta',
                    icon: const Icon(Icons.refresh),
                    onPressed: _messages.isNotEmpty ? _regenerate : null,
                  ),
                  IconButton.filled(icon: const Icon(Icons.send), onPressed: llm.isReady ? _send : null),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
