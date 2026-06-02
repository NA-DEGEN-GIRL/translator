import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koja_translator/services/realtime_transcription_ws_service.dart';

const _defaultEnvFiles = ['.env', '.env.flutter'];

void main(List<String> args) async {
  late final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final dotenv = _loadDotenv(options.envFile);
  final apiKey =
      Platform.environment['OPENAI_API_KEY'] ?? dotenv['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.trim().isEmpty) {
    stderr.writeln('OPENAI_API_KEY is required in the environment or .env.');
    exitCode = 64;
    return;
  }

  final file = File(options.filePath);
  if (!file.existsSync()) {
    stderr.writeln('Audio file not found: ${file.path}');
    exitCode = 66;
    return;
  }

  final wav = _readPcm16Wav(file);
  final results = <_RunResult>[];
  stdout.writeln('Realtime STT benchmark');
  stdout.writeln('file=${file.path}');
  stdout.writeln('bytes=${wav.pcm.length}');
  stdout.writeln('sampleRate=${wav.sampleRate}');
  stdout.writeln('channels=${wav.channels}');
  stdout.writeln('duration=${wav.durationMs}ms');
  stdout.writeln('lang=${options.language}');
  stdout.writeln('delay=${options.delay}');
  stdout.writeln('chunkMs=${options.chunkMs}');
  stdout.writeln('realtimePlayback=${options.realtimePlayback}');
  stdout.writeln('runs=${options.runs}, warmup=${options.warmup}');
  stdout.writeln('');

  for (var run = 1; run <= options.warmup + options.runs; run++) {
    final warmup = run <= options.warmup;
    final visibleRun = warmup ? 'warmup-$run' : '${run - options.warmup}';
    final result = await _runOne(apiKey.trim(), wav, options, run, warmup);
    _printResult(result, visibleRun: visibleRun);
    if (!warmup) results.add(result);
  }

  _printSummary(results);
}

Future<_RunResult> _runOne(
  String apiKey,
  _WavData wav,
  _Options options,
  int run,
  bool warmup,
) async {
  final clock = Stopwatch()..start();
  int? firstDeltaMs;
  var deltaChars = 0;
  var readyMs = 0;
  var audioSentMs = 0;
  final service = RealtimeTranscriptionWsService(
    apiKey: apiKey,
    language: options.language,
    delay: options.delay,
    noiseReduction: options.noiseReduction,
    prompt: options.prompt,
    onDelta: (delta) {
      if (delta.isEmpty) return;
      deltaChars += delta.length;
      firstDeltaMs ??= clock.elapsedMilliseconds;
    },
  );

  try {
    final startFuture = service.start().then((_) {
      readyMs = clock.elapsedMilliseconds;
    });
    final bytesPerMs = wav.sampleRate * wav.channels * 2 / 1000;
    final frameBytes = wav.channels * 2;
    final rawChunkBytes = (bytesPerMs * options.chunkMs).round();
    final chunkBytes = max(
      frameBytes,
      rawChunkBytes - rawChunkBytes % frameBytes,
    );

    for (var offset = 0; offset < wav.pcm.length; offset += chunkBytes) {
      final end = min(offset + chunkBytes, wav.pcm.length);
      service.appendPcm16(Uint8List.sublistView(wav.pcm, offset, end));
      if (options.realtimePlayback) {
        final durationMs = ((end - offset) / bytesPerMs).round();
        await Future<void>.delayed(Duration(milliseconds: durationMs));
      }
    }
    await startFuture;
    audioSentMs = clock.elapsedMilliseconds;
    final text = await service.commitAndWait();
    final doneMs = clock.elapsedMilliseconds;
    return _RunResult(
      run: run,
      warmup: warmup,
      readyMs: readyMs,
      firstDeltaMs: firstDeltaMs,
      audioSentMs: audioSentMs,
      doneMs: doneMs,
      postAudioDoneMs: doneMs - audioSentMs,
      chars: text.length,
      deltaChars: deltaChars,
      error: null,
    );
  } catch (error) {
    return _RunResult(
      run: run,
      warmup: warmup,
      readyMs: readyMs,
      firstDeltaMs: firstDeltaMs,
      audioSentMs: audioSentMs,
      doneMs: clock.elapsedMilliseconds,
      postAudioDoneMs: audioSentMs == 0
          ? null
          : clock.elapsedMilliseconds - audioSentMs,
      chars: 0,
      deltaChars: deltaChars,
      error: error.toString(),
    );
  } finally {
    unawaited(service.stop());
  }
}

