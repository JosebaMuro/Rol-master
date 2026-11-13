import 'dart:io';

import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:director_de_rol/core/portable.dart';
import 'package:director_de_rol/core/settings.dart';
import 'package:director_de_rol/core/story_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rol_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('DataRoot guarda rutas relativas y las resuelve', () {
    final root = DataRoot(p.join(tmp.path, 'datos'));
    final inside = p.join(root.maps, 'a.png');
    expect(root.toStored(inside), 'mapas/a.png');
    expect(root.resolve('mapas/a.png'), p.normalize(inside));
    final outside = p.join(tmp.path, 'otro.png');
    expect(root.toStored(outside), outside);
    expect(Directory(root.models).existsSync(), isTrue);
  });

  test('los ajustes se guardan en un JSON y se recargan', () {
    final f = p.join(tmp.path, 'ajustes.json');
    final a = AppSettings.load(f);
    a.temperature = 0.4;
    expect(File(f).existsSync(), isTrue);
    expect(AppSettings.load(f).temperature, 0.4);
  });

  test('exportar e importar una historia la duplica con sus partidas y mapas', () {
    final root = DataRoot(p.join(tmp.path, 'datos'));
    final db = AppDatabase.memory(root: root);
    final c = db.insertCampaign(Campaign(title: 'La cripta', theme: 'Fantasía', premise: 'Un rey muerto'));
    final cid = c.id!;
    final pl = db.upsertPlayer('Ana');
    db.setCampaignPlayers(cid, [CampaignPlayer(playerId: pl.id!, playerName: 'Ana', characterName: 'Lira')]);
    db.upsertNpc(Npc(campaignId: cid, name: 'Gorm', description: 'Herrero', voiceHint: 'hombre grave'));
    final s = db.startSession(cid);
    final m1 = db.addMessage(ChatMessage(campaignId: cid, sessionId: s.id!, role: MessageRole.player, content: 'Hola'));
    db.addMessage(ChatMessage(campaignId: cid, sessionId: s.id!, role: MessageRole.gm, content: 'Bienvenidos'));
    c.bible['_memoryUpTo'] = m1.id;
    db.updateCampaign(c);
    final img = File(p.join(root.maps, 'm.png'))..writeAsBytesSync([1, 2, 3]);
    db.addMap(MapRecord(campaignId: cid, title: 'Cripta', kind: 'mazmorra', seed: 7, imagePath: img.path));

    final bytes = StoryPackage.export(db, cid);
    expect(StoryPackage.peek(bytes)['campaign']['title'], 'La cripta');

    final imported = StoryPackage.import(db, bytes, mapsDir: root.maps);
    expect(imported.id, isNot(cid));
    expect(imported.title, 'La cripta (importada)');
    expect(db.npcs(imported.id!).single.name, 'Gorm');
    expect(db.campaignPlayers(imported.id!).single.characterName, 'Lira');
    final sessions = db.sessions(imported.id!);
    expect(sessions, hasLength(1));
    final msgs = db.messagesForSession(sessions.single.id!);
    expect(msgs.map((m) => m.content), ['Hola', 'Bienvenidos']);
    expect(db.campaign(imported.id!)!.bible['_memoryUpTo'], msgs.first.id);
    final map = db.maps(campaignId: imported.id!).single;
    expect(File(map.imagePath).readAsBytesSync(), [1, 2, 3]);

    final clean = StoryPackage.import(db, StoryPackage.export(db, cid, includeProgress: false), mapsDir: root.maps);
    expect(db.sessions(clean.id!), isEmpty);
    expect(db.campaign(clean.id!)!.bible.containsKey('_memoryUpTo'), isFalse);
    db.close();
  });
}
