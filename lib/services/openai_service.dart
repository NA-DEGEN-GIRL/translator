import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class OpenAIService {
  final String apiKey;

  OpenAIService(this.apiKey);

  Future<Map<String, String?>> translate(String text, String direction, {String model = 'gpt-5.4-nano'}) async {
    final systemPrompt = direction == 'ko2ja'
        ? 'You are a Korean→Japanese translator. Translate the input to natural Japanese. '
            'Reply in JSON: {"translated": "<Japanese>", "intent_korean": "<copy input as-is>"}'
        : 'You are a Japanese→Korean translator. Translate the input to natural Korean. '
            'Reply in JSON: {"translated": "<Korean>"}';

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': text},
        ],
        'temperature': 0.3,
        'response_format': {'type': 'json_object'},
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Translation failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final result = jsonDecode(data['choices'][0]['message']['content']);

    return {
      'translated': result['translated'] ?? '',
      'back_translation':
          direction == 'ko2ja' ? result['intent_korean'] : null,
    };
  }

  Future<Uint8List> tts(String text, String lang, {String? voice}) async {
    final defaultVoice = lang == 'ja' ? 'onyx' : 'nova';
    final instructions = lang == 'ja'
        ? 'Speak naturally in Japanese like a friendly interpreter.'
        : 'Speak naturally in Korean like a friendly interpreter.';

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
        'instructions': instructions,
        'speed': 1.15,
      }),
    );

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
    request.fields['language'] = lang == 'ja' ? 'ja' : 'ko';
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      audioBytes,
      filename: 'audio.webm',
    ));

    final response = await request.send();
    final body = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw Exception('STT failed: ${response.statusCode} $body');
    }

    final data = jsonDecode(body);
    return data['text'] ?? '';
  }
}
