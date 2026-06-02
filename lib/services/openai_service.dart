import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../prompts.dart';

class OpenAIService {
  final String apiKey;
  final http.Client _client;
  late final Map<String, String> _jsonHeaders = {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };
  static const _timeout = Duration(seconds: 30);
  static final Map<String, bool> _temperatureSupportCache = {};
  static final Map<String, String> _realtimePostProcessPromptCache = {};
  static final Uri _chatCompletionsUri = Uri.parse(
    'https://api.openai.com/v1/chat/completions',
  );
  static final Uri _ttsUri = Uri.parse(
    'https://api.openai.com/v1/audio/speech',
  );
  static final Uri _sttUri = Uri.parse(
    'https://api.openai.com/v1/audio/transcriptions',
  );

  OpenAIService(this.apiKey, {http.Client? client})
    : _client = client ?? http.Client();

  void close() => _client.close();

  static bool _supportsCustomTemperature(String model) {
    final cached = _temperatureSupportCache[model];
    if (cached != null) return cached;
    final id = model.toLowerCase();
    final supported =
        !id.startsWith('gpt-5') &&
        !id.startsWith('o1') &&
        !id.startsWith('o3') &&
        !id.startsWith('o4');
    _temperatureSupportCache[model] = supported;
    return supported;
  }

