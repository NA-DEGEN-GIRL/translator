import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:koja_translator/models/language.dart';

const _defaultEnvFiles = ['.env', '.env.flutter'];
const _defaultModels = ['gpt-5.4-nano', 'gpt-5.4-mini'];
const _defaultReasoning = ['omit', 'low', 'medium'];
const _defaultTemperatures = ['omit'];
const _appDefaultTranslationSystem = '''
You are a professional translator for {{SOURCE_LANG}} and {{TARGET_LANG}}.

Task:
- Translate the user's input to natural {{TARGET_LANG}}.
- Preserve meaning, tone, and intent.
{{TONE_INSTRUCTION}}- Prefer natural phrasing over word-for-word translation.
- Do not add explanations, notes, or extra text.

Output rules:
- Reply with valid JSON only.
- Use exactly this schema: {"translated":"<translation>"}
- Do not wrap JSON in markdown.
''';

const _cases = <_TranslationCase>[
  _TranslationCase(
    id: 'short_ko_ja',
    sourceLangCode: 'ko',
    targetLangCode: 'ja',
    text: '안녕하세요. 오늘 시간 괜찮으세요?',
  ),
  _TranslationCase(
    id: 'short_ja_ko',
    sourceLangCode: 'ja',
    targetLangCode: 'ko',
    text: 'すみません、今少しだけお時間ありますか？',
  ),
  _TranslationCase(
    id: 'ambiguous_ko_ja',
    sourceLangCode: 'ko',
    targetLangCode: 'ja',
    text: '일본 사람 맞죠? 제가 아까 잘못 들은 것 같아서요.',
  ),
  _TranslationCase(
    id: 'casual_ja_ko',
    sourceLangCode: 'ja',
    targetLangCode: 'ko',
    text: '明日もし時間あったら、軽くご飯でも行かない？',
  ),
  _TranslationCase(
    id: 'long_ko_ja',
    sourceLangCode: 'ko',
    targetLangCode: 'ja',
    text:
        '방금 말한 내용은 농담이 아니라, 실제로 앱에서 번역이 너무 늦게 나오면 대화 흐름이 끊긴다는 뜻이었어요. 자연스럽고 짧게 전달해 주세요.',
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

  final selectedCases = _selectCases(options.caseIds);
  if (selectedCases.isEmpty) {
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

  final client = _TranslationClient(apiKey.trim());
  final results = <_RunResult>[];
  try {
    stdout.writeln('Text translation benchmark');
    stdout.writeln('models=${options.models.join(', ')}');
    stdout.writeln('reasoning=${options.reasoning.join(', ')}');
    stdout.writeln('temperatures=${options.temperatures.join(', ')}');
    stdout.writeln('cases=${selectedCases.map((c) => c.id).join(', ')}');
    stdout.writeln('runs=${options.runs}, warmup=${options.warmup}');
    if (outputFile != null) stdout.writeln('jsonl=${outputFile.path}');
    stdout.writeln('');

    for (var run = 1; run <= options.warmup + options.runs; run++) {
      final warmup = run <= options.warmup;
      final visibleRun = warmup ? 'warmup-$run' : '${run - options.warmup}';
      for (final translationCase in selectedCases) {
        for (final model in options.models) {
          for (final reasoning in options.reasoning) {
            for (final temperature in options.temperatures) {
              final result = await _runOne(
                client,
                translationCase,
                model: model,
                reasoning: reasoning,
                temperature: temperature,
                run: run,
                warmup: warmup,
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
        }
      }
      stdout.writeln('');
    }
  } finally {
    client.close();
  }

  _printSummary(results);
}

List<_TranslationCase> _selectCases(List<String> ids) {
  if (ids.isEmpty || ids.contains('all')) return _cases;
  final wanted = ids.toSet();
  return [
    for (final item in _cases)
      if (wanted.contains(item.id)) item,
  ];
}

Future<_RunResult> _runOne(
  _TranslationClient client,
  _TranslationCase translationCase, {
  required String model,
  required String reasoning,
  required String temperature,
  required int run,
  required bool warmup,
}) async {
  final clock = Stopwatch()..start();
  try {
    final response = await client.translate(
      translationCase,
      model: model,
      reasoning: reasoning,
      temperature: temperature,
    );
    if (response.translated.trim().isEmpty) {
      throw Exception('empty translation');
    }
    return _RunResult(
      run: run,
      warmup: warmup,
      caseId: translationCase.id,
      model: model,
      reasoning: reasoning,
      temperature: temperature,
      doneMs: clock.elapsedMilliseconds,
      translated: response.translated,
      promptTokens: response.promptTokens,
      completionTokens: response.completionTokens,
      reasoningTokens: response.reasoningTokens,
      error: null,
    );
  } catch (error) {
    return _RunResult(
      run: run,
      warmup: warmup,
      caseId: translationCase.id,
      model: model,
      reasoning: reasoning,
      temperature: temperature,
      doneMs: clock.elapsedMilliseconds,
      translated: '',
      promptTokens: null,
      completionTokens: null,
      reasoningTokens: null,
      error: error.toString(),
    );
  }
}

void _printResult(_RunResult result, {required String visibleRun}) {
  final translated = result.translated.replaceAll('\n', r'\n');
  stdout.writeln(
    [
      'run=$visibleRun',
      'case=${result.caseId}',
      'model=${result.model}',
      'reasoning=${result.reasoning}',
      'temperature=${result.temperature}',
      'done=${result.doneMs}ms',
      'chars=${result.translated.length}',
      if (result.reasoningTokens != null)
        'reasoning_tokens=${result.reasoningTokens}',
      if (result.error != null) 'error=${result.error}',
      if (result.error == null) 'result=${jsonEncode(translated)}',
    ].join(' '),
  );
}

void _printSummary(List<_RunResult> results) {
  if (results.isEmpty) return;
  stdout.writeln('summary');
  final overall = <String, List<_RunResult>>{};
  for (final result in results) {
    final key = '${result.model}\t${result.reasoning}\t${result.temperature}';
    overall.putIfAbsent(key, () => []).add(result);
  }

  stdout.writeln('overall');
  for (final entry in overall.entries) {
    final parts = entry.key.split('\t');
    final ok = entry.value.where((r) => r.error == null).toList();
    final done = ok.map((r) => r.doneMs).toList();
    if (done.isEmpty) {
      stdout.writeln(
        'model=${parts[0]} reasoning=${parts[1]} temperature=${parts[2]} ok=0/${entry.value.length}',
      );
      continue;
    }
    stdout.writeln(
      [
        'model=${parts[0]}',
        'reasoning=${parts[1]}',
        'temperature=${parts[2]}',
        'ok=${ok.length}/${entry.value.length}',
        'avg=${_avg(done).round()}ms',
        'med=${_median(done).round()}ms',
        'min=${done.reduce(min)}ms',
        'max=${done.reduce(max)}ms',
      ].join(' '),
    );
  }

  stdout.writeln('by_case');
  final groups = <String, List<_RunResult>>{};
  for (final result in results) {
    final key =
        '${result.model}\t${result.reasoning}\t${result.temperature}\t${result.caseId}';
    groups.putIfAbsent(key, () => []).add(result);
  }

  for (final entry in groups.entries) {
    final parts = entry.key.split('\t');
    final ok = entry.value.where((r) => r.error == null).toList();
    final done = ok.map((r) => r.doneMs).toList();
    if (done.isEmpty) {
      stdout.writeln(
        'model=${parts[0]} reasoning=${parts[1]} temperature=${parts[2]} case=${parts[3]} ok=0/${entry.value.length}',
      );
      continue;
    }
    stdout.writeln(
      [
        'model=${parts[0]}',
        'reasoning=${parts[1]}',
        'temperature=${parts[2]}',
        'case=${parts[3]}',
        'ok=${ok.length}/${entry.value.length}',
        'avg=${_avg(done).round()}ms',
        'med=${_median(done).round()}ms',
        'min=${done.reduce(min)}ms',
        'max=${done.reduce(max)}ms',
      ].join(' '),
    );
  }
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

class _TranslationClient {
  static final _uri = Uri.parse('https://api.openai.com/v1/chat/completions');
  static const _timeout = Duration(seconds: 60);

  final String apiKey;
  final http.Client _client;

  _TranslationClient(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  Future<_TranslationResponse> translate(
    _TranslationCase translationCase, {
    required String model,
    required String reasoning,
    required String temperature,
  }) async {
    final reasoningEffort = _normalizeReasoning(reasoning);
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt(translationCase)},
        {'role': 'user', 'content': translationCase.text},
      ],
      'response_format': {'type': 'json_object'},
    };
    if (reasoningEffort != null) body['reasoning_effort'] = reasoningEffort;
    if (temperature != 'omit') body['temperature'] = double.parse(temperature);

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

    final decoded = jsonDecode(response.body);
    final content =
        decoded['choices']?[0]?['message']?['content']?.toString() ?? '';
    final translated = _extractTranslated(content);
    final usage = decoded['usage'];
    final completionDetails = usage is Map
        ? usage['completion_tokens_details']
        : null;

    return _TranslationResponse(
      translated: translated,
      promptTokens: usage is Map ? usage['prompt_tokens'] as int? : null,
      completionTokens: usage is Map
          ? usage['completion_tokens'] as int?
          : null,
      reasoningTokens: completionDetails is Map
          ? completionDetails['reasoning_tokens'] as int?
          : null,
    );
  }

  String? _normalizeReasoning(String value) {
    return switch (value) {
      'omit' || 'none' || '' => null,
      _ => value,
    };
  }

  String _systemPrompt(_TranslationCase translationCase) {
    return _appDefaultTranslationSystem
        .replaceAll('{{SOURCE_LANG}}', translationCase.sourceLangName)
        .replaceAll('{{TARGET_LANG}}', translationCase.targetLangName)
        .replaceAll('{{TONE_INSTRUCTION}}', '');
  }

  String _extractTranslated(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        return decoded['translated']?.toString() ?? content;
      }
      return content;
    } catch (_) {
      return content;
    }
  }
}

class _Options {
  final bool help;
  final List<String> models;
  final List<String> reasoning;
  final List<String> temperatures;
  final List<String> caseIds;
  final int runs;
  final int warmup;
  final String? envFile;
  final String? outputPath;

  const _Options({
    required this.help,
    required this.models,
    required this.reasoning,
    required this.temperatures,
    required this.caseIds,
    required this.runs,
    required this.warmup,
    required this.envFile,
    required this.outputPath,
  });

  factory _Options.parse(List<String> args) {
    var help = false;
    var models = _defaultModels;
    var reasoning = _defaultReasoning;
    var temperatures = _defaultTemperatures;
    var caseIds = <String>['all'];
    var runs = 3;
    var warmup = 1;
    String? envFile;
    String? outputPath = '.dart_tool/text_translation_benchmark.jsonl';

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
      } else if (arg == '--reasoning' || arg.startsWith('--reasoning=')) {
        reasoning = _splitCsv(readValue('--reasoning'));
      } else if (arg == '--temperatures' || arg.startsWith('--temperatures=')) {
        temperatures = _splitCsv(readValue('--temperatures'));
      } else if (arg == '--cases' || arg.startsWith('--cases=')) {
        caseIds = _splitCsv(readValue('--cases'));
      } else if (arg == '--runs' || arg.startsWith('--runs=')) {
        runs = int.parse(readValue('--runs'));
      } else if (arg == '--warmup' || arg.startsWith('--warmup=')) {
        warmup = int.parse(readValue('--warmup'));
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
    if (reasoning.isEmpty) throw const FormatException('--reasoning is empty');
    if (temperatures.isEmpty) {
      throw const FormatException('--temperatures is empty');
    }
    for (final temperature in temperatures) {
      if (temperature == 'omit') continue;
      final parsed = double.tryParse(temperature);
      if (parsed == null || parsed < 0 || parsed > 2) {
        throw FormatException('Invalid temperature: $temperature');
      }
    }

    return _Options(
      help: help,
      models: models,
      reasoning: reasoning,
      temperatures: temperatures,
      caseIds: caseIds,
      runs: runs,
      warmup: warmup,
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

class _TranslationCase {
  final String id;
  final String sourceLangCode;
  final String targetLangCode;
  final String text;

  const _TranslationCase({
    required this.id,
    required this.sourceLangCode,
    required this.targetLangCode,
    required this.text,
  });

  String get sourceLangName => getLangByCode(sourceLangCode).name;
  String get targetLangName => getLangByCode(targetLangCode).name;
}

class _TranslationResponse {
  final String translated;
  final int? promptTokens;
  final int? completionTokens;
  final int? reasoningTokens;

  const _TranslationResponse({
    required this.translated,
    required this.promptTokens,
    required this.completionTokens,
    required this.reasoningTokens,
  });
}

class _RunResult {
  final int run;
  final bool warmup;
  final String caseId;
  final String model;
  final String reasoning;
  final String temperature;
  final int doneMs;
  final String translated;
  final int? promptTokens;
  final int? completionTokens;
  final int? reasoningTokens;
  final String? error;

  const _RunResult({
    required this.run,
    required this.warmup,
    required this.caseId,
    required this.model,
    required this.reasoning,
    required this.temperature,
    required this.doneMs,
    required this.translated,
    required this.promptTokens,
    required this.completionTokens,
    required this.reasoningTokens,
    required this.error,
  });

  Map<String, Object?> toJson() {
    return {
      'run': run,
      'warmup': warmup,
      'case': caseId,
      'model': model,
      'reasoning': reasoning,
      'temperature': temperature,
      'done_ms': doneMs,
      'translated': translated,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'reasoning_tokens': reasoningTokens,
      'error': error,
    };
  }
}

const _usage = '''
Usage:
  dart run tool/text_translation_benchmark.dart

Environment:
  OPENAI_API_KEY can be set in the environment, .env, or .env.flutter.

Options:
  --models LIST     Comma-separated models. Default: gpt-5.4-nano,gpt-5.4-mini
  --reasoning LIST  Comma-separated reasoning values. Use omit for null/no param.
                    Default: omit,low,medium
  --temperatures LIST  Comma-separated temperatures or omit for no param.
                       Default: omit
  --cases LIST      Comma-separated case IDs or all.
                    Cases: short_ko_ja,short_ja_ko,ambiguous_ko_ja,casual_ja_ko,long_ko_ja
  --runs N          Measured runs per combination. Default: 3.
  --warmup N        Warmup runs excluded from summary. Default: 1.
  --env-file PATH   Load API key from this dotenv file instead of .env/.env.flutter.
  --out PATH        Write JSONL results. Default: .dart_tool/text_translation_benchmark.jsonl
  --no-out          Do not write JSONL.
''';
