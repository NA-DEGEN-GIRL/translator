import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const _defaultModels = ['gpt-4o-mini-transcribe', 'gpt-4o-transcribe'];
const _defaultEnvFiles = ['.env', '.env.flutter'];

void main(List<String> args) async {
  late final _BenchmarkOptions options;
  try {
    options = _BenchmarkOptions.parse(args);
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

  if ((options.filePath == null || options.filePath!.trim().isEmpty) &&
      (options.sampleText == null || options.sampleText!.trim().isEmpty)) {
    stderr.writeln('Missing --file or --sample-text.');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final service = _SttClient(apiKey.trim());
  final allResults = <_SttRunResult>[];
  try {
    final file = await _prepareAudioFile(service, options);
    stdout.writeln('STT benchmark');
    stdout.writeln('file=${file.path}');
    stdout.writeln('bytes=${file.lengthSync()}');
    stdout.writeln('lang=${options.language}');
    stdout.writeln('stream=${options.stream}');
    stdout.writeln('mode=${options.parallel ? 'parallel' : 'sequential'}');
    stdout.writeln('runs=${options.runs}, warmup=${options.warmup}');
    stdout.writeln('models=${options.models.join(', ')}');
    stdout.writeln('');

    for (var run = 1; run <= options.warmup + options.runs; run++) {
      final isWarmup = run <= options.warmup;
      final visibleRun = isWarmup ? 'warmup-$run' : '${run - options.warmup}';
      stdout.writeln('run=$visibleRun start');

      final runResults = options.parallel
          ? await _runParallel(
              service,
              options,
              file,
              run: run,
              isWarmup: isWarmup,
            )
          : await _runSequential(
              service,
              options,
              file,
              run: run,
              isWarmup: isWarmup,
            );

      for (final result in runResults) {
        _printRunResult(result);
        if (!isWarmup) allResults.add(result);
      }
      stdout.writeln('');
    }
  } on _UsageException catch (error) {
    stderr.writeln(error.message);
    exitCode = error.exitCode;
    return;
  } finally {
    service.close();
  }

  if (allResults.isEmpty) return;
  stdout.writeln('summary');
  for (final model in options.models) {
    final modelResults = allResults.where((r) => r.model == model).toList();
    if (modelResults.isEmpty) continue;
    final done = modelResults.map((r) => r.doneMs).toList();
    final first = modelResults
        .map((r) => r.firstDeltaMs)
        .whereType<int>()
        .toList();
    final errors = modelResults.where((r) => r.error != null).length;
    stdout.writeln(
      [
        'model=$model',
        'ok=${modelResults.length - errors}/${modelResults.length}',
        'first_avg=${first.isEmpty ? 'n/a' : _avg(first).round()}ms',
        'first_med=${first.isEmpty ? 'n/a' : _median(first).round()}ms',
        'done_avg=${_avg(done).round()}ms',
        'done_med=${_median(done).round()}ms',
        'done_min=${done.reduce(min)}ms',
        'done_max=${done.reduce(max)}ms',
      ].join(' '),
    );
  }

  final winner = _winnerByAverageDone(allResults, options.models);
  if (winner != null) stdout.writeln('winner=$winner');
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

Future<File> _prepareAudioFile(
  _SttClient service,
  _BenchmarkOptions options,
) async {
  final filePath = options.filePath?.trim();
  if (filePath != null && filePath.isNotEmpty) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw _UsageException('Audio file not found: $filePath', 66);
    }
    return file;
  }

  final sampleText = options.sampleText?.trim();
  if (sampleText == null || sampleText.isEmpty) {
    throw _UsageException('Missing --file or --sample-text.', 64);
  }

  final output = File(
    options.sampleOutputPath ?? '.dart_tool/stt_benchmark_sample.wav',
  );
  await output.parent.create(recursive: true);
  stdout.writeln('generating_sample file=${output.path}');
  await service.ttsToFile(
    sampleText,
    output,
    model: options.sampleTtsModel,
    voice: options.sampleVoice,
  );
  return output;
}

Future<List<_SttRunResult>> _runParallel(
  _SttClient service,
  _BenchmarkOptions options,
  File file, {
  required int run,
  required bool isWarmup,
}) async {
  return Future.wait([
    for (final model in options.models)
      _runOne(
        service,
        options,
        file,
        model: model,
        run: run,
        isWarmup: isWarmup,
      ),
  ]);
}

Future<List<_SttRunResult>> _runSequential(
  _SttClient service,
  _BenchmarkOptions options,
  File file, {
  required int run,
  required bool isWarmup,
}) async {
  final results = <_SttRunResult>[];
  for (final model in options.models) {
    results.add(
      await _runOne(
        service,
        options,
        file,
        model: model,
        run: run,
        isWarmup: isWarmup,
      ),
    );
  }
  return results;
}

Future<_SttRunResult> _runOne(
  _SttClient service,
  _BenchmarkOptions options,
  File file, {
  required String model,
  required int run,
  required bool isWarmup,
}) async {
  final clock = Stopwatch()..start();
  int? firstDeltaMs;
  var deltaEvents = 0;
  try {
    final text = await service.sttFile(
      file.path,
      options.language,
      model: model,
      filename: options.filename ?? file.uri.pathSegments.last,
      prompt: options.prompt,
      stream: options.stream,
      onDelta: (delta) {
        if (delta.isEmpty) return;
        deltaEvents++;
        firstDeltaMs ??= clock.elapsedMilliseconds;
      },
    );
    return _SttRunResult(
      run: run,
      warmup: isWarmup,
      model: model,
      firstDeltaMs: firstDeltaMs,
      doneMs: clock.elapsedMilliseconds,
      chars: text.trim().length,
      deltaEvents: deltaEvents,
      error: null,
    );
  } catch (error) {
    return _SttRunResult(
      run: run,
      warmup: isWarmup,
      model: model,
      firstDeltaMs: firstDeltaMs,
      doneMs: clock.elapsedMilliseconds,
      chars: 0,
      deltaEvents: deltaEvents,
      error: error.toString(),
    );
  }
}

void _printRunResult(_SttRunResult result) {
  stdout.writeln(
    [
      'model=${result.model}',
      'first=${result.firstDeltaMs == null ? 'n/a' : '${result.firstDeltaMs}ms'}',
      'done=${result.doneMs}ms',
      'chars=${result.chars}',
      'events=${result.deltaEvents}',
      if (result.error != null) 'error=${result.error}',
    ].join(' '),
  );
}

String? _winnerByAverageDone(List<_SttRunResult> results, List<String> models) {
  String? winner;
  double? best;
  for (final model in models) {
    final done = results
        .where((r) => r.model == model && r.error == null)
        .map((r) => r.doneMs)
        .toList();
    if (done.isEmpty) continue;
    final avg = _avg(done);
    if (best == null || avg < best) {
      best = avg;
      winner = model;
    }
  }
  return winner;
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

class _BenchmarkOptions {
  final bool help;
  final String? filePath;
  final String language;
  final List<String> models;
  final int runs;
  final int warmup;
  final bool stream;
  final bool parallel;
  final String? prompt;
  final String? filename;
  final String? envFile;
  final String? sampleText;
  final String? sampleOutputPath;
  final String sampleTtsModel;
  final String sampleVoice;

  const _BenchmarkOptions({
    required this.help,
    required this.filePath,
    required this.language,
    required this.models,
    required this.runs,
    required this.warmup,
    required this.stream,
    required this.parallel,
    required this.prompt,
    required this.filename,
    required this.envFile,
    required this.sampleText,
    required this.sampleOutputPath,
    required this.sampleTtsModel,
    required this.sampleVoice,
  });

  factory _BenchmarkOptions.parse(List<String> args) {
    var help = false;
    String? filePath;
    var language = 'ko';
    var models = _defaultModels;
    var runs = 5;
    var warmup = 1;
    var stream = true;
    var parallel = true;
    String? prompt;
    String? filename;
    String? envFile;
    String? sampleText;
    String? sampleOutputPath;
    var sampleTtsModel = 'gpt-4o-mini-tts';
    var sampleVoice = 'nova';

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
      } else if (arg == '--models' || arg.startsWith('--models=')) {
        models = readValue(
          '--models',
        ).split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
      } else if (arg == '--runs' || arg.startsWith('--runs=')) {
        runs = int.parse(readValue('--runs'));
      } else if (arg == '--warmup' || arg.startsWith('--warmup=')) {
        warmup = int.parse(readValue('--warmup'));
      } else if (arg == '--prompt' || arg.startsWith('--prompt=')) {
        prompt = readValue('--prompt');
      } else if (arg == '--filename' || arg.startsWith('--filename=')) {
        filename = readValue('--filename');
      } else if (arg == '--env-file' || arg.startsWith('--env-file=')) {
        envFile = readValue('--env-file');
      } else if (arg == '--sample-text' || arg.startsWith('--sample-text=')) {
        sampleText = readValue('--sample-text');
      } else if (arg == '--sample-output' ||
          arg.startsWith('--sample-output=')) {
        sampleOutputPath = readValue('--sample-output');
      } else if (arg == '--sample-tts-model' ||
          arg.startsWith('--sample-tts-model=')) {
        sampleTtsModel = readValue('--sample-tts-model');
      } else if (arg == '--sample-voice' || arg.startsWith('--sample-voice=')) {
        sampleVoice = readValue('--sample-voice');
      } else if (arg == '--no-stream') {
        stream = false;
      } else if (arg == '--sequential') {
        parallel = false;
      } else {
        throw FormatException('Unknown argument: $arg');
      }
    }

    if (runs < 1) throw const FormatException('--runs must be >= 1');
    if (warmup < 0) throw const FormatException('--warmup must be >= 0');
    if (models.isEmpty) throw const FormatException('--models is empty');

    return _BenchmarkOptions(
      help: help,
      filePath: filePath,
      language: language,
      models: models,
      runs: runs,
      warmup: warmup,
      stream: stream,
      parallel: parallel,
      prompt: prompt,
      filename: filename,
      envFile: envFile,
      sampleText: sampleText,
      sampleOutputPath: sampleOutputPath,
      sampleTtsModel: sampleTtsModel,
      sampleVoice: sampleVoice,
    );
  }
}

