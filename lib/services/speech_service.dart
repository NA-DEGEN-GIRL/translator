import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SpeechService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _voicesCached = false;
  Map<String, String> _voiceCache = {}; // 'ja_male' -> voice name

  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize();
    try { await _tts.setSharedInstance(true); } catch (_) {}
    await _cacheVoices();
    return _initialized;
  }

  Future<void> _cacheVoices() async {
    if (_voicesCached) return;
    try {
      // Browser may load voices asynchronously — retry if empty
      var voices = await _tts.getVoices as List<dynamic>;
      if (voices.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        voices = await _tts.getVoices as List<dynamic>;
      }
      for (final lang in ['ja', 'ko']) {
        final prefix = lang == 'ja' ? 'ja' : 'ko';
        final langVoices = voices.where((v) {
          return (v['locale'] ?? '').toString().startsWith(prefix);
        }).toList();

        if (langVoices.isEmpty) continue;

        // Find male/female
        final female = langVoices.where((v) =>
            (v['name'] ?? '').toString().toLowerCase().contains('female')).toList();
        final male = langVoices.where((v) {
          final n = (v['name'] ?? '').toString().toLowerCase();
          return n.contains('male') && !n.contains('female');
        }).toList();

        _voiceCache['${lang}_female'] = female.isNotEmpty
            ? female.first['name'] : langVoices.first['name'];
        _voiceCache['${lang}_male'] = male.isNotEmpty
            ? male.first['name'] : langVoices.last['name'];
      }
      _voicesCached = true;
    } catch (_) {}
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

  void _log(String msg) {
    debugPrint('[TTS] $msg');
  }

  Future<void> speak(String text, String lang, {double rate = 1.0, String gender = 'female'}) async {
    final locale = lang == 'ja' ? 'ja-JP' : 'ko-KR';
    _log('speak called: lang=$lang, gender=$gender, rate=$rate, warmedUp=$_ttsWarmedUp');
    _log('text: "${text.length > 30 ? text.substring(0, 30) : text}"');

    await _tts.setLanguage(locale);
    await _tts.setSpeechRate(rate);

    final key = '${lang}_$gender';
    _log('voice cache: $_voiceCache');
    if (_voiceCache.containsKey(key)) {
      _log('setting voice: ${_voiceCache[key]}');
      await _tts.setVoice({'name': _voiceCache[key]!, 'locale': locale});
    } else {
      _log('no cached voice for $key');
    }

    final result = await _tts.speak(text);
    _log('speak result: $result');
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  bool _ttsWarmedUp = false;
  Future<void> warmupTts() async {
    if (_ttsWarmedUp) return;
    _ttsWarmedUp = true;
    _log('warmup start');
    await _cacheVoices();
    await _tts.setVolume(0);
    final r = await _tts.speak('.');
    _log('warmup speak result: $r');
    await Future.delayed(const Duration(milliseconds: 200));
    await _tts.stop();
    await _tts.setVolume(1.0);
    _log('warmup done');
  }
}
