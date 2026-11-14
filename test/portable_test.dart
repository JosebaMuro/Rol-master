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

  test('campaña completa: música, fondos, voces, documentación y RAG viajan a otro equipo', () async {
    // Equipo A
    final rootA = DataRoot(p.join(tmp.path, 'A'));
    final dbA = AppDatabase.memory(root: rootA);
    final setA = AppSettings(JsonPrefs.memory())..embedModel = 'embeddinggemma.gguf';
    final c = dbA.insertCampaign(Campaign(title: 'Niebla', theme: 'Terror'));
    final cid = c.id!;
    dbA.upsertNpc(Npc(
      campaignId: cid,
      name: 'Vera',
      description: 'Bruja',
      voiceHint: 'mujer',
      voice: const VoiceProfile(engine: 'neural', neuralPack: 'vits-piper-es_ES-test'),
    ));
    dbA.addChunk(LoreChunk(campaignId: cid, source: 'biblia', text: 'La niebla esconde a los muertos', embedding: [0.1, 0.2, 0.3]));
    final doc = dbA.addDocument(DocumentRecord(campaignId: null, title: 'Reglas', path: '', kind: 'txt', chars: 10));
    dbA.addDocChunks(doc.id!, ['Tirada de cordura'], [
      [1.0, 0.0],
    ]);
    final combate = dbA.situations().firstWhere((x) => x.name == 'Combate');
    final song = File(p.join(rootA.music, 'Combate', 'tambores.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(5000, 7));
    dbA.addTrack(Track(path: rootA.toStored(song.path), title: 'Tambores', situationId: combate.id, volume: 0.8));
    dbA.addSituation('Niebla espesa', '🌫️');
    final bg = File(p.join(rootA.backgrounds, 'cripta.jpg'))..writeAsBytesSync([9, 9, 9]);
    setA.setSceneBackground('cripta', rootA.toStored(bg.path));
    setA.narratorVoice = const VoiceProfile(engine: 'neural', neuralPack: 'vits-piper-es_ES-test', speed: 0.9);
    final pack = Directory(p.join(rootA.voices, 'vits-piper-es_ES-test'))..createSync(recursive: true);
    File(p.join(pack.path, 'pack.json')).writeAsStringSync('{"id":"vits-piper-es_ES-test","kind":"piper","files":{},"numSpeakers":1}');
    File(p.join(pack.path, 'model.onnx')).writeAsBytesSync([1, 2]);

    final sizes = StoryPackage.estimateSizes(dbA, cid, root: rootA, settings: setA);
    expect(sizes['musica'], 5000);
    expect(sizes['voces'], greaterThan(0));

    final out = p.join(rootA.exports, 'niebla.rolpack');
    await StoryPackage.exportToFile(dbA, cid, out,
        options: const PackageOptions(voiceModels: true), root: rootA, settings: setA);
    final summary = StoryPackage.peekFile(out);
    expect(summary.title, 'Niebla');
    expect(summary.tracks, 1);
    expect(summary.includedVoicePacks, 1);

    // Equipo B, con otro modelo de embeddings y sin la voz.
    final rootB = DataRoot(p.join(tmp.path, 'B'));
    final dbB = AppDatabase.memory(root: rootB);
    final setB = AppSettings(JsonPrefs.memory())..embedModel = 'otro-modelo.gguf';
    final r = await StoryPackage.importFile(dbB, out, root: rootB, settings: setB);
    final id = r.campaign.id!;
    expect(r.campaign.title, 'Niebla');
    expect(dbB.npcs(id).single.voice.neuralPack, 'vits-piper-es_ES-test');
    expect(r.tracks, 1);
    final t = dbB.tracks().single;
    expect(t.title, 'Tambores');
    expect(t.volume, 0.8);
    expect(dbB.situations().firstWhere((x) => x.id == t.situationId).name, 'Combate');
    expect(File(rootB.resolve(t.path)).lengthSync(), 5000);
    expect(dbB.situations().any((x) => x.name == 'Niebla espesa'), isTrue);
    expect(File(rootB.resolve(setB.sceneBackground('cripta'))).readAsBytesSync(), [9, 9, 9]);
    expect(r.installedVoices, ['vits-piper-es_ES-test']);
    expect(File(p.join(rootB.voices, 'vits-piper-es_ES-test', 'model.onnx')).existsSync(), isTrue);
    expect(r.narratorApplied, isTrue);
    expect(setB.narratorVoice.speed, 0.9);
    // RAG: el texto viaja; los vectores de otro modelo se descartan.
    expect(r.needsReembed, isTrue);
    expect(dbB.chunks(id).single.text, 'La niebla esconde a los muertos');
    expect(dbB.chunks(id).single.embedding, isNull);
    expect(dbB.documents().single.title, 'Reglas');
    expect(dbB.documents().single.campaignId, isNull);

    // Importar otra vez no duplica la música ni la documentación general.
    final r2 = await StoryPackage.importFile(dbB, out, root: rootB, settings: setB);
    expect(r2.tracks, 0);
    expect(r2.tracksSkipped, 1);
    expect(dbB.tracks(), hasLength(1));
    expect(dbB.documents(), hasLength(1));
    expect(r2.campaign.title, 'Niebla (importada)');

    // Mismo modelo de embeddings: los vectores se conservan.
    final rootC = DataRoot(p.join(tmp.path, 'C'));
    final dbC = AppDatabase.memory(root: rootC);
    final setC = AppSettings(JsonPrefs.memory())..embedModel = 'embeddinggemma.gguf';
    final r3 = await StoryPackage.importFile(dbC, out, root: rootC, settings: setC,
        options: const ImportOptions(voiceModels: false, narrator: false));
    expect(r3.needsReembed, isFalse);
    expect(dbC.chunks(r3.campaign.id!).single.embedding, isNotNull);
    expect(r3.missingVoices, ['vits-piper-es_ES-test']);
    expect(setC.narratorVoice.engine, 'system');
    dbA.close();
    dbB.close();
    dbC.close();
  });
}