class _SttClient {
  static final _sttUri = Uri.parse(
    'https://api.openai.com/v1/audio/transcriptions',
  );
  static final _ttsUri = Uri.parse('https://api.openai.com/v1/audio/speech');
  static const _timeout = Duration(seconds: 60);

  final String apiKey;
  final http.Client _client;

  _SttClient(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  Future<void> ttsToFile(
    String text,
    File output, {
    required String model,
    required String voice,
  }) async {
    final response = await _client
        .post(
          _ttsUri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'voice': voice,
            'input': text,
            'response_format': 'wav',
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('TTS sample failed: ${response.statusCode}');
    }
    await output.writeAsBytes(response.bodyBytes);
  }

  Future<String> sttFile(
    String path,
    String lang, {
    required String model,
    required String filename,
    String? prompt,
    required bool stream,
    void Function(String delta)? onDelta,
  }) async {
    final request = http.MultipartRequest('POST', _sttUri);
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = model;
    request.fields['language'] = lang;
    if (prompt != null && prompt.trim().isNotEmpty) {
      request.fields['prompt'] = prompt.trim();
    }
    if (stream && _supportsSttStreaming(model)) {
      request.fields['response_format'] = 'text';
      request.fields['stream'] = 'true';
    }
    request.files.add(
      await http.MultipartFile.fromPath('file', path, filename: filename),
    );

    final response = await _client.send(request).timeout(_timeout);
    final isStreaming = request.fields['stream'] == 'true';
    if (isStreaming && response.statusCode == 200) {
      return _readEventStream(response, onDelta: onDelta);
    }

    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw Exception('STT failed: ${response.statusCode} $body');
    }

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return decoded['text']?.toString() ?? '';
      return '';
    } catch (error) {
      throw Exception('STT parse error: $error');
    }
  }

  bool _supportsSttStreaming(String model) {
    final id = model.toLowerCase();
    return id != 'whisper-1' && id != 'gpt-realtime-whisper';
  }

  Future<String> _readEventStream(
    http.StreamedResponse response, {
    void Function(String delta)? onDelta,
  }) async {
    final output = StringBuffer();
    String? doneText;

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith(':')) continue;
      if (trimmed.startsWith('event:')) continue;

      final data = trimmed.startsWith('data:')
          ? trimmed.substring(5).trim()
          : trimmed;
      if (data.isEmpty || data == '[DONE]') continue;

      final event = _tryDecodeObject(data);
      if (event == null) continue;
      final type = event['type']?.toString() ?? '';

      if (type == 'transcript.text.delta' || type.endsWith('.delta')) {
        final delta =
            event['delta']?.toString() ?? event['text']?.toString() ?? '';
        if (delta.isEmpty) continue;
        output.write(delta);
        onDelta?.call(delta);
        continue;
      }

      if (type == 'transcript.text.done' || type.endsWith('.done')) {
        doneText =
            event['text']?.toString() ??
            event['transcript']?.toString() ??
            output.toString();
      }
    }

    return (doneText ?? output.toString()).trim();
  }

  Map<String, dynamic>? _tryDecodeObject(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }
}

