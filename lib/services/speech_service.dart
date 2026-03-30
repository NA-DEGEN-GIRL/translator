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
      var voices = await _tts.getVoices as List<dynamic>;
      if (voices.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        voices = await _tts.getVoices as List<dynamic>;
      }

      _log('Total voices: ${voices.length}');

      for (final lang in ['ko','ja','zh','en','de','fr','vi','ru']) {
        final prefix = lang == 'ja' ? 'ja' : 'ko';
        final langVoices = voices.where((v) {
          final locale = (v['locale'] ?? v['name'] ?? '').toString().toLowerCase();
          return locale.contains(prefix);
        }).toList();

        _log('$lang voices: ${langVoices.length}');
        for (final v in langVoices) {
          _log('  ${v['name']} (${v['locale']})');
        }

        if (langVoices.isEmpty) continue;

        // Try matching by name keywords
        final female = langVoices.where((v) {
          final n = (v['name'] ?? '').toString().toLowerCase();
          return n.contains('female') || n.contains('여') || n.contains('f-');
        }).toList();
        final male = langVoices.where((v) {
          final n = (v['name'] ?? '').toString().toLowerCase();
          return (n.contains('male') && !n.contains('female')) ||
              n.contains('남') || n.contains('m-');
        }).toList();

        if (female.isNotEmpty) {
          _voiceCache['${lang}_female'] = female.first['name'];
        } else if (langVoices.length >= 2) {
          // Assume first = female, second = male (common convention)
          _voiceCache['${lang}_female'] = langVoices.first['name'];
        } else {
          _voiceCache['${lang}_female'] = langVoices.first['name'];
        }

        if (male.isNotEmpty) {
          _voiceCache['${lang}_male'] = male.first['name'];
        } else if (langVoices.length >= 2) {
          _voiceCache['${lang}_male'] = langVoices.last['name'];
        } else {
          _voiceCache['${lang}_male'] = langVoices.first['name'];
        }
      }

      _log('Voice cache: $_voiceCache');
      _voicesCached = true;
    } catch (e) {
      _log('Voice cache error: $e');
    }
  }

  bool get isAvailable => _initialized;

  Future<void> startListening({
    required String locale,
    required Function(String text, bool isFinal) onResult,
    required Function() onDone,
    int pauseSeconds = 3,
  }) async {
    if (!_initialized) await initialize();

    _stt.statusListener = (status) {
      if (status == 'done' || status == 'notListening') {
        onDone();
      }
    };

    _stt.errorListener = (error) {
      _log('STT error: ${error.errorMsg}');
      onDone();
    };

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
    final locale = lang.contains('-') ? lang : '$lang-${lang.toUpperCase()}';
    await _tts.setLanguage(locale);

    // Android: flutter_tts internally multiplies rate by 2x
    // So 0.5 in flutter_tts = 1.0 native = normal speed
    final adjustedRate = kIsWeb ? rate : rate * 0.5;
    await _tts.setSpeechRate(adjustedRate);

    // Use cached voice (index-based on Android since no gender metadata)
    final key = '${lang}_$gender';
    if (_voiceCache.containsKey(key)) {
      await _tts.setVoice({'name': _voiceCache[key]!, 'locale': locale});
    }

    await _tts.speak(text);
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
