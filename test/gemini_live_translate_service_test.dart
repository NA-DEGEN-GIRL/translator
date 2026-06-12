import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/gemini_live_translate_service.dart';

void main() {
  group('GeminiLiveTranslateService', () {
    GeminiLiveTranslateService build(String target) => GeminiLiveTranslateService(
      apiKey: 'test-key',
      targetLangCode: target,
      onEvent: (_, _) {},
    );

    test('setup message carries translationConfig with echoTargetLanguage=false', () {
      final setup = build('ja').debugBuildSetupMessage();
      final s = setup['setup'] as Map<String, dynamic>;
      expect(s['model'], 'models/${GeminiLiveTranslateService.defaultModel}');

      final gen = s['generationConfig'] as Map<String, dynamic>;
      expect(gen['responseModalities'], ['AUDIO']);

      final tc = gen['translationConfig'] as Map<String, dynamic>;
      expect(tc['targetLanguageCode'], 'ja');
      expect(tc['echoTargetLanguage'], false);
    });

    test('setup enables input and output transcription', () {
      final s = build('ko').debugBuildSetupMessage()['setup']
          as Map<String, dynamic>;
      expect(s.containsKey('inputAudioTranscription'), true);
      expect(s.containsKey('outputAudioTranscription'), true);
    });

    test('input sample rate is 16kHz', () {
      expect(GeminiLiveTranslateService.inputSampleRateHz, 16000);
    });
  });
}
