import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../prompts.dart';

class OpenAIService {
  final String apiKey;
  static const _timeout = Duration(seconds: 30);

  OpenAIService(this.apiKey);

  Future<Map<String, String?>> translate(
    String text, {
    String sourceLang = 'Korean',
    String targetLang = 'Japanese',
    String model = 'gpt-5.4-nano',
    ToneMode tone = ToneMode.normal,
    String? systemPrompt,
    List<Map<String, String>>? context,
  }) async {
    final prompt = systemPrompt ?? AppPrompts.translationSystem(
      PromptLanguagePair(sourceLang: sourceLang, targetLang: targetLang),
      tone: tone,
    );

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt},
    ];

    if (context != null) messages.addAll(context);
    messages.add({'role': 'user', 'content': text});

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'messages': messages,
        'temperature': 0.3,
        'response_format': {'type': 'json_object'},
      }),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Translation failed: ${response.statusCode} ${response.body}');
    }

    try {
      final data = jsonDecode(response.body);
      final result = jsonDecode(data['choices'][0]['message']['content']);
      return {
        'translated': result['translated'] ?? '',
      };
    } catch (e) {
      throw Exception('Translation parse error: $e');
    }
  }

  Future<Uint8List> tts(String text, String lang, {String? voice, String? instructions}) async {
    final defaultVoice = voice ?? 'nova';
    final prompt = instructions ?? AppPrompts.ttsInstructions();

    final response = await http.post(
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
    ).timeout(_timeout);

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
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      audioBytes,
      filename: 'audio.m4a',
    ));

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

  Future<String> askAssistant(String question, {
    List<Map<String, String>> conversationContext = const [],
    String model = 'gpt-5.4-nano',
    String? systemPrompt,
  }) async {
    final prompt = systemPrompt ?? AppPrompts.assistantSystem(
      hasContext: conversationContext.isNotEmpty,
    );

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt},
    ];

    if (conversationContext.isNotEmpty) {
      final contextStr = conversationContext.map((m) => m['content'] ?? '').join('\n');
      messages.add({'role': 'user', 'content': '[Conversation context]\n$contextStr'});
      messages.add({'role': 'assistant', 'content': 'I have the conversation context. What is your question?'});
    }

    messages.add({'role': 'user', 'content': question});

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'messages': messages,
        'temperature': 0.7,
      }),
    ).timeout(_timeout);

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
