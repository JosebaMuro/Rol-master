import 'package:director_de_rol/ai/llama_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

GpuDeviceInfo gpu(GpuBackend b, int i, String name, GpuDeviceType type, int gb) => GpuDeviceInfo(
      backend: b,
      mainGpu: i,
      name: '${b.name}$i',
      description: name,
      deviceId: '$i',
      type: type,
      memoryFreeBytes: gb << 30,
      memoryTotalBytes: gb << 30,
    );

void main() {
  const nvidia = 'NVIDIA GeForce RTX 4070';
  const intel = 'Intel(R) UHD Graphics 770';

  test('con NVIDIA y CUDA incluido, Auto elige CUDA', () {
    final c = GpuChoice.pick([
      gpu(GpuBackend.vulkan, 0, nvidia, GpuDeviceType.discreteGpu, 12),
      gpu(GpuBackend.cuda, 0, nvidia, GpuDeviceType.discreteGpu, 12),
    ], 'auto')!;
    expect(c.backend, GpuBackend.cuda);
    expect(c.devices, isNull);
    expect(c.label, contains('CUDA'));
    expect(c.label, contains(nvidia));
  });

  test('sin CUDA usa Vulkan y prefiere la dedicada a la integrada', () {
    final c = GpuChoice.pick([
      gpu(GpuBackend.vulkan, 0, intel, GpuDeviceType.integratedGpu, 16),
      gpu(GpuBackend.vulkan, 1, nvidia, GpuDeviceType.discreteGpu, 8),
    ], 'auto')!;
    expect(c.backend, GpuBackend.vulkan);
    expect(c.devices, [1]);
    expect(c.label, contains(nvidia));
  });

  test('respeta el backend elegido en Ajustes', () {
    final gpus = [
      gpu(GpuBackend.vulkan, 0, nvidia, GpuDeviceType.discreteGpu, 12),
      gpu(GpuBackend.cuda, 0, nvidia, GpuDeviceType.discreteGpu, 12),
    ];
    expect(GpuChoice.pick(gpus, 'vulkan')!.backend, GpuBackend.vulkan);
    expect(GpuChoice.pick(gpus, 'cpu'), isNull);
  });

  test('sin GPU no elige nada (se queda en CPU)', () {
    expect(GpuChoice.pick(const [], 'auto'), isNull);
  });
}
