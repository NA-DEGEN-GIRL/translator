import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SpeechService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize();
    await _tts.setSharedInstance(true);
    return _initialized;
  }

  bool get isAvailable => _initialized;

  Future<void> startListening({
    required String locale,
    required Function(String text, bool isFinal) onResult,
    required Function() onDone,
    int pauseSeconds = 3,
  }) async {
    if (!_initialized) await initialize();
    await _stt.listen(
      localeId: locale,
      onResult: (result) {
        onResult(result.recognizedWords, result.finalResult);
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: Duration(seconds: pauseSeconds),
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
      ),
    );
  }

  Future<void> stopListening() async {
    await _stt.stop();
  }

  bool get isListening => _stt.isListening;

  Future<void> speak(String text, String lang, {double rate = 1.0}) async {
    await _tts.setLanguage(lang == 'ja' ? 'ja-JP' : 'ko-KR');
    await _tts.setSpeechRate(rate);
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
  }
}