void _printResult(_RunResult result, {required String visibleRun}) {
  stdout.writeln(
    [
      'run=$visibleRun',
      'ready=${result.readyMs}ms',
      'first=${result.firstDeltaMs == null ? 'n/a' : '${result.firstDeltaMs}ms'}',
      'audio_sent=${result.audioSentMs}ms',
      'done=${result.doneMs}ms',
      'post_audio=${result.postAudioDoneMs == null ? 'n/a' : '${result.postAudioDoneMs}ms'}',
      'chars=${result.chars}',
      'deltaChars=${result.deltaChars}',
      if (result.error != null) 'error=${result.error}',
    ].join(' '),
  );
}

void _printSummary(List<_RunResult> results) {
  if (results.isEmpty) return;
  final ok = results.where((r) => r.error == null).toList();
  if (ok.isEmpty) {
    stdout.writeln('summary ok=0/${results.length}');
    return;
  }
  stdout.writeln('summary ok=${ok.length}/${results.length}');
  _printMetric('ready', ok.map((r) => r.readyMs).toList());
  _printMetric(
    'first',
    ok.map((r) => r.firstDeltaMs).whereType<int>().toList(),
  );
  _printMetric('audio_sent', ok.map((r) => r.audioSentMs).toList());
  _printMetric('done', ok.map((r) => r.doneMs).toList());
  _printMetric(
    'post_audio',
    ok.map((r) => r.postAudioDoneMs).whereType<int>().toList(),
  );
}

void _printMetric(String label, List<int> values) {
  if (values.isEmpty) {
    stdout.writeln('$label=n/a');
    return;
  }
  stdout.writeln(
    '$label avg=${_avg(values).round()}ms med=${_median(values).round()}ms '
    'min=${values.reduce(min)}ms max=${values.reduce(max)}ms',
  );
}

_WavData _readPcm16Wav(File file) {
  final bytes = file.readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  if (_ascii(bytes, 0, 4) != 'RIFF' || _ascii(bytes, 8, 12) != 'WAVE') {
    throw FormatException('Not a WAV file: ${file.path}');
  }

  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = _ascii(bytes, offset, offset + 4);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      final audioFormat = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
      if (audioFormat != 1) {
        throw FormatException('Only PCM WAV is supported: ${file.path}');
      }
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = size == 0xFFFFFFFF ? bytes.length - body : size;
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (sampleRate == null ||
      channels == null ||
      bitsPerSample == null ||
      dataOffset == null ||
      dataLength == null) {
    throw FormatException('Invalid WAV file: ${file.path}');
  }
  if (bitsPerSample != 16) {
    throw FormatException('Only 16-bit WAV is supported: ${file.path}');
  }

  return _WavData(
    pcm: Uint8List.sublistView(bytes, dataOffset, dataOffset + dataLength),
    sampleRate: sampleRate,
    channels: channels,
  );
}

String _ascii(Uint8List bytes, int start, int end) {
  return ascii.decode(bytes.sublist(start, end), allowInvalid: true);
}

Map<String, String> _loadDotenv(String? explicitPath) {
  final paths = explicitPath == null ? _defaultEnvFiles : [explicitPath];
  final values = <String, String>{};

  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    for (final rawLine in file.readAsLinesSync()) {
      final parsed = _parseEnvLine(rawLine);
      if (parsed == null) continue;
      values[parsed.key] = parsed.value;
    }
  }

  return values;
}

({String key, String value})? _parseEnvLine(String rawLine) {
  var line = rawLine.trim();
  if (line.isEmpty || line.startsWith('#')) return null;
  if (line.startsWith('export ')) line = line.substring(7).trim();
  if (line.startsWith('--dart-define=')) {
    line = line.substring('--dart-define='.length).trim();
  }

  final separator = line.indexOf('=');
  if (separator <= 0) return null;
  final key = line.substring(0, separator).trim();
  var value = line.substring(separator + 1).trim();
  if (key.isEmpty) return null;
  final hashIndex = value.indexOf(' #');
  if (hashIndex >= 0) value = value.substring(0, hashIndex).trimRight();
  if (value.length >= 2) {
    final quote = value[0];
    if ((quote == '"' || quote == "'") && value.endsWith(quote)) {
      value = value.substring(1, value.length - 1);
      if (quote == '"') {
        value = value
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', '\\');
      }
    }
  }
  return (key: key, value: value);
}

double _avg(List<int> values) {
  return values.reduce((a, b) => a + b) / values.length;
}

double _median(List<int> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid].toDouble();
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

class _WavData {
  final Uint8List pcm;
  final int sampleRate;
  final int channels;

  const _WavData({
    required this.pcm,
    required this.sampleRate,
    required this.channels,
  });

