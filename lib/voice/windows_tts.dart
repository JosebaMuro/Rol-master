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
try { [Console]::InputEncoding = $utf8 } catch { }
try { [Console]::OutputEncoding = $utf8 } catch { }
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true
$winrt = $null
$winrtError = ''
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesisStream, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $winrt = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
} catch { $winrt = $null; $winrtError = "$($_.Exception.Message)" }
$sapi = $null
$sapiError = ''
try { Add-Type -AssemblyName System.Speech; $sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer } catch { $sapiError = "$($_.Exception.Message)" }

function Out-Json($o) { $stdout.WriteLine(($o | ConvertTo-Json -Compress -Depth 4)) }

function Speak-WinRT($req) {
  $all = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices
  $voice = $all | Where-Object { $_.DisplayName -eq $req.voice } | Select-Object -First 1
  if (-not $voice -and $req.voice) { $voice = $all | Where-Object { $req.voice -like "*$($_.DisplayName)*" -or $_.DisplayName -like "*$($req.voice)*" } | Select-Object -First 1 }
  if (-not $voice -and $req.locale) { $voice = $all | Where-Object { $_.Language -like "$($req.locale.Substring(0,2))*" } | Select-Object -First 1 }
  if (-not $voice) { $voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::DefaultVoice }
  if (-not $voice) { throw 'no hay voces OneCore instaladas' }
  $winrt.Voice = $voice
  # Tono y velocidad existen desde Windows 10 1803; en versiones viejas se omiten.
  try { $winrt.Options.AudioPitch = [double]$req.pitch } catch { }
  try { $winrt.Options.SpeakingRate = [double]$req.rate } catch { }
  $op = $winrt.SynthesizeTextToStreamAsync([string]$req.text)
  $task = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream]).Invoke($null, @($op))
  if (-not $task.Wait(60000)) { throw 'la síntesis tardó demasiado' }
  $stream = $task.Result
  $in = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
  $out = [System.IO.File]::Create($req.out)
  try { $in.CopyTo($out) } finally { $out.Close(); $in.Close(); $stream.Dispose() }
  if ((Get-Item -LiteralPath $req.out).Length -lt 100) { throw 'el audio salió vacío' }
}

