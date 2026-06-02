import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/realtime_transcription_ws_service.dart';

void main() {
  group('RealtimeTranscriptionWsService', () {
    test('builds a transcription session for streamed pcm audio', () {
      final service = RealtimeTranscriptionWsService(
        apiKey: 'test-key',
        language: 'ko',
        delay: 'minimal',
      );

      final payload = service.buildSessionUpdatePayloadForTesting();
      final session = payload['session'] as Map<String, dynamic>;
      final audio = session['audio'] as Map<String, dynamic>;
      final input = audio['input'] as Map<String, dynamic>;

      expect(payload['type'], 'session.update');
      expect(session['type'], 'transcription');
      expect(input['format'], {'type': 'audio/pcm', 'rate': 24000});
      expect(input['transcription'], {
        'model': 'gpt-realtime-whisper',
        'language': 'ko',
        'delay': 'minimal',
      });
      expect(input['turn_detection'], isNull);
      expect(input['noise_reduction'], {'type': 'near_field'});
    });

    test('forwards transcript deltas', () {
      final deltas = <String>[];
      final service = RealtimeTranscriptionWsService(
        apiKey: 'test-key',
        language: 'ja',
        onDelta: deltas.add,
      );

      service.handleEventForTesting({
        'type': 'conversation.item.input_audio_transcription.delta',
        'delta': 'こん',
      });
      service.handleEventForTesting({
        'type': 'conversation.item.input_audio_transcription.delta',
        'delta': 'にちは',
      });

      expect(deltas, ['こん', 'にちは']);
    });

    test('does not final-commit buffers shorter than realtime API minimum', () {
      final service = RealtimeTranscriptionWsService(
        apiKey: 'test-key',
        language: 'ko',
      );

      expect(service.minApiCommitBytesForTesting(), 4800);
    });
  });
}
