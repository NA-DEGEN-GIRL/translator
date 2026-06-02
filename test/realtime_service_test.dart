import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/realtime_service.dart';

void main() {
  group('RealtimeService', () {
    test('builds realtime session with input transcription enabled', () {
      final service = RealtimeService(
        apiKey: 'test-key',
        sourceLangCode: 'ko',
        targetLangCode: 'ja',
        inputTranscriptionLanguage: 'ko',
        onEvent: (_, _) {},
      );

      final session = service.buildSessionConfigForTesting();

      expect(session['model'], 'gpt-realtime-2');
      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;
      expect(input['noise_reduction'], {'type': 'near_field'});
      expect(input['transcription'], {
        'model': 'gpt-4o-transcribe',
        'language': 'ko',
      });
    });

    test('builds server_vad turn detection by default with tunables', () {
      final service = RealtimeService(
        apiKey: 'test-key',
        vadThreshold: 0.7,
        silenceDurationMs: 700,
        onEvent: (_, _) {},
      );

      final session = service.buildSessionConfigForTesting();
      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;
      final td = input['turn_detection'] as Map<String, dynamic>;

      expect(td['type'], 'server_vad');
      expect(td['threshold'], 0.7);
      expect(td['silence_duration_ms'], 700);
      expect(td['create_response'], true);
    });

    test('builds semantic_vad turn detection with eagerness', () {
      final service = RealtimeService(
        apiKey: 'test-key',
        turnDetectionType: 'semantic_vad',
        vadEagerness: 'high',
        onEvent: (_, _) {},
      );

      final session = service.buildSessionConfigForTesting();
      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;
      final td = input['turn_detection'] as Map<String, dynamic>;

      expect(td['type'], 'semantic_vad');
      expect(td['eagerness'], 'high');
      expect(td.containsKey('threshold'), isFalse);
      expect(td.containsKey('silence_duration_ms'), isFalse);
      expect(td['create_response'], true);
    });

    test('can disable input transcription', () {
      final service = RealtimeService(
        apiKey: 'test-key',
        inputTranscriptionEnabled: false,
        onEvent: (_, _) {},
      );

      final session = service.buildSessionConfigForTesting();
      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;

      expect(input.containsKey('transcription'), isFalse);
      expect(input.containsKey('noise_reduction'), isFalse);
    });

    test('maps input transcription events to the response turn', () {
      final forwarded = <String>[];
      final service = RealtimeService(
        apiKey: 'test-key',
        onEvent: (type, _) => forwarded.add(type),
      );

      service.handleEventForTesting({
        'type': 'conversation.item.added',
        'item': {'id': 'item_1', 'type': 'message', 'role': 'user'},
      });
      service.handleEventForTesting({
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'item_1',
        'delta': '안녕',
      });

      expect(service.inputTranscriptForItem('item_1'), '안녕');

      service.handleEventForTesting({
        'type': 'response.created',
        'response': {'id': 'resp_1'},
      });
      service.handleEventForTesting({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'item_1',
        'transcript': '안녕하세요',
      });
      service.handleEventForTesting({
        'type': 'response.output_text.delta',
        'response_id': 'resp_1',
        'delta': 'こんにちは',
      });

      expect(service.turns['resp_1']?.input, '안녕하세요');
      expect(service.turns['resp_1']?.output, 'こんにちは');
      expect(forwarded, [
        'conversation.item.input_audio_transcription.delta',
        'response.created',
        'conversation.item.input_audio_transcription.completed',
        'response.output_text.delta',
      ]);
    });

    test('keeps late final transcript after a response turn is removed', () {
      final service = RealtimeService(apiKey: 'test-key', onEvent: (_, _) {});

      service.handleEventForTesting({
        'type': 'conversation.item.added',
        'item': {'id': 'item_1', 'type': 'message', 'role': 'user'},
      });
      service.handleEventForTesting({
        'type': 'response.created',
        'response': {'id': 'resp_1'},
      });
      service.removeTurn('resp_1');
      service.handleEventForTesting({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'item_1',
        'transcript': '늦게 도착한 원문',
      });

      expect(service.inputTranscriptForItem('item_1'), '늦게 도착한 원문');
    });
  });
}