function Speak-Sapi($req) {
  if ($req.voice) {
    $match = $sapi.GetInstalledVoices() | Where-Object { $_.Enabled -and ($_.VoiceInfo.Name -eq $req.voice -or $_.VoiceInfo.Name -like "*$($req.voice)*" -or $req.voice -like "*$($_.VoiceInfo.Name)*") } | Select-Object -First 1
    if ($match) { $sapi.SelectVoice($match.VoiceInfo.Name) }
  }
  $sapi.Rate = [int][Math]::Max(-10, [Math]::Min(10, ([double]$req.rate - 1) * 10))
  $sapi.SetOutputToWaveFile($req.out)
  try {
    $pb = New-Object System.Speech.Synthesis.PromptBuilder
    $pct = [int](([double]$req.pitch - 1) * 50)
    $sign = if ($pct -ge 0) { '+' } else { '' }
    try {
      $pb.AppendSsmlMarkup("<prosody pitch=`"$sign$($pct)%`">" + [Security.SecurityElement]::Escape([string]$req.text) + "</prosody>")
    } catch {
      $pb = New-Object System.Speech.Synthesis.PromptBuilder
      $pb.AppendText([string]$req.text)
    }
    $sapi.Speak($pb)
  } finally { $sapi.SetOutputToNull() }
}

while ($true) {
  $line = $stdin.ReadLine()
  if ($line -eq $null) { break }
  if (-not $line.Trim()) { continue }
  $req = $null
  try {
    $req = $line | ConvertFrom-Json
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
          if (-not $v.Enabled) { continue }
          if (-not ($list | Where-Object { $_.name -eq $i.Name -or $i.Name -like "$($_.name)*" })) {
            $list += @{ name = $i.Name; locale = $i.Culture.Name; gender = "$($i.Gender)"; engine = 'sapi' }
          }
        }
      }
      Out-Json @{ id = $req.id; voices = $list; winrtError = $winrtError; sapiError = $sapiError }
    } elseif ($req.cmd -eq 'speak') {
      $errors = @()
      $done = $false
      if ($winrt) {
        try { Speak-WinRT $req; $done = $true } catch { $errors += "OneCore: $($_.Exception.Message)" }
      } elseif ($winrtError) { $errors += "OneCore: $winrtError" }
      if (-not $done -and $sapi) {
        try { Speak-Sapi $req; $done = $true } catch { $errors += "SAPI: $($_.Exception.Message)" }
      } elseif (-not $done -and $sapiError) { $errors += "SAPI: $sapiError" }
      if ($done) { Out-Json @{ id = $req.id; ok = $true } }
      elseif ($errors.Count -gt 0) { Out-Json @{ id = $req.id; error = ($errors -join ' | ') } }
      else { Out-Json @{ id = $req.id; error = 'No hay voces del sistema instaladas' } }
    } elseif ($req.cmd -eq 'ping') {
      Out-Json @{ id = $req.id; ok = $true }
    }
  } catch {
    $rid = if ($req) { $req.id } else { -1 }
    Out-Json @{ id = $rid; error = "$($_.Exception.Message)" }
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

  /// Último error del motor de voz de Windows (para mostrarlo al usuario).
  String? lastError;
  final _stderr = StringBuffer();

  static String get _powershell {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final full = p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    return File(full).existsSync() ? full : 'powershell.exe';
  }

  Future<void> _launch() async {
    Directory(scriptDir).createSync(recursive: true);
    final script = File(p.join(scriptDir, 'voz_windows.ps1'));
    // Con BOM: Windows PowerShell 5.1 lee como ANSI los .ps1 UTF-8 sin BOM.
    script.writeAsStringSync('\uFEFF${_script.replaceAll('\r', '').replaceAll('\n', '\r\n')}');
    _stderr.clear();
    final proc = await Process.start(
      _powershell,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ],
      runInShell: false,
    );
    // Si el proceso muere, escribir en su entrada no debe tumbar la app.
    unawaited(proc.stdin.done.catchError((_) {}));
    _proc = proc;
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final t = line.replaceAll('\uFEFF', '').trim();
      if (t.isEmpty) return;
      try {
        final m = (jsonDecode(t) as Map).cast<String, dynamic>();
        _pending.remove((m['id'] as num).toInt())?.complete(m);
      } catch (_) {
        debugPrint('WindowsTts: $line');
      }
    }, onError: (_) {});
    proc.stderr.transform(utf8.decoder).listen((e) {
      debugPrint('WindowsTts error: $e');
      if (_stderr.length < 4000) _stderr.write(e);
    }, onError: (_) {});
    unawaited(proc.exitCode.then((code) {
      _proc = null;
      _starting = null;
      final err = _stderr.toString().trim();
      final msg = 'El proceso de voz de Windows terminó (código $code)${err.isEmpty ? '' : ': $err'}';
      lastError = msg;
      for (final c in _pending.values) {
        if (!c.isCompleted) c.complete({'error': msg});
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
      proc.stdin.add(utf8.encode('${jsonEncode({...req, 'id': id})}\n'));
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
      final r = await _call({'cmd': 'voices'}, timeout: const Duration(seconds: 45));
      if (r['error'] != null) {
        lastError = '${r['error']}';
        return const [];
      }
      final v = r['voices'];
      final list = v is List ? v : (v is Map ? [v] : const []);
      if (list.isEmpty) {
        final why = [r['winrtError'], r['sapiError']].where((e) => e != null && '$e'.isNotEmpty).join(' | ');
        lastError = 'Windows no tiene voces instaladas${why.isEmpty ? '' : ' ($why)'}. Añádelas en Configuración › Hora e idioma › Voz.';
      }
      return [
        for (final e in list.whereType<Map>()) e.map((k, val) => MapEntry('$k', '$val')),
      ];
    } catch (e) {
      lastError = '$e';
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
    if (r['error'] != null) {
      lastError = '${r['error']}';
      throw Exception(r['error']);
    }
    lastError = null;
  }

  void dispose() {
    _proc?.kill();
    _proc = null;
  }
}
