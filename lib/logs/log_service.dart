import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/db.dart';
import '../core/models.dart';

/// Registro de partidas. Además de guardarse en la base de datos, cada
/// sesión se escribe en Markdown en
///   `Documentos/DirectorDeRol/logs/{Jugador}/{Tema}/{Campaña}/sesion-N.md`
/// para poder leerlas fuera de la app.
class LogService {
  LogService(this.db, this.logsDir, {this.exportsDir});
  final String? exportsDir;
  final AppDatabase db;
  final String logsDir;

  static String safe(String s) {
    final t = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '').replaceAll(RegExp(r'\s+'), ' ');
    return t.isEmpty ? 'sin-nombre' : t;
  }

  String sessionMarkdown(Campaign c, GameSession s) {
    final b = StringBuffer()
      ..writeln('# ${c.title} — Sesión ${s.number}')
      ..writeln()
      ..writeln('- Tema: ${c.theme}')
      ..writeln('- Jugadores: ${db.campaignPlayers(c.id!).map((p) => '${p.playerName} (${p.characterName})').join(', ')}')
      ..writeln('- Inicio: ${_fmt(s.startedAt)}${s.endedAt == null ? '' : ' · Fin: ${_fmt(s.endedAt!)}'}')
      ..writeln();
    if (s.summary.isNotEmpty) {
      b
        ..writeln('## Resumen')
        ..writeln()
        ..writeln(s.summary)
        ..writeln();
    }
    b
      ..writeln('## Transcripción')
      ..writeln();
    for (final m in db.messagesForSession(s.id!)) {
      switch (m.role) {
        case MessageRole.player:
          b.writeln('**${m.speaker}** _(${_time(m.ts)})_: ${m.content}');
        case MessageRole.gm:
          b.writeln('> **Director** _(${_time(m.ts)})_\n>\n> ${m.content.replaceAll('\n', '\n> ')}');
        case MessageRole.system:
          b.writeln('_${m.speaker}: ${m.content}_');
      }
      b.writeln();
    }
    return b.toString();
  }

  /// Escribe (o reescribe) los ficheros de la sesión, uno por jugador para
  /// que la carpeta de cada jugador tenga su historial completo.
  Future<List<String>> writeSession(Campaign c, GameSession s) async {
    final md = sessionMarkdown(c, s);
    final out = <String>[];
    final players = db.campaignPlayers(c.id!);
    final owners = players.isEmpty ? ['Sin jugador'] : players.map((p) => p.playerName);
    for (final owner in owners) {
      final dir = Directory(p.join(logsDir, safe(owner), safe(c.theme), safe(c.title)));
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, 'sesion-${s.number.toString().padLeft(2, '0')}.md'));
      await f.writeAsString(md);
      out.add(f.path);
    }
    return out;
  }

  Future<String> exportCampaign(Campaign c) async {
    final b = StringBuffer('# ${c.title}\n\n${c.premise}\n\n');
    for (final s in db.sessions(c.id!)) {
      b
        ..writeln(sessionMarkdown(c, s))
        ..writeln('\n---\n');
    }
    final dir = Directory(exportsDir ?? p.join(logsDir, '_exportaciones'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, '${safe(c.title)}.md'));
    await f.writeAsString(b.toString());
    return f.path;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _fmt(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';
  static String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
}
