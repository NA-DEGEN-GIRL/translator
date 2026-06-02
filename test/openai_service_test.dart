import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koja_translator/services/openai_service.dart';

void main() {
  test('translate sends reasoning effort for GPT-5 models', () async {
    late Map<String, dynamic> requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"translated":"こんにちは"}'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.translate(
      '안녕하세요',
      model: 'gpt-5.4-nano',
      reasoningEffort: 'low',
      temperature: 0.3,
    );

    expect(result['translated'], 'こんにちは');
    expect(requestBody['reasoning_effort'], 'low');
    expect(requestBody.containsKey('temperature'), isFalse);
    service.close();
  });

  test('translate omits reasoning effort when empty', () async {
    late Map<String, dynamic> requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"translated":"こんにちは"}'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await service.translate(
      '안녕하세요',
      model: 'gpt-5.4-nano',
      reasoningEffort: '',
    );

    expect(requestBody.containsKey('reasoning_effort'), isFalse);
    service.close();
  });

  test('translate omits minimal reasoning effort for GPT-5.4 models', () async {
    late Map<String, dynamic> requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"translated":"こんにちは"}'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await service.translate(
      '안녕하세요',
      model: 'gpt-5.4-nano',
      reasoningEffort: 'minimal',
    );

    expect(requestBody.containsKey('reasoning_effort'), isFalse);
    service.close();
  });

  test(
    'translate keeps minimal reasoning effort for base GPT-5 model',
    () async {
      late Map<String, dynamic> requestBody;
      final service = OpenAIService(
        'test-key',
        client: MockClient((request) async {
          requestBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '{"translated":"こんにちは"}'},
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await service.translate(
        '안녕하세요',
        model: 'gpt-5',
        reasoningEffort: 'minimal',
      );

      expect(requestBody['reasoning_effort'], 'minimal');
      service.close();
    },
  );

  test('stt sends selected model and prompt', () async {
    late String requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = request.body;
        return http.Response.bytes(
          utf8.encode('{"text":"안녕하세요"}'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.stt(
      Uint8List.fromList([1, 2, 3, 4]),
      'ko',
      model: 'gpt-4o-transcribe',
      prompt: 'OpenAI, Kor-Jap Translator',
    );

    expect(result, '안녕하세요');
    expect(requestBody, contains('name="model"'));
    expect(requestBody, contains('gpt-4o-transcribe'));
    expect(requestBody, contains('name="prompt"'));
    expect(requestBody, contains('OpenAI, Kor-Jap Translator'));
    service.close();
  });

  test('stt streams completed recordings for non-whisper models', () async {
    late String requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = request.body;
        return http.Response(
          [
            'data: {"type":"transcript.text.delta","delta":"안녕"}',
            '',
            'data: {"type":"transcript.text.delta","delta":"하세요"}',
            '',
            'data: {"type":"transcript.text.done","text":"안녕하세요"}',
            '',
          ].join('\n'),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }),
    );

    final result = await service.stt(
      Uint8List.fromList([1, 2, 3, 4]),
      'ko',
      model: 'gpt-4o-mini-transcribe',
      stream: true,
      filename: 'audio.wav',
    );

    expect(result, '안녕하세요');
    expect(requestBody, contains('name="stream"'));
    expect(requestBody, contains('true'));
    expect(requestBody, contains('name="response_format"'));
    expect(requestBody, contains('text'));
    expect(requestBody, contains('filename="audio.wav"'));
    service.close();
  });

  test('stt does not send stream for whisper', () async {
    late String requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = request.body;
        return http.Response.bytes(
          utf8.encode('{"text":"안녕하세요"}'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.stt(
      Uint8List.fromList([1, 2, 3, 4]),
      'ko',
      model: 'whisper-1',
      stream: true,
    );

    expect(result, '안녕하세요');
    expect(requestBody, isNot(contains('name="stream"')));
    expect(requestBody, isNot(contains('name="response_format"')));
    service.close();
  });

  test('tts sends selected model and instructions for 4o mini tts', () async {
    late Map<String, dynamic> requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          Uint8List.fromList([1, 2, 3, 4]),
          200,
          headers: {'content-type': 'audio/wav'},
        );
      }),
    );

    final result = await service.tts(
      'こんにちは',
      'ja',
      model: 'gpt-4o-mini-tts',
      voice: 'coral',
      instructions: 'Speak clearly.',
    );

    expect(result, [1, 2, 3, 4]);
    expect(requestBody['model'], 'gpt-4o-mini-tts');
    expect(requestBody['voice'], 'coral');
    expect(requestBody['input'], 'こんにちは');
    expect(requestBody['response_format'], 'wav');
    expect(requestBody['instructions'], 'Speak clearly.');
    service.close();
  });

  test('tts omits instructions for legacy tts models', () async {
    late Map<String, dynamic> requestBody;
    final service = OpenAIService(
      'test-key',
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          Uint8List.fromList([1, 2, 3, 4]),
          200,
          headers: {'content-type': 'audio/wav'},
        );
      }),
    );

    await service.tts(
      'こんにちは',
      'ja',
      model: 'tts-1',
      voice: 'nova',
      instructions: 'Speak clearly.',
    );

    expect(requestBody['model'], 'tts-1');
    expect(requestBody['response_format'], 'wav');
    expect(requestBody.containsKey('instructions'), isFalse);
    service.close();
  });
}
