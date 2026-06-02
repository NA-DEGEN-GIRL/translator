import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/realtime_translation_service.dart';

void main() {
  group('RealtimeTranslationService', () {
    test('builds translation client secret body with output language', () {
      final body = RealtimeTranslationService.buildClientSecretRequestBody(
        model: 'gpt-realtime-translate',
        targetLangCode: 'ja',
      );

      expect(body['session'], isA<Map<String, dynamic>>());
      final session = body['session'] as Map<String, dynamic>;
      expect(session['model'], 'gpt-realtime-translate');

      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;
      expect(input.containsKey('transcription'), isFalse);
      expect(input['noise_reduction'], {'type': 'near_field'});
      expect(input.containsKey('turn_detection'), isFalse);
      expect(audio['output'], {'language': 'ja'});
    });

    test('can disable translation input noise reduction', () {
      final body = RealtimeTranslationService.buildClientSecretRequestBody(
        model: 'gpt-realtime-translate',
        targetLangCode: 'ja',
        inputNoiseReduction: 'none',
      );

      final session = body['session'] as Map<String, dynamic>;
      final audio = session['audio'] as Map<String, dynamic>;
      expect(audio.containsKey('input'), isFalse);
    });

    test('extracts root client secret response shape', () {
      expect(
        RealtimeTranslationService.extractClientSecret({'value': 'ek_root'}),
        'ek_root',
      );
    });

    test('extracts nested client secret response shape', () {
      expect(
        RealtimeTranslationService.extractClientSecret({
          'client_secret': {'value': 'ek_nested'},
        }),
        'ek_nested',
      );
    });

    test('rejects missing client secret response shape', () {
      expect(
        () => RealtimeTranslationService.extractClientSecret({
          'client_secret': {'value': ''},
        }),
        throwsFormatException,
      );
    });

    test('forwards translated transcript and close events', () {
      final events = <String>[];
      final service = RealtimeTranslationService(
        apiKey: 'test-key',
        targetLangCode: 'ja',
        onEvent: (type, _) => events.add(type),
      );

      service.handleEventForTesting({
        'type': 'session.output_transcript.delta',
        'delta': 'こんにちは',
      });
      service.handleEventForTesting({
        'type': 'session.output_transcript.done',
        'transcript': 'こんにちは',
      });
      service.handleEventForTesting({'type': 'session.closed'});

      expect(events, [
        'session.output_transcript.delta',
        'session.output_transcript.done',
        'session.closed',
      ]);
    });
  });
}
