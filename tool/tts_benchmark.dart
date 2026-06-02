import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const _defaultEnvFiles = ['.env', '.env.flutter'];
const _defaultModels = ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'];
const _defaultTexts = <_TtsCase>[
  _TtsCase(id: 'short_ja', text: 'こんにちは。今日、お時間は大丈夫ですか？', lang: 'ja'),
  _TtsCase(id: 'two_sentence_ja', text: '日本の方ですよね？さっき聞き間違えたみたいで。', lang: 'ja'),
  _TtsCase(id: 'short_ko', text: '죄송하지만, 지금 잠깐 시간 괜찮으신가요?', lang: 'ko'),
  _TtsCase(
    id: 'two_sentence_ko',
    text: '내일 혹시 시간 있으면, 가볍게 밥이라도 먹으러 가지 않을래?',
    lang: 'ko',
  ),
];

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

  final cases = _selectCases(options.caseIds);
  if (cases.isEmpty) {
    stderr.writeln('No cases selected.');
    exitCode = 64;
    return;
  }

  final outputFile = options.outputPath == null
      ? null
      : File(options.outputPath!);
  if (outputFile != null) {
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString('');
  }

  final client = _TtsClient(apiKey.trim());
  final results = <_RunResult>[];
  try {
    stdout.writeln('TTS benchmark');
    stdout.writeln('models=${options.models.join(', ')}');
    stdout.writeln('voice=${options.voice}');
    stdout.writeln('cases=${cases.map((c) => c.id).join(', ')}');
    stdout.writeln('runs=${options.runs}, warmup=${options.warmup}');
    if (outputFile != null) stdout.writeln('jsonl=${outputFile.path}');
    stdout.writeln('');

    for (var run = 1; run <= options.warmup + options.runs; run++) {
      final warmup = run <= options.warmup;
      final visibleRun = warmup ? 'warmup-$run' : '${run - options.warmup}';
      for (final ttsCase in cases) {
        for (final model in options.models) {
          final result = await _runOne(
            client,
            ttsCase,
            model: model,
            voice: options.voice,
            run: run,
            warmup: warmup,
            instructions: options.instructions,
          );
          _printResult(result, visibleRun: visibleRun);
          if (outputFile != null) {
            await outputFile.writeAsString(
              '${jsonEncode(result.toJson())}\n',
              mode: FileMode.append,
            );
          }
          if (!warmup) results.add(result);
        }
      }
      stdout.writeln('');
    }
  } finally {
    client.close();
  }

  _printSummary(results);
}

List<_TtsCase> _selectCases(List<String> ids) {
  if (ids.isEmpty || ids.contains('all')) return _defaultTexts;
  final wanted = ids.toSet();
  return [
    for (final item in _defaultTexts)
      if (wanted.contains(item.id)) item,
  ];
}

Future<_RunResult> _runOne(
  _TtsClient client,
  _TtsCase ttsCase, {
  required String model,
  required String voice,
  required int run,
  required bool warmup,
  required String instructions,
}) async {
  final clock = Stopwatch()..start();
  try {
    final bytes = await client.tts(
      ttsCase.text,
      model: model,
      voice: voice,
      instructions: instructions,
    );
    return _RunResult(
      run: run,
      warmup: warmup,
      caseId: ttsCase.id,
      model: model,
      voice: voice,
      doneMs: clock.elapsedMilliseconds,
      bytes: bytes.length,
      error: null,
    );
  } catch (error) {
    return _RunResult(
      run: run,
      warmup: warmup,
      caseId: ttsCase.id,
      model: model,
      voice: voice,
      doneMs: clock.elapsedMilliseconds,
      bytes: 0,
      error: error.toString(),
    );
  }
}

void _printResult(_RunResult result, {required String visibleRun}) {
  stdout.writeln(
    [
      'run=$visibleRun',
      'case=${result.caseId}',
      'model=${result.model}',
      'voice=${result.voice}',
      'done=${result.doneMs}ms',
      'bytes=${result.bytes}',
      if (result.error != null) 'error=${result.error}',
    ].join(' '),
  );
}

void _printSummary(List<_RunResult> results) {
  if (results.isEmpty) return;
  stdout.writeln('summary');
  final overall = <String, List<_RunResult>>{};
  final byCase = <String, List<_RunResult>>{};
  for (final result in results) {
    overall.putIfAbsent(result.model, () => []).add(result);
    byCase
        .putIfAbsent('${result.model}\t${result.caseId}', () => [])
        .add(result);
  }

  stdout.writeln('overall');
  for (final entry in overall.entries) {
    _printSummaryLine('model=${entry.key}', entry.value);
  }

  stdout.writeln('by_case');
  for (final entry in byCase.entries) {
    final parts = entry.key.split('\t');
    _printSummaryLine('model=${parts[0]} case=${parts[1]}', entry.value);
  }
}

