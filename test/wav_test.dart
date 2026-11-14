import 'dart:typed_data';

import 'package:director_de_rol/voice/win_native.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _wav({required int sampleRate, required int seconds, int dataSizeField = -1, bool extraChunk = false}) {
  final dataLen = sampleRate * 2 * seconds;
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  str('RIFF');
  u32(36 + dataLen);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  if (extraChunk) {
    str('LIST');
    u32(3);
    b.add([1, 2, 3, 0]);
  }
  str('data');
  u32(dataSizeField >= 0 ? dataSizeField : dataLen);
  b.add(Uint8List(dataLen));
  return b.toBytes();
}

void main() {
  test('duración de un WAV normal', () {
    expect(WinNative.wavDuration(_wav(sampleRate: 22050, seconds: 2)), const Duration(seconds: 2));
  });
  test('chunks extra y tamaño de datos sin rellenar', () {
    expect(WinNative.wavDuration(_wav(sampleRate: 16000, seconds: 3, dataSizeField: 0, extraChunk: true)), const Duration(seconds: 3));
    expect(WinNative.wavDuration(_wav(sampleRate: 16000, seconds: 1, dataSizeField: 0xFFFFFFFF)), const Duration(seconds: 1));
  });
  test('audio vacío', () {
    expect(() => WinNative.wavDuration(Uint8List(10)), throwsException);
  });
}