  int get durationMs =>
      (pcm.length / (sampleRate * channels * 2) * 1000).round();
}

class _Options {
  final bool help;
  final String filePath;
  final String language;
  final String delay;
  final String noiseReduction;
  final String? prompt;
  final int chunkMs;
  final bool realtimePlayback;
  final int runs;
  final int warmup;
  final String? envFile;

  const _Options({
    required this.help,
    required this.filePath,
    required this.language,
    required this.delay,
    required this.noiseReduction,
    required this.prompt,
    required this.chunkMs,
    required this.realtimePlayback,
    required this.runs,
    required this.warmup,
    required this.envFile,
  });

  factory _Options.parse(List<String> args) {
    var help = false;
    var filePath = '.dart_tool/stt_benchmark_sample.wav';
    var language = 'ko';
    var delay = 'minimal';
    var noiseReduction = 'near_field';
    String? prompt;
    var chunkMs = 100;
    var realtimePlayback = true;
    var runs = 3;
    var warmup = 1;
    String? envFile;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String readValue(String name) {
        if (arg.contains('=')) return arg.substring(arg.indexOf('=') + 1);
        if (i + 1 >= args.length) {
          throw FormatException('Missing value for $name');
        }
        i++;
        return args[i];
      }

      if (arg == '-h' || arg == '--help') {
        help = true;
      } else if (arg == '--file' || arg.startsWith('--file=')) {
        filePath = readValue('--file');
      } else if (arg == '--lang' || arg.startsWith('--lang=')) {
        language = readValue('--lang');
      } else if (arg == '--delay' || arg.startsWith('--delay=')) {
        delay = readValue('--delay');
      } else if (arg == '--noise-reduction' ||
          arg.startsWith('--noise-reduction=')) {
        noiseReduction = readValue('--noise-reduction');
      } else if (arg == '--prompt' || arg.startsWith('--prompt=')) {
        prompt = readValue('--prompt');
      } else if (arg == '--chunk-ms' || arg.startsWith('--chunk-ms=')) {
        chunkMs = int.parse(readValue('--chunk-ms'));
      } else if (arg == '--runs' || arg.startsWith('--runs=')) {
        runs = int.parse(readValue('--runs'));
      } else if (arg == '--warmup' || arg.startsWith('--warmup=')) {
        warmup = int.parse(readValue('--warmup'));
      } else if (arg == '--env-file' || arg.startsWith('--env-file=')) {
        envFile = readValue('--env-file');
      } else if (arg == '--fast-send') {
        realtimePlayback = false;
      } else {
        throw FormatException('Unknown argument: $arg');
      }
    }

    if (chunkMs < 10) throw const FormatException('--chunk-ms must be >= 10');
    if (runs < 1) throw const FormatException('--runs must be >= 1');
    if (warmup < 0) throw const FormatException('--warmup must be >= 0');

    return _Options(
      help: help,
      filePath: filePath,
      language: language,
      delay: delay,
      noiseReduction: noiseReduction,
      prompt: prompt,
      chunkMs: chunkMs,
      realtimePlayback: realtimePlayback,
      runs: runs,
      warmup: warmup,
      envFile: envFile,
    );
  }
}

class _RunResult {
  final int run;
  final bool warmup;
  final int readyMs;
  final int? firstDeltaMs;
  final int audioSentMs;
  final int doneMs;
  final int? postAudioDoneMs;
  final int chars;
  final int deltaChars;
  final String? error;

  const _RunResult({
    required this.run,
    required this.warmup,
    required this.readyMs,
    required this.firstDeltaMs,
    required this.audioSentMs,
    required this.doneMs,
    required this.postAudioDoneMs,
    required this.chars,
    required this.deltaChars,
    required this.error,
  });
}

const _usage = '''
Usage:
  dart run tool/realtime_stt_benchmark.dart --file .dart_tool/stt_benchmark_sample.wav --lang ko

Environment:
  OPENAI_API_KEY can be set in the environment, .env, or .env.flutter.

Options:
  --file PATH            PCM16 WAV file. Default: .dart_tool/stt_benchmark_sample.wav
  --lang CODE            Language hint. Default: ko.
  --delay VALUE          Realtime STT delay. Default: minimal.
  --noise-reduction VAL  near_field, far_field, or none. Default: near_field.
  --prompt TEXT          Optional STT prompt.
  --chunk-ms N           PCM append chunk duration. Default: 100.
  --fast-send            Send audio as fast as possible instead of real time.
  --runs N               Measured runs. Default: 3.
  --warmup N             Warmup runs excluded from summary. Default: 1.
  --env-file PATH        Load API key from this dotenv file instead of .env/.env.flutter.
''';