void _printSummaryLine(String prefix, List<_RunResult> results) {
  final ok = results.where((r) => r.error == null).toList();
  final done = ok.map((r) => r.doneMs).toList();
  if (done.isEmpty) {
    stdout.writeln('$prefix ok=0/${results.length}');
    return;
  }
  stdout.writeln(
    [
      prefix,
      'ok=${ok.length}/${results.length}',
      'avg=${_avg(done).round()}ms',
      'med=${_median(done).round()}ms',
      'min=${done.reduce(min)}ms',
      'max=${done.reduce(max)}ms',
    ].join(' '),
  );
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

class _TtsClient {
  static final _uri = Uri.parse('https://api.openai.com/v1/audio/speech');
  static const _timeout = Duration(seconds: 60);

  final String apiKey;
  final http.Client _client;

  _TtsClient(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  Future<List<int>> tts(
    String text, {
    required String model,
    required String voice,
    required String instructions,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'voice': voice,
      'input': text,
      'response_format': 'wav',
      'speed': 1.15,
    };
    if (_supportsInstructions(model)) body['instructions'] = instructions;

    final response = await _client
        .post(
          _uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} ${response.body}');
    }
    return response.bodyBytes;
  }

  bool _supportsInstructions(String model) {
    final id = model.toLowerCase();
    return id == 'gpt-4o-mini-tts' || id.startsWith('gpt-4o-mini-tts-');
  }
}

class _Options {
  final bool help;
  final List<String> models;
  final List<String> caseIds;
  final int runs;
  final int warmup;
  final String voice;
  final String instructions;
  final String? envFile;
  final String? outputPath;

  const _Options({
    required this.help,
    required this.models,
    required this.caseIds,
    required this.runs,
    required this.warmup,
    required this.voice,
    required this.instructions,
    required this.envFile,
    required this.outputPath,
  });

  factory _Options.parse(List<String> args) {
    var help = false;
    var models = _defaultModels;
    var caseIds = <String>['all'];
    var runs = 3;
    var warmup = 1;
    var voice = 'nova';
    var instructions =
        'Speak naturally and clearly, like a friendly interpreter. '
        'Keep a warm, conversational tone.';
    String? envFile;
    String? outputPath = '.dart_tool/tts_benchmark.jsonl';

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
      } else if (arg == '--models' || arg.startsWith('--models=')) {
        models = _splitCsv(readValue('--models'));
      } else if (arg == '--cases' || arg.startsWith('--cases=')) {
        caseIds = _splitCsv(readValue('--cases'));
      } else if (arg == '--runs' || arg.startsWith('--runs=')) {
        runs = int.parse(readValue('--runs'));
      } else if (arg == '--warmup' || arg.startsWith('--warmup=')) {
        warmup = int.parse(readValue('--warmup'));
      } else if (arg == '--voice' || arg.startsWith('--voice=')) {
        voice = readValue('--voice');
      } else if (arg == '--instructions' || arg.startsWith('--instructions=')) {
        instructions = readValue('--instructions');
      } else if (arg == '--env-file' || arg.startsWith('--env-file=')) {
        envFile = readValue('--env-file');
      } else if (arg == '--out' || arg.startsWith('--out=')) {
        outputPath = readValue('--out');
      } else if (arg == '--no-out') {
        outputPath = null;
      } else {
        throw FormatException('Unknown argument: $arg');
      }
    }

    if (runs < 1) throw const FormatException('--runs must be >= 1');
    if (warmup < 0) throw const FormatException('--warmup must be >= 0');
    if (models.isEmpty) throw const FormatException('--models is empty');

    return _Options(
      help: help,
      models: models,
      caseIds: caseIds,
      runs: runs,
      warmup: warmup,
      voice: voice,
      instructions: instructions,
      envFile: envFile,
      outputPath: outputPath,
    );
  }

  static List<String> _splitCsv(String value) {
    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}

class _TtsCase {
  final String id;
  final String text;
  final String lang;

  const _TtsCase({required this.id, required this.text, required this.lang});
}

class _RunResult {
  final int run;
  final bool warmup;
  final String caseId;
  final String model;
  final String voice;
  final int doneMs;
  final int bytes;
  final String? error;

  const _RunResult({
    required this.run,
    required this.warmup,
    required this.caseId,
    required this.model,
    required this.voice,
    required this.doneMs,
    required this.bytes,
    required this.error,
  });

  Map<String, Object?> toJson() {
    return {
      'run': run,
      'warmup': warmup,
      'case': caseId,
      'model': model,
      'voice': voice,
      'done_ms': doneMs,
      'bytes': bytes,
      'error': error,
    };
  }
}

const _usage = '''
Usage:
  dart run tool/tts_benchmark.dart

Environment:
  OPENAI_API_KEY can be set in the environment, .env, or .env.flutter.

Options:
  --models LIST    Comma-separated models. Default: gpt-4o-mini-tts,tts-1,tts-1-hd
  --cases LIST     Comma-separated case IDs or all.
                   Cases: short_ja,two_sentence_ja,short_ko,two_sentence_ko
  --runs N         Measured runs per combination. Default: 3.
  --warmup N       Warmup runs excluded from summary. Default: 1.
  --voice VOICE    Voice. Default: nova.
  --instructions TEXT  Instructions for gpt-4o-mini-tts.
  --env-file PATH  Load API key from this dotenv file instead of .env/.env.flutter.
  --out PATH       Write JSONL results. Default: .dart_tool/tts_benchmark.jsonl
  --no-out         Do not write JSONL.
''';
