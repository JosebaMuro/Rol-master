import 'dart:async';
import 'dart:io';

/// Descarga un fichero grande a disco aguantando cortes de conexión.
///
/// Las descargas de GitHub redirigen a una URL firmada que caduca y los
/// móviles cortan a menudo la conexión a mitad (Wi-Fi que se duerme, cambio a
/// datos...). Por eso cada intento vuelve a pedir la URL original y continúa
/// donde se quedó con una cabecera `Range`, hasta [maxAttempts] veces
/// seguidas sin avanzar.
class ResumableDownloader {
  ResumableDownloader({
    this.maxAttempts = 6,
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 45),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final int maxAttempts;
  final Duration connectTimeout;

  /// Si no llega ningún dato en este tiempo se da por cortada la conexión.
  final Duration idleTimeout;
  final HttpClient Function() _clientFactory;

  /// Descarga [url] en [dest]. [onProgress] recibe la fracción (0–1) o null
  /// si no se conoce el tamaño. Si [dest] ya existe a medias, se reanuda.
  Future<void> download(Uri url, File dest, {void Function(double? progress)? onProgress}) async {
    var failures = 0;
    Object? lastError;
    while (true) {
      final before = dest.existsSync() ? dest.lengthSync() : 0;
      try {
        final complete = await _attempt(url, dest, onProgress);
        if (complete) return;
      } on _FatalDownloadError {
        rethrow;
      } catch (e) {
        lastError = e;
      }
      final after = dest.existsSync() ? dest.lengthSync() : 0;
      // Sólo cuentan los intentos que no avanzan: una conexión que se corta
      // cada pocos MB acaba bajando el fichero entero.
      failures = after > before ? 0 : failures + 1;
      if (failures >= maxAttempts) {
        throw DownloadException(describe(lastError ?? 'la descarga no termina'));
      }
      await Future<void>.delayed(Duration(seconds: 2 * (failures + 1)));
    }
  }

  /// Devuelve true si el fichero quedó completo.
  Future<bool> _attempt(Uri url, File dest, void Function(double?)? onProgress) async {
    final client = _clientFactory()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = idleTimeout;
    IOSink? sink;
    try {
      final have = dest.existsSync() ? dest.lengthSync() : 0;
      final req = await client.getUrl(url);
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close().timeout(connectTimeout);

      int? total;
      var received = 0;
      if (res.statusCode == HttpStatus.partialContent && have > 0) {
        received = have;
        final range = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        total = int.tryParse(range.split('/').last);
        sink = dest.openWrite(mode: FileMode.append);
      } else if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
        // Ya estaba entero.
        await res.drain<void>();
        return true;
      } else if (res.statusCode == HttpStatus.ok) {
        total = res.contentLength > 0 ? res.contentLength : null;
        sink = dest.openWrite(); // el servidor no reanuda: se empieza de cero
      } else {
        await res.drain<void>();
        final msg = 'el servidor respondió ${res.statusCode}';
        if (res.statusCode == 404 || res.statusCode == 403 || res.statusCode == 410) throw _FatalDownloadError(msg);
        throw HttpException(msg);
      }

      await for (final chunk in res.timeout(idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total != null && total > 0 ? received / total : null);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total != null && received < total) throw const HttpException('la conexión se cortó');
      return true;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// Mensaje corto y legible (sin la URL firmada, que ocupa media pantalla).
  static String describe(Object e) {
    if (e is DownloadException) return e.message;
    if (e is _FatalDownloadError) return e.message;
    if (e is TimeoutException) return 'la conexión se quedó parada';
    if (e is SocketException) return 'sin conexión a Internet (${e.osError?.message ?? e.message})';
    if (e is HandshakeException) return 'fallo de conexión segura';
    if (e is HttpException) {
      final m = e.message;
      return m.contains('Connection closed') ? 'la conexión se cortó' : m;
    }
    var s = '$e';
    s = s.replaceAll(RegExp(r',?\s*uri=\S+'), '').replaceAll(RegExp(r'https?://\S+'), '').trim();
    if (s.contains('Connection closed')) return 'la conexión se cortó';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _FatalDownloadError implements Exception {
  _FatalDownloadError(this.message);
  final String message;
  @override
  String toString() => message;
}
