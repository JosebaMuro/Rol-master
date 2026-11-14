import 'dart:io';
import 'dart:typed_data';

import 'package:director_de_rol/core/downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Servidor que redirige (como GitHub) y corta la conexión cada [cut] bytes.
Future<HttpServer> _server(Uint8List data, {int cut = 0, bool range = true, int status = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    if (req.uri.path == '/release') {
      res.redirect(Uri.parse('/blob?sig=secreto'));
      return;
    }
    if (status != 200) {
      res.statusCode = status;
      await res.close();
      return;
    }
    var start = 0;
    final r = req.headers.value(HttpHeaders.rangeHeader);
    if (range && r != null) {
      start = int.parse(r.substring(6, r.length - 1));
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${data.length - 1}/${data.length}');
    }
    res.contentLength = data.length - start;
    final end = cut > 0 ? (start + cut).clamp(0, data.length) : data.length;
    if (end < data.length) {
      final socket = await res.detachSocket();
      socket.add(data.sublist(start, end));
      await socket.flush();
      socket.destroy();
      return;
    }
    res.add(data.sublist(start, end));
    await res.close();
  });
  return server;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dl'));
  tearDown(() => dir.deleteSync(recursive: true));

  final data = Uint8List.fromList(List.generate(300000, (i) => i % 251));

  test('reanuda tras cortes de conexión y sigue la redirección', () async {
    final s = await _server(data, cut: 70000);
    final f = File('${dir.path}/x.part');
    final progress = <double?>[];
    await ResumableDownloader(maxAttempts: 3).download(
      Uri.parse('http://127.0.0.1:${s.port}/release'),
      f,
      onProgress: progress.add,
    );
    await s.close(force: true);
    expect(f.readAsBytesSync(), data);
    expect(progress.last, 1.0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('error corto y sin URL cuando el fichero no existe', () async {
    final s = await _server(data, status: 404);
    final f = File('${dir.path}/y.part');
    try {
      await ResumableDownloader(maxAttempts: 2).download(Uri.parse('http://127.0.0.1:${s.port}/release'), f);
      fail('debía fallar');
    } catch (e) {
      final msg = ResumableDownloader.describe(e);
      expect(msg, contains('404'));
      expect(msg, isNot(contains('http')));
    }
    await s.close(force: true);
  });

  test('describe quita la URL firmada', () {
    final msg = ResumableDownloader.describe(Exception(
        'ClientException: Connection closed while receiving data, uri=https://release-assets.githubusercontent.com/a?sig=x'));
    expect(msg, 'la conexión se cortó');
  });
}
