import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Utilidades nativas de Windows para las voces, sin plugins:
///
/// * [play] reproduce un WAV con `PlaySoundW` (winmm), el reproductor más
///   básico y fiable de Windows. Así la voz no depende de Media Foundation
///   (audioplayers), que en algunos equipos no sonaba o no avisaba al acabar.
/// * [safePath] convierte rutas con tildes o eñes a su nombre corto 8.3:
///   sherpa-onnx y espeak-ng abren los ficheros con la página de códigos
///   ANSI y fallan (o cierran la app) con rutas que no son ASCII.
class WinNative {
  WinNative._();

  static const _sndAsync = 0x0001;
  static const _sndNoDefault = 0x0002;
  static const _sndFilename = 0x00020000;

  static final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final int Function(Pointer<Utf16>, int, int) _playSound =
      _winmm.lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Uint32), int Function(Pointer<Utf16>, int, int)>('PlaySoundW');

  static final int Function(Pointer<Utf16>, Pointer<Utf16>, int) _getShortPathName = _kernel32
      .lookupFunction<Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, Pointer<Utf16>, int)>(
          'GetShortPathNameW');

  static Completer<void>? _current;

  /// Reproduce [path] (WAV PCM) y espera a que termine o a que se llame a
  /// [stop]. Lanza una excepción si Windows no puede reproducirlo.
  static Future<void> play(String path) async {
    stop();
    final duration = wavDuration(File(path).readAsBytesSync());
    final name = path.toNativeUtf16();
    final ok = _playSound(name, 0, _sndFilename | _sndAsync | _sndNoDefault);
    malloc.free(name);
    if (ok == 0) throw Exception('Windows no pudo reproducir el audio (¿hay altavoces o auriculares activos?)');
    final done = Completer<void>();
    _current = done;
    final timer = Timer(duration + const Duration(milliseconds: 200), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    timer.cancel();
    if (identical(_current, done)) _current = null;
  }

  /// Corta el audio que se esté reproduciendo.
  static void stop() {
    try {
      _playSound(nullptr, 0, 0);
    } catch (_) {}
    final c = _current;
    _current = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Duración de un WAV a partir de su cabecera.
  static Duration wavDuration(Uint8List bytes) {
    if (bytes.length < 44) throw Exception('El audio generado está vacío');
    final data = ByteData.sublistView(bytes);
    var byteRate = 0;
    var dataSize = 0;
    var pos = 12;
    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
      var size = data.getUint32(pos + 4, Endian.little);
      if (id == 'fmt ' && pos + 16 <= bytes.length) byteRate = data.getUint32(pos + 16, Endian.little);
      if (id == 'data') {
        // Algunos motores dejan el tamaño a 0 o a 0xFFFFFFFF: se usa lo que hay.
        final rest = bytes.length - pos - 8;
        if (size == 0 || size > rest) size = rest;
        dataSize = size;
        break;
      }
      pos += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (byteRate <= 0 || dataSize <= 0) throw Exception('El audio generado está vacío o no es un WAV válido');
    return Duration(microseconds: (dataSize * 1000000 / byteRate).round());
  }

  static bool _isAscii(String s) => s.codeUnits.every((c) => c < 128);

  /// Ruta equivalente sólo con caracteres ASCII (nombre corto 8.3) si la
  /// original tiene tildes, eñes, etc. Si el fichero aún no existe se acorta
  /// la carpeta que lo contiene. Si Windows no tiene nombres cortos en ese
  /// disco, devuelve la ruta tal cual.
  static String safePath(String path) {
    if (!Platform.isWindows || path.isEmpty || _isAscii(path)) return path;
    if (!File(path).existsSync() && !Directory(path).existsSync()) {
      final sep = path.lastIndexOf(RegExp(r'[\\/]'));
      if (sep <= 0) return path;
      final dir = safePath(path.substring(0, sep));
      return '$dir\\${path.substring(sep + 1)}';
    }
    final input = path.toNativeUtf16();
    final buf = malloc<Uint16>(32768).cast<Utf16>();
    try {
      final n = _getShortPathName(input, buf, 32768);
      if (n == 0 || n >= 32768) return path;
      return buf.toDartString(length: n);
    } finally {
      malloc.free(input);
      malloc.free(buf);
    }
  }
}