  static bool _isUnsupportedTemperatureError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('temperature') &&
        lower.contains('unsupported') &&
        lower.contains('default');
  }

  static bool _supportsReasoningEffort(String model) {
    final id = model.toLowerCase();
    return id.startsWith('gpt-5') || id.startsWith('o');
  }

  static String? _chatReasoningEffort(String model, String? reasoningEffort) {
    final effort = reasoningEffort?.trim();
    if (effort == null ||
        effort.isEmpty ||
        effort == 'none' ||
        !_supportsReasoningEffort(model)) {
      return null;
    }

    final id = model.toLowerCase();
    final isBaseGpt5 = id == 'gpt-5' || id.startsWith('gpt-5-');
    if (effort == 'minimal' && !isBaseGpt5) {
      return null;
    }
    return effort;
  }

  static bool supportsSttStreaming(String model) {
    final id = model.toLowerCase();
    return id != 'whisper-1' && id != 'gpt-realtime-whisper';
  }

  static bool _isUnsupportedReasoningEffortError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('reasoning') &&
        (lower.contains('unsupported') ||
            lower.contains('not supported') ||
            lower.contains('unknown parameter') ||
            lower.contains('unrecognized') ||
            lower.contains('invalid'));
  }

  static String _realtimePostProcessSystemPrompt({
    required String sourceLangCode,
    required String targetLangCode,
  }) {
    final key = '$sourceLangCode\x1f$targetLangCode';
    final cached = _realtimePostProcessPromptCache[key];
    if (cached != null) return cached;

    final prompt =
        '''
You post-process realtime translation output for a translation app.

Input text is already the translated output from a realtime interpreter.
Return valid JSON only.

Rules:
- Detect whether input_text is in source or target language unless known_output_lang_code is provided.
- detected_lang_code must be exactly "$sourceLangCode" or "$targetLangCode".
- If need_back_translation is true, translate input_text into the requested back_translation_target language naturally.
- back_translation MUST be in back_translation_target.code when it is provided.
- If back_translation_target is null, translate back_translation into the opposite language based on detected_lang_code.
- Never translate back_translation into English unless back_translation_target.code is "en".
- If detected_lang_code is "$sourceLangCode", the opposite language is "$targetLangCode".
- If detected_lang_code is "$targetLangCode", the opposite language is "$sourceLangCode".
- Example for Korean/Japanese: input_text "고마워요" with back_translation_target.code "ja" -> "ありがとうございます" or "ありがとう"; never "Thank you".
- If need_pronunciation is true, provide Korean Hangul pronunciation for the non-Korean/non-English text among input_text or back_translation.
- If pronunciation is not useful or the relevant text is Korean or English, use null.
- Do not add explanations or markdown.

Schema:
{"detected_lang_code":"$sourceLangCode|$targetLangCode","back_translation":"<text or null in requested target language>","pronunciation":"<hangul or null>"}
''';
    _realtimePostProcessPromptCache[key] = prompt;
    return prompt;
  }

  static String _realtimePostProcessUserPayload({
    required String text,
    required String sourceLang,
    required String sourceLangCode,
    required String targetLang,
    required String targetLangCode,
    required String? knownOutputLangCode,
    required String? backTranslationLangCode,
    required String? backTranslationLang,
    required bool needBackTranslation,
    required bool needPronunciation,
  }) {
    final backTranslationTarget = backTranslationLangCode == null
        ? 'null'
        : '{"code":${jsonEncode(backTranslationLangCode)},"name":${jsonEncode(backTranslationLang)}}';
    return '{"input_text":${jsonEncode(text)},'
        '"source":{"code":${jsonEncode(sourceLangCode)},"name":${jsonEncode(sourceLang)}},'
        '"target":{"code":${jsonEncode(targetLangCode)},"name":${jsonEncode(targetLang)}},'
        '"known_output_lang_code":${knownOutputLangCode == null ? 'null' : jsonEncode(knownOutputLangCode)},'
        '"back_translation_target":$backTranslationTarget,'
        '"need_back_translation":$needBackTranslation,'
        '"need_pronunciation":$needPronunciation}';
  }

  Future<http.Response> _postChatCompletion(Map<String, dynamic> body) {
    return _client
        .post(
          _chatCompletionsUri,
          headers: _jsonHeaders,
          body: jsonEncode(body),
        )
        .timeout(_timeout);
  }

  Future<http.Response> _postChatCompletionWithFallback(
    Map<String, dynamic> body,
  ) async {
    var requestBody = Map<String, dynamic>.from(body);
    for (var attempt = 0; attempt < 3; attempt++) {
      final response = await _postChatCompletion(requestBody);
      if (response.statusCode != 400) return response;

      if (requestBody.containsKey('temperature') &&
          _isUnsupportedTemperatureError(response.body)) {
        final model = requestBody['model'];
        if (model is String) {
          _temperatureSupportCache[model] = false;
        }
        requestBody = Map<String, dynamic>.from(requestBody)
          ..remove('temperature');
        continue;
      }

      if (requestBody.containsKey('reasoning_effort') &&
          _isUnsupportedReasoningEffortError(response.body)) {
        requestBody = Map<String, dynamic>.from(requestBody)
          ..remove('reasoning_effort');
        continue;
      }

      return response;
    }
    return _postChatCompletion(requestBody);
  }

  Future<Map<String, String?>> translate(
    String text, {
    String sourceLang = 'Korean',
    String targetLang = 'Japanese',
    String model = 'gpt-5.4-nano',
    ToneMode tone = ToneMode.normal,
    String? systemPrompt,
    List<Map<String, String>>? context,
    double temperature = 0.3,
    String? reasoningEffort,
  }) async {
    final prompt =
        systemPrompt ??
        AppPrompts.translationSystem(
          PromptLanguagePair(sourceLang: sourceLang, targetLang: targetLang),
          tone: tone,
        );

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt},
    ];

    if (context != null) messages.addAll(context);
    messages.add({'role': 'user', 'content': text});

    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'response_format': {'type': 'json_object'},
    };
    if (_supportsCustomTemperature(model)) {
      body['temperature'] = temperature;
    }
    final chatReasoningEffort = _chatReasoningEffort(model, reasoningEffort);
    if (chatReasoningEffort != null) {
      body['reasoning_effort'] = chatReasoningEffort;
    }

    final response = await _postChatCompletionWithFallback(body);

    if (response.statusCode != 200) {
      throw Exception(
        'Translation failed: ${response.statusCode} ${response.body}',
      );
    }

    try {
      final data = jsonDecode(response.body);
      final result = jsonDecode(data['choices'][0]['message']['content']);
      return {'translated': result['translated'] ?? ''};
    } catch (e) {
      throw Exception('Translation parse error: $e');
    }
  }

  static String? _cleanNullableString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    return text;
  }

  Future<Map<String, String?>> realtimePostProcess(
    String text, {
    required String sourceLang,
    required String sourceLangCode,
    required String targetLang,
    required String targetLangCode,
    String? knownOutputLangCode,
    String? backTranslationLangCode,
    String? backTranslationLang,
    bool needBackTranslation = true,
    bool needPronunciation = true,
    String model = 'gpt-5.4-nano',
    double temperature = 0.1,
    String? reasoningEffort,
  }) async {
    final systemPrompt = _realtimePostProcessSystemPrompt(
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
    );

    final userPayload = _realtimePostProcessUserPayload(
      text: text,
      sourceLang: sourceLang,
      sourceLangCode: sourceLangCode,
      targetLang: targetLang,
      targetLangCode: targetLangCode,
      knownOutputLangCode: knownOutputLangCode,
      backTranslationLangCode: backTranslationLangCode,
      backTranslationLang: backTranslationLang,
      needBackTranslation: needBackTranslation,
      needPronunciation: needPronunciation,
    );

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPayload},
      ],
      'response_format': {'type': 'json_object'},
      'max_completion_tokens': 256,
    };
    if (_supportsCustomTemperature(model)) {
      body['temperature'] = temperature;
    }
    final chatReasoningEffort = _chatReasoningEffort(model, reasoningEffort);
    if (chatReasoningEffort != null) {
      body['reasoning_effort'] = chatReasoningEffort;
    }

    final response = await _postChatCompletionWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception('Realtime post-process failed: ${response.statusCode}');
    }

    try {
      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final result = jsonDecode(content) as Map<String, dynamic>;
      final detected = _cleanNullableString(result['detected_lang_code']);
      return {
        'detected_lang_code':
            detected == sourceLangCode || detected == targetLangCode
            ? detected
            : knownOutputLangCode,
        'back_translation': _cleanNullableString(result['back_translation']),
        'pronunciation': _cleanNullableString(result['pronunciation']),
      };
    } catch (e) {
      throw Exception('Realtime post-process parse error: $e');
    }
  }

  Future<Uint8List> tts(
    String text,
    String lang, {
    String model = 'gpt-4o-mini-tts',
    String? voice,
    String? instructions,
    String responseFormat = 'wav',
  }) async {
    final defaultVoice = voice ?? 'nova';
    final body = <String, dynamic>{
      'model': model,
      'voice': defaultVoice,
      'input': text,
      'response_format': responseFormat,
      'speed': 1.15,
    };
    if (_supportsTtsInstructions(model)) {
      body['instructions'] = instructions ?? AppPrompts.ttsInstructions();
    }

    final response = await _client
        .post(_ttsUri, headers: _jsonHeaders, body: jsonEncode(body))
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('TTS failed: ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  static bool _supportsTtsInstructions(String model) {
    final id = model.toLowerCase();
    return id == 'gpt-4o-mini-tts' || id.startsWith('gpt-4o-mini-tts-');
  }

  Future<String> _sendSttRequest(
    http.MultipartRequest request,
    String lang, {
    String model = 'gpt-4o-mini-transcribe',
    String? prompt,
    bool stream = false,
    void Function(String delta)? onDelta,
    void Function(String event)? onTiming,
  }) async {
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = model;
    request.fields['language'] = lang;
    final sttPrompt = prompt?.trim();
    if (sttPrompt != null && sttPrompt.isNotEmpty) {
      request.fields['prompt'] = sttPrompt;
    }
    final shouldStream = stream && supportsSttStreaming(model);
    if (shouldStream) {
      request.fields['response_format'] = 'text';
      request.fields['stream'] = 'true';
    }

    onTiming?.call('stt_upload_start');
    final response = await _client.send(request).timeout(_timeout);
    onTiming?.call('stt_response_headers');
    if (shouldStream && response.statusCode == 200) {
      return _readSttEventStream(response, onDelta: onDelta);
    }

    final body = await response.stream.bytesToString();
    onTiming?.call('stt_response_body_done');

    if (response.statusCode != 200) {
      throw Exception('STT failed: ${response.statusCode} $body');
    }

    try {
      final data = jsonDecode(body);
      return data['text'] ?? '';
    } catch (e) {
      throw Exception('STT parse error: $e');
    }
  }

  Future<String> _readSttEventStream(
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

      if (type == 'transcript.text.delta') {
        final delta = event['delta']?.toString() ?? '';
        if (delta.isEmpty) continue;
        output.write(delta);
        onDelta?.call(delta);
        continue;
      }

      if (type == 'transcript.text.done') {
        doneText =
            event['text']?.toString() ??
            event['transcript']?.toString() ??
            output.toString();
        continue;
      }

      if (type.endsWith('.delta')) {
        final delta =
            event['delta']?.toString() ?? event['text']?.toString() ?? '';
        if (delta.isEmpty) continue;
        output.write(delta);
        onDelta?.call(delta);
        continue;
      }

      if (type.endsWith('.done')) {
        doneText =
            event['text']?.toString() ??
            event['transcript']?.toString() ??
            output.toString();
      }
    }

    return (doneText ?? output.toString()).trim();
  }

  static Map<String, dynamic>? _tryDecodeObject(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> stt(
    Uint8List audioBytes,
    String lang, {
    String model = 'gpt-4o-mini-transcribe',
    String? prompt,
    String filename = 'audio.m4a',
    bool stream = false,
    void Function(String delta)? onDelta,
    void Function(String event)? onTiming,
  }) async {
    final request = http.MultipartRequest('POST', _sttUri);
    request.files.add(
      http.MultipartFile.fromBytes('file', audioBytes, filename: filename),
    );
    onTiming?.call('stt_multipart_ready');
    return _sendSttRequest(
      request,
      lang,
      model: model,
      prompt: prompt,
      stream: stream,
      onDelta: onDelta,
      onTiming: onTiming,
    );
  }

  Future<String> sttFile(
    String path,
    String lang, {
    String model = 'gpt-4o-mini-transcribe',
    String? prompt,
    String filename = 'audio.m4a',
    bool stream = false,
    void Function(String delta)? onDelta,
    void Function(String event)? onTiming,
  }) async {
    final request = http.MultipartRequest('POST', _sttUri);
    request.files.add(
      await http.MultipartFile.fromPath('file', path, filename: filename),
    );
    onTiming?.call('stt_multipart_ready');
    return _sendSttRequest(
      request,
      lang,
      model: model,
      prompt: prompt,
      stream: stream,
      onDelta: onDelta,
      onTiming: onTiming,
    );
  }

  Future<String> askAssistant(
    String question, {
    List<Map<String, String>> conversationContext = const [],
    String? conversationContextText,
    String model = 'gpt-5.4-nano',
    String? systemPrompt,
    double temperature = 0.7,
    String? reasoningEffort,
  }) async {
    final hasContext =
        conversationContextText?.isNotEmpty == true ||
        conversationContext.isNotEmpty;
    final prompt =
        systemPrompt ?? AppPrompts.assistantSystem(hasContext: hasContext);

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt},
    ];

    if (hasContext) {
      var contextText = conversationContextText;
      if (contextText == null) {
        final contextBuffer = StringBuffer();
        for (final message in conversationContext) {
          if (contextBuffer.isNotEmpty) contextBuffer.writeln();
          contextBuffer.write(message['content'] ?? '');
        }
        contextText = contextBuffer.toString();
      }
      messages.add({
        'role': 'user',
        'content': '[Conversation context]\n$contextText',
      });
      messages.add({
        'role': 'assistant',
        'content': 'I have the conversation context. What is your question?',
      });
    }

    messages.add({'role': 'user', 'content': question});

    final body = <String, dynamic>{'model': model, 'messages': messages};
    if (_supportsCustomTemperature(model)) {
      body['temperature'] = temperature;
    }
    final chatReasoningEffort = _chatReasoningEffort(model, reasoningEffort);
    if (chatReasoningEffort != null) {
      body['reasoning_effort'] = chatReasoningEffort;
    }

    final response = await _postChatCompletionWithFallback(body);

    if (response.statusCode != 200) {
      throw Exception('Assistant failed: ${response.statusCode}');
    }

    try {
      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] ?? '';
    } catch (e) {
      throw Exception('Assistant parse error: $e');
    }
  }

  Future<String?> detectLanguageCode(
    String text, {
    required String sourceLang,
    required String sourceLangCode,
    required String targetLang,
    required String targetLangCode,
    String model = 'gpt-5.4-nano',
    double temperature = 0.1,
    String? reasoningEffort,
  }) async {
    final systemPrompt =
        '''
You classify text for a translation app.

Return valid JSON only.
The only allowed detected_lang_code values are "$sourceLangCode" ($sourceLang) and "$targetLangCode" ($targetLang).
Choose the closer language from the two options. Do not translate the text.

Schema:
{"detected_lang_code":"$sourceLangCode|$targetLangCode"}
''';

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': text},
      ],
      'response_format': {'type': 'json_object'},
      'max_completion_tokens': 64,
    };
    if (_supportsCustomTemperature(model)) {
      body['temperature'] = temperature;
    }
    final chatReasoningEffort = _chatReasoningEffort(model, reasoningEffort);
    if (chatReasoningEffort != null) {
      body['reasoning_effort'] = chatReasoningEffort;
    }

    final response = await _postChatCompletionWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception('Language detection failed: ${response.statusCode}');
    }

    try {
      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final result = jsonDecode(content) as Map<String, dynamic>;
      final detected = _cleanNullableString(result['detected_lang_code']);
      if (detected == sourceLangCode || detected == targetLangCode) {
        return detected;
      }
      return null;
    } catch (e) {
      throw Exception('Language detection parse error: $e');
    }
  }

  Future<String?> hangulPronunciation(
    String text, {
    String model = 'gpt-5.4-nano',
    double temperature = 0.3,
    String? reasoningEffort,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'Write how the user text sounds using Korean Hangul. Reply with only the Hangul pronunciation. If a pronunciation is not useful, reply with null.',
        },
        {'role': 'user', 'content': text},
      ],
      'max_completion_tokens': 384,
    };
    if (_supportsCustomTemperature(model)) {
      body['temperature'] = temperature;
    }
    final chatReasoningEffort = _chatReasoningEffort(model, reasoningEffort);
    if (chatReasoningEffort != null) {
      body['reasoning_effort'] = chatReasoningEffort;
    }

    final response = await _postChatCompletionWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception('Pronunciation failed: ${response.statusCode}');
    }

    try {
      final data = jsonDecode(response.body);
      final value = data['choices'][0]['message']['content'];
      return _cleanNullableString(value);
    } catch (e) {
      throw Exception('Pronunciation parse error: $e');
    }
  }
}
