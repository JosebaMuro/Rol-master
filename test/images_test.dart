import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:director_de_rol/core/db.dart';
import 'package:director_de_rol/core/models.dart';
import 'package:director_de_rol/core/portable.dart';
import 'package:director_de_rol/core/settings.dart';
import 'package:director_de_rol/core/story_package.dart';
import 'package:director_de_rol/images/image_engine.dart';
import 'package:director_de_rol/images/image_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// PNG mínimo válido (1×1).
final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

/// Motor de pruebas: apunta lo que se le pide y devuelve un PNG.
class FakeEngine implements ImageEngine {
  FakeEngine({this.english = false, this.fail = false});
  final bool english;
  final bool fail;
  final requests = <ImageRequest>[];
  @override
  String get id => 'fake';
  @override
  String get label => 'Falso';
  @override
  bool get prefersEnglish => english;
  @override
  String? get problem => null;
  @override
  Future<Uint8List> generate(ImageRequest request) async {
    requests.add(request);
    if (fail) throw ImageEngineException('roto');
    return png;
  }

  @override
  void cancel() {}
}

void main() {
  late Directory tmp;
  late DataRoot root;
  late AppDatabase db;
  late AppSettings settings;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('img_');
    root = DataRoot(p.join(tmp.path, 'datos'));
    db = AppDatabase.memory(root: root);
    settings = AppSettings(JsonPrefs.memory());
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  Campaign campaign() {
    final c = db.insertCampaign(Campaign(
      title: 'La Corona de Ceniza',
      theme: 'Fantasía',
      tone: 'oscuro',
      bible: Map<String, dynamic>.from(sampleBible),
      location: 'Taberna del Cuervo',
    ));
    final pl = db.upsertPlayer('Ana');
    db.setCampaignPlayers(c.id!, [CampaignPlayer(playerId: pl.id!, playerName: 'Ana', characterName: 'Kael', characterSheet: 'Elfo explorador de pelo plateado')]);
    db.upsertNpc(Npc(campaignId: c.id!, name: 'Bran el tabernero', description: 'Tabernero desconfiado y calvo'));
    return c;
  }

  test('la tabla de imágenes guarda una por tipo y sujeto, con rutas relativas', () {
    final c = campaign();
    final f = p.join(root.campaignImages(c.id!), 'r.png');
    Directory(p.dirname(f)).createSync(recursive: true);
    File(f).writeAsBytesSync(png);
    db.saveImage(ImageRecord(campaignId: c.id!, kind: ImageRecord.portrait, subject: 'Kael', path: f));
    db.saveImage(ImageRecord(campaignId: c.id!, kind: ImageRecord.portrait, subject: 'kael', path: f, description: 'otra'));
    final all = db.images(c.id!);
    expect(all, hasLength(1));
    expect(all.first.description, 'otra');
    expect(all.first.path, p.normalize(f));
    final raw = db.db.select('SELECT path FROM images').first['path'] as String;
    expect(p.isAbsolute(raw), isFalse);
  });

  test('personajes: PJ y PNJ con lo que se sabe de ellos', () {
    final c = campaign();
    final lib = ImageLibrary(db, FakeLlm(), settings, root, engineOverride: () => FakeEngine());
    final names = lib.subjects(c).map((s) => s.name).toList();
    expect(names, containsAll(['Kael', 'Bran el tabernero']));
    expect(lib.subjects(c).firstWhere((s) => s.name == 'Kael').player, isTrue);
    expect(lib.descriptionOf(c, 'bran el tabernero'), contains('calvo'));
  });

  test('buscar escenas que faltan apunta los lugares y las propuestas de la IA', () async {
    final c = campaign();
    final llm = FakeLlm(jsonReplies: [
      {
        'scenes': [
          {'title': 'El duelo en la cripta', 'description': 'Lady Morwen alza la corona negra.'},
          {'title': 'Taberna del Cuervo', 'description': 'repetida'},
        ],
      },
    ]);
    final lib = ImageLibrary(db, llm, settings, root, engineOverride: () => FakeEngine());
    final n = await lib.planScenes(c);
    final titles = lib.scenes(c.id!).map((e) => e.subject).toSet();
    expect(titles, containsAll(['Taberna del Cuervo', 'Cripta de los Reyes', 'El duelo en la cripta']));
    expect(n, titles.length);
    expect(lib.scenes(c.id!).every((e) => e.missing), isTrue);
    // Otra vez no añade nada nuevo.
    expect(await lib.planScenes(c, useAi: false), 0);
  });

  test('generar lo que falta: retrato, cuerpo entero y escenas, con la misma semilla por personaje', () async {
    final c = campaign();
    final engine = FakeEngine();
    final lib = ImageLibrary(db, FakeLlm(), settings, root, engineOverride: () => engine);
    lib.ensureScene(c.id!, 'Taberna del Cuervo', description: 'Humo y secretos');
    final missing = lib.missing(c);
    expect(missing.where((r) => r.kind == ImageRecord.portrait), hasLength(2));
    expect(missing.where((r) => r.kind == ImageRecord.fullBody), hasLength(2));
    final done = await lib.generateMissing(c);
    expect(done, 5);
    expect(lib.missing(c), isEmpty);
    expect(lib.fileOf(c.id!, ImageRecord.fullBody, 'Kael')!.existsSync(), isTrue);
    final kael = engine.requests.where((r) => r.prompt.contains('Kael')).toList();
    expect(kael, hasLength(2));
    expect(kael[0].seed, kael[1].seed);
    expect(kael[0].height, greaterThanOrEqualTo(kael[0].width)); // retrato cuadrado
    expect(kael[1].height, greaterThan(kael[1].width)); // cuerpo entero vertical
    final scene = engine.requests.last;
    expect(scene.width, greaterThan(scene.height));
    expect(scene.prompt, contains('Humo y secretos'));
    // El HUD encuentra la escena del lugar actual.
    expect(lib.sceneFor(c)?.subject, 'Taberna del Cuervo');
  });

  test('si el modelo prefiere inglés, la IA traduce la descripción y se guarda', () async {
    final c = campaign();
    final engine = FakeEngine(english: true);
    final llm = FakeLlm(jsonReplies: [
      {'prompt': 'bald suspicious innkeeper, apron, candlelight'},
    ]);
    final lib = ImageLibrary(db, llm, settings, root, engineOverride: () => engine);
    final r = ImageRecord(campaignId: c.id!, kind: ImageRecord.portrait, subject: 'Bran el tabernero');
    await lib.generate(c, r);
    expect(engine.requests.single.prompt, contains('bald suspicious innkeeper'));
    expect(engine.requests.single.prompt, startsWith('portrait'));
    expect(db.image(c.id!, ImageRecord.portrait, 'Bran el tabernero')!.prompt, contains('innkeeper'));
  });

  test('dos fallos seguidos paran la cola y dejan el error a la vista', () async {
    final c = campaign();
    final lib = ImageLibrary(db, FakeLlm(), settings, root, engineOverride: () => FakeEngine(fail: true));
    final n = await lib.generateMissing(c);
    expect(n, 0);
    expect(lib.lastError, contains('roto'));
    expect(lib.busy, isFalse);
  });

  test('el lugar nuevo se apunta como escena y quitar una imagen la deja como «falta»', () async {
    final c = campaign()..location = 'Faro de Velmor';
    settings.imageAuto = false;
    final lib = ImageLibrary(db, FakeLlm(), settings, root, engineOverride: () => FakeEngine());
    final rec = lib.noteLocation(c, narration: '**Bran:** «hola»\nEl faro se alza sobre las rocas. [[lugar: Faro]]')!;
    expect(rec.missing, isTrue);
    expect(rec.description, 'El faro se alza sobre las rocas.');
    final src = File(p.join(tmp.path, 'mia.png'))..writeAsBytesSync(png);
    final set = await lib.setFromFile(c.id!, ImageRecord.sceneKind, 'Faro de Velmor', src.path);
    expect(File(set.path).existsSync(), isTrue);
    expect(p.isWithin(root.images, set.path), isTrue);
    lib.remove(set);
    expect(lib.find(c.id!, ImageRecord.sceneKind, 'Faro de Velmor')!.missing, isTrue);
    expect(File(set.path).existsSync(), isFalse);
  });

  test('sd-cli recibe los argumentos del modelo en piezas', () {
    final e = SdCppEngine(exe: 'sd', model: 'z.gguf', vae: 'ae.safetensors', llm: 'qwen.gguf', steps: 8, cfg: 1.0, tmpDir: tmp.path);
    final a = e.arguments(const ImageRequest(prompt: 'un dragón', negative: 'texto', width: 512, height: 768, seed: 7), 'o.png');
    expect(a, containsAllInOrder(['--diffusion-model', 'z.gguf', '--vae', 'ae.safetensors', '--llm', 'qwen.gguf', '-p', 'un dragón']));
    expect(a, isNot(contains('-n'))); // con cfg 1 el negativo no sirve
    expect(a, containsAllInOrder(['-W', '512', '-H', '768', '--steps', '8']));
    expect(e.prefersEnglish, isFalse);
    final single = SdCppEngine(exe: 'sd', model: 'sd.gguf', tmpDir: tmp.path, cfg: 7);
    expect(single.arguments(const ImageRequest(prompt: 'x', negative: 'y'), 'o.png'), containsAllInOrder(['-m', 'sd.gguf', '-p', 'x', '-n', 'y']));
    expect(single.prefersEnglish, isTrue);
  });

  test('servicio con API de OpenAI: dirección, clave y respuesta en base64', () async {
    late http.Request sent;
    final client = MockClient((req) async {
      sent = req;
      return http.Response(jsonEncode({
        'data': [
          {'b64_json': base64Encode(png)},
        ],
      }), 200);
    });
    final e = OpenAiImageEngine(baseUrl: 'api.ejemplo.com', apiKey: 'k', model: 'm', client: client);
    final bytes = await e.generate(const ImageRequest(prompt: 'castillo', width: 768, height: 512));
    expect(imageExtension(bytes), '.png');
    expect(sent.url.toString(), 'https://api.ejemplo.com/v1/images/generations');
    expect(sent.headers['Authorization'], 'Bearer k');
    expect(jsonDecode(sent.body)['size'], '1536x1024');

    final bad = OpenAiImageEngine(
      baseUrl: 'https://x/v1',
      client: MockClient((_) async => http.Response(jsonEncode({'error': {'message': 'Invalid key'}}), 401)),
    );
    expect(() => bad.generate(const ImageRequest(prompt: 'x')), throwsA(predicate((e) => '$e'.contains('clave no válida'))));
  });

  test('servidor A1111 devuelve la imagen en base64', () async {
    final e = A1111Engine(
      baseUrl: '192.168.1.20:7860',
      client: MockClient((req) async {
        expect(req.url.toString(), 'http://192.168.1.20:7860/sdapi/v1/txt2img');
        return http.Response(jsonEncode({'images': [base64Encode(png)]}), 200);
      }),
    );
    expect(imageExtension(await e.generate(const ImageRequest(prompt: 'x'))), '.png');
  });

  test('las imágenes viajan en el .rolpack, también las escenas que faltan', () async {
    final c = campaign();
    final lib = ImageLibrary(db, FakeLlm(), settings, root, engineOverride: () => FakeEngine());
    final src = File(p.join(tmp.path, 'kael.png'))..writeAsBytesSync(png);
    final portrait = await lib.setFromFile(c.id!, ImageRecord.portrait, 'Kael', src.path);
    lib.ensureScene(c.id!, 'Cripta de los Reyes', description: 'Bajo la abadía');
    lib.pin(c, portrait);
    final out = p.join(tmp.path, 'c.rolpack');
    await StoryPackage.exportToFile(db, c.id!, out, root: root, settings: settings);

    final rootB = DataRoot(p.join(tmp.path, 'B'));
    final dbB = AppDatabase.memory(root: rootB);
    final r = await StoryPackage.importFile(dbB, out, root: rootB, settings: AppSettings(JsonPrefs.memory()));
    expect(r.images, 1);
    final imgs = dbB.images(r.campaign.id!);
    final p2 = imgs.firstWhere((i) => i.kind == ImageRecord.portrait);
    expect(File(p2.path).existsSync(), isTrue);
    expect(p.isWithin(rootB.campaignImages(r.campaign.id!), p2.path), isTrue);
    final crypt = imgs.firstWhere((i) => i.subject == 'Cripta de los Reyes');
    expect(crypt.missing, isTrue);
    expect(crypt.description, 'Bajo la abadía');
    // La imagen fijada se traduce al id nuevo.
    expect(dbB.campaign(r.campaign.id!)!.bible[ImageLibrary.pinnedKey], p2.id);
    dbB.close();
  });
}
