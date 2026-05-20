import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../prompts.dart';

class OpenAIService {
  final String apiKey;
  static const _timeout = Duration(seconds: 30);

  OpenAIService(this.apiKey);

  static bool _supportsCustomTemperature(String model) {
    final id = model.toLowerCase();
    return !id.startsWith('gpt-5') &&
        !id.startsWith('o1') &&
        !id.startsWith('o3') &&
        !id.startsWith('o4');
  }

  static bool _isUnsupportedTemperatureError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('temperature') &&
        lower.contains('unsupported') &&
        lower.contains('default');
  }

  Future<http.Response> _postChatCompletion(Map<String, dynamic> body) {
    return http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);
  }

  Future<http.Response> _postChatCompletionWithFallback(
    Map<String, dynamic> body,
  ) async {
    final response = await _postChatCompletion(body);
    if (response.statusCode == 400 &&
        body.containsKey('temperature') &&
        _isUnsupportedTemperatureError(response.body)) {
      final retryBody = Map<String, dynamic>.from(body)..remove('temperature');
      return _postChatCompletion(retryBody);
    }
    return response;
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
  }) async {
    final systemPrompt =
        '''
You post-process realtime translation output for a translation app.

Input text is already the translated output from a realtime interpreter.
Return valid JSON only.

Rules:
- Detect whether input_text is in source or target language unless known_output_lang_code is provided.
- detected_lang_code must be exactly "$sourceLangCode" or "$targetLangCode".
- If need_back_translation is true, translate input_text into the requested back_translation_target language naturally.
- back_translation MUST be in back_translation_target.code when it is provided.
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

    final userPayload = jsonEncode({
      'input_text': text,
      'source': {'code': sourceLangCode, 'name': sourceLang},
      'target': {'code': targetLangCode, 'name': targetLang},
      'known_output_lang_code': knownOutputLangCode,
      'back_translation_target': backTranslationLangCode == null
          ? null
          : {'code': backTranslationLangCode, 'name': backTranslationLang},
      'need_back_translation': needBackTranslation,
      'need_pronunciation': needPronunciation,
    });

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
    String? voice,
    String? instructions,
  }) async {
    final defaultVoice = voice ?? 'nova';
    final prompt = instructions ?? AppPrompts.ttsInstructions();

    final response = await http
        .post(
          Uri.parse('https://api.openai.com/v1/audio/speech'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': 'gpt-4o-mini-tts',
            'voice': voice ?? defaultVoice,
            'input': text,
            'instructions': prompt,
            'speed': 1.15,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('TTS failed: ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  Future<String> stt(Uint8List audioBytes, String lang) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
    );
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = 'gpt-4o-mini-transcribe';
    request.fields['language'] = lang;
    request.files.add(
      http.MultipartFile.fromBytes('file', audioBytes, filename: 'audio.m4a'),
    );

    final response = await request.send().timeout(_timeout);
    final body = await response.stream.bytesToString();

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

  Future<String> askAssistant(
    String question, {
    List<Map<String, String>> conversationContext = const [],
    String model = 'gpt-5.4-nano',
    String? systemPrompt,
    double temperature = 0.7,
  }) async {
    final prompt =
        systemPrompt ??
        AppPrompts.assistantSystem(hasContext: conversationContext.isNotEmpty);

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt},
    ];

    if (conversationContext.isNotEmpty) {
      final contextStr = conversationContext
          .map((m) => m['content'] ?? '')
          .join('\n');
      messages.add({
        'role': 'user',
        'content': '[Conversation context]\n$contextStr',
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
}