class _UsageException implements Exception {
  final String message;
  final int exitCode;

  const _UsageException(this.message, this.exitCode);
}

class _SttRunResult {
  final int run;
  final bool warmup;
  final String model;
  final int? firstDeltaMs;
  final int doneMs;
  final int chars;
  final int deltaEvents;
  final String? error;

  const _SttRunResult({
    required this.run,
    required this.warmup,
    required this.model,
    required this.firstDeltaMs,
    required this.doneMs,
    required this.chars,
    required this.deltaEvents,
    required this.error,
  });
}

const _usage = '''
Usage:
  dart run tool/stt_benchmark.dart --file sample.wav --lang ko
  dart run tool/stt_benchmark.dart --sample-text "안녕하세요. 오늘 날씨가 좋네요." --lang ko

Environment:
  OPENAI_API_KEY can be set in the environment, .env, or .env.flutter.

Options:
  --file PATH         Audio file to transcribe.
  --sample-text TEXT  Generate a temporary WAV sample through TTS when --file is omitted.
  --lang CODE         Language hint passed to the API. Default: ko.
  --models LIST       Comma-separated models.
                    Default: gpt-4o-mini-transcribe,gpt-4o-transcribe
  --runs N            Measured runs per model. Default: 5.
  --warmup N          Warmup runs excluded from summary. Default: 1.
  --no-stream         Disable streaming and measure final response only.
  --sequential        Run models one after another instead of concurrently.
  --prompt TEXT       Optional STT prompt/hint.
  --filename NAME     Override multipart filename.
  --env-file PATH     Load API key from this dotenv file instead of .env/.env.flutter.
  --sample-output PATH     TTS sample output path. Default: .dart_tool/stt_benchmark_sample.wav
  --sample-tts-model MODEL TTS model for --sample-text. Default: gpt-4o-mini-tts.
  --sample-voice VOICE     TTS voice for --sample-text. Default: nova.
''';
