import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/google_translation_bridge_service.dart';

void main() {
  group('GoogleTranslationBridgeService', () {
    test('builds bridge start message for Google Media Translation', () {
      final message = GoogleTranslationBridgeService.buildStartMessage(
        sourceLangCode: 'ko',
        targetLangCode: 'ja',
      );

      expect(message['type'], 'session.start');
      expect(message['provider'], 'google.media_translation');
      expect(message['source_language_code'], 'ko');
      expect(message['target_language_code'], 'ja');
      expect(message['interim_results'], isTrue);
      expect(message['audio'], {
        'encoding': 'linear16',
        'sample_rate_hz': 16000,
        'channels': 1,
      });
    });

    test('builds base64 audio append payload', () {
      final payload = GoogleTranslationBridgeService.buildAudioAppendPayload(
        Uint8List.fromList([1, 2, 3, 4]),
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['type'], 'audio.append');
      expect(decoded['audio'], base64Encode([1, 2, 3, 4]));
    });

    test('normalizes transcript aliases', () {
      final delta = GoogleTranslationBridgeService.normalizeServerEvent({
        'type': 'transcript.delta',
        'text': '안녕',
      });
      final done = GoogleTranslationBridgeService.normalizeServerEvent({
        'type': 'transcript.final',
        'text': '안녕하세요',
      });

      expect(delta?['type'], 'source_transcript.delta');
      expect(delta?['delta'], '안녕');
      expect(done?['type'], 'source_transcript.done');
      expect(done?['transcript'], '안녕하세요');
    });

    test('normalizes Google media translation response result', () {
      final delta = GoogleTranslationBridgeService.normalizeServerEvent({
        'type': 'google.media_translation.response',
        'result': {
          'text_translation_result': {
            'translation': 'こんにちは',
            'is_final': false,
          },
        },
      });
      final done = GoogleTranslationBridgeService.normalizeServerEvent({
        'result': {
          'textTranslationResult': {'translation': 'こんにちは', 'isFinal': true},
        },
      });

      expect(delta?['type'], 'translation.delta');
      expect(delta?['delta'], 'こんにちは');
      expect(done?['type'], 'translation.done');
      expect(done?['transcript'], 'こんにちは');
    });

    test('returns null for malformed messages', () {
      expect(
        GoogleTranslationBridgeService.normalizeServerEvent('not-json'),
        isNull,
      );
      expect(
        GoogleTranslationBridgeService.normalizeServerEvent([1, 2, 3]),
        isNull,
      );
    });
  });
}
