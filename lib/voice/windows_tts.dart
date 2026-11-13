import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Voz del sistema en Windows sin el plugin flutter_tts (que cierra la app al
/// llamar a stop() cuando no hay nada sonando).
///
/// Mantiene abierto un proceso de Windows PowerShell que sintetiza cada frase
/// a un WAV con el motor de Windows (voces OneCore, las de Configuración ›
/// Voz) y, si no está disponible, con System.Speech (SAPI). La reproducción
/// la hace la app, así que parar es siempre seguro.
class WindowsTts {
  WindowsTts({required this.scriptDir});

  /// Carpeta donde se escribe el script de PowerShell.
  final String scriptDir;
  Process? _proc;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _next = 0;
  Future<void>? _starting;

  static const _script = r'''
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$winrt = $null
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $winrt = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
} catch { $winrt = $null }
$sapi = $null
try { Add-Type -AssemblyName System.Speech; $sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer } catch { }

function Out-Json($o) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 4)); [Console]::Out.Flush() }

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($line -eq $null) { break }
  $req = $line | ConvertFrom-Json
  try {
    if ($req.cmd -eq 'voices') {
      $list = @()
      if ($winrt) {
        foreach ($v in [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) {
          $list += @{ name = $v.DisplayName; locale = $v.Language; gender = "$($v.Gender)"; engine = 'winrt' }
        }
      }
      if ($sapi) {
        foreach ($v in $sapi.GetInstalledVoices()) {
          $i = $v.VoiceInfo
          if (-not ($list | Where-Object { $_.name -eq $i.Name })) {
            $list += @{ name = $i.Name; locale = $i.Culture.Name; gender = "$($i.Gender)"; engine = 'sapi' }
          }
        }
      }
      Out-Json @{ id = $req.id; voices = $list }
    } elseif ($req.cmd -eq 'speak') {
      $done = $false
      if ($winrt) {
        $voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.DisplayName -eq $req.voice } | Select-Object -First 1
        if (-not $voice -and $req.locale) { $voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.Language -like "$($req.locale.Substring(0,2))*" } | Select-Object -First 1 }
        if ($voice) {
          $winrt.Voice = $voice
          $winrt.Options.AudioPitch = [double]$req.pitch
          $winrt.Options.SpeakingRate = [double]$req.rate
          $op = $winrt.SynthesizeTextToStreamAsync([string]$req.text)
          $task = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream]).Invoke($null, @($op))
          $task.Wait()
          $stream = $task.Result
          $in = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
          $out = [System.IO.File]::Create($req.out)
          $in.CopyTo($out); $out.Close(); $in.Close(); $stream.Dispose()
          $done = $true
        }
      }
      if (-not $done -and $sapi) {
        try { if ($req.voice) { $sapi.SelectVoice($req.voice) } } catch { }
        $sapi.Rate = [int][Math]::Max(-10, [Math]::Min(10, ([double]$req.rate - 1) * 10))
        $sapi.SetOutputToWaveFile($req.out)
        $pb = New-Object System.Speech.Synthesis.PromptBuilder
        $pct = [int](([double]$req.pitch - 1) * 50)
        $pb.AppendSsmlMarkup("<prosody pitch=`"$($pct)%`">" + [Security.SecurityElement]::Escape([string]$req.text) + "</prosody>")
        $sapi.Speak($pb)
        $sapi.SetOutputToNull()
        $done = $true
      }
      if ($done) { Out-Json @{ id = $req.id; ok = $true } } else { Out-Json @{ id = $req.id; error = 'No hay voces del sistema' } }
    }
  } catch {
    Out-Json @{ id = $req.id; error = "$($_.Exception.Message)" }
  }
}
''';

  Future<void> _ensure() {
    if (_proc != null) return Future.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      await _launch();
    } catch (e) {
      _starting = null;
      rethrow;
    }
  }

  Future<void> _launch() async {
    Directory(scriptDir).createSync(recursive: true);
    final script = File(p.join(scriptDir, 'voz_windows.ps1'));
    script.writeAsStringSync(_script.replaceAll('\r', '').replaceAll('\n', '\r\n'));
    final proc = await Process.start(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path],
      runInShell: false,
    );
    proc.stdin.encoding = utf8;
    // Si el proceso muere, escribir en su entrada no debe tumbar la app.
    unawaited(proc.stdin.done.catchError((_) {}));
    _proc = proc;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = (jsonDecode(line.replaceAll('\uFEFF', '').trim()) as Map).cast<String, dynamic>();
        _pending.remove((m['id'] as num).toInt())?.complete(m);
      } catch (_) {
        debugPrint('WindowsTts: $line');
      }
    });
    proc.stderr.transform(utf8.decoder).listen((e) => debugPrint('WindowsTts error: $e'));
    unawaited(proc.exitCode.then((_) {
      _proc = null;
      _starting = null;
      for (final c in _pending.values) {
        if (!c.isCompleted) c.complete({'error': 'El proceso de voz terminó'});
      }
      _pending.clear();
    }));
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> req, {Duration timeout = const Duration(seconds: 60)}) async {
    await _ensure();
    final id = _next++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final proc = _proc;
    if (proc == null) return {'error': 'El proceso de voz no está activo'};
    try {
      proc.stdin.writeln(jsonEncode({...req, 'id': id}));
      await proc.stdin.flush();
    } catch (e) {
      _pending.remove(id);
      return {'error': 'No se pudo hablar con el proceso de voz: $e'};
    }
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      return {'error': 'Tiempo de espera agotado'};
    });
  }

  /// Voces instaladas: [{name, locale, gender, engine}].
  Future<List<Map<String, String>>> voices() async {
    try {
      final r = await _call({'cmd': 'voices'}, timeout: const Duration(seconds: 30));
      final v = r['voices'];
      final list = v is List ? v : (v is Map ? [v] : const []);
      return [
        for (final e in list.whereType<Map>()) e.map((k, val) => MapEntry('$k', '$val')),
      ];
    } catch (e) {
      debugPrint('WindowsTts voices: $e');
      return const [];
    }
  }

  /// Sintetiza [text] en [outPath] (WAV). [pitch] 0–2 y [rate] 0,5–3 (1 = normal).
  Future<void> synthesize({
    required String text,
    required String outPath,
    String voice = '',
    String locale = 'es-ES',
    double pitch = 1.0,
    double rate = 1.0,
  }) async {
    final r = await _call({
      'cmd': 'speak',
      'text': text,
      'out': outPath,
      'voice': voice,
      'locale': locale,
      'pitch': pitch.clamp(0.0, 2.0),
      'rate': rate.clamp(0.5, 3.0),
    });
    if (r['error'] != null) throw Exception(r['error']);
  }

  void dispose() {
    _proc?.kill();
    _proc = null;
  }
}
