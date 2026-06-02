import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class WebSpeechTtsService {
  final Map<String, web.SpeechSynthesisVoice> _voiceCache = {};
  bool _voicesCached = false;
  int _generation = 0;
  web.SpeechSynthesisUtterance? _activeUtterance;

  Future<void> prepareVoice(
    String lang, {
    required double rate,
    required String gender,
  }) async {
    await _voiceFor(lang, gender);
  }

  Future<void> speak(
    String text,
    String lang, {
    required double rate,
    required String gender,
    void Function()? onStart,
    void Function()? onReadyToSpeak,
    void Function()? onSpeakReturned,
    void Function()? onDone,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final generation = ++_generation;
    final locale = _localeFor(lang);
    final voice = await _voiceFor(lang, gender);
    if (generation != _generation) return;

    final utterance = web.SpeechSynthesisUtterance(trimmed)
      ..lang = locale
      ..rate = rate
      ..volume = 1.0
      ..pitch = 1.0;
    if (voice != null) utterance.voice = voice;
    _activeUtterance = utterance;

    utterance.onstart = ((web.Event _) {
      if (generation == _generation) onStart?.call();
    }).toJS;
    utterance.onend = ((web.Event _) {
      if (generation == _generation) {
        _activeUtterance = null;
        onDone?.call();
      }
    }).toJS;
    utterance.onerror = ((web.Event _) {
      if (generation == _generation) {
        _activeUtterance = null;
        onDone?.call();
      }
    }).toJS;

    onReadyToSpeak?.call();
    final synth = web.window.speechSynthesis;
    if (synth.paused) synth.resume();
    synth.speak(utterance);
    if (generation == _generation) onSpeakReturned?.call();
  }

  Future<void> stop() async {
    final synth = web.window.speechSynthesis;
    if (_activeUtterance == null && !synth.speaking && !synth.pending) {
      return;
    }
    _generation++;
    _activeUtterance = null;
    try {
      synth.cancel();
    } catch (_) {}
  }

  Future<web.SpeechSynthesisVoice?> _voiceFor(
    String lang,
    String gender,
  ) async {
    final normalizedLang = _baseLang(lang);
    final key = '${normalizedLang}_$gender';
    final cached = _voiceCache[key];
    if (cached != null) return cached;
    await _cacheVoices();
    return _voiceCache[key] ?? _voiceCache['${normalizedLang}_fallback'];
  }

  Future<void> _cacheVoices() async {
    if (_voicesCached) return;
    var voices = _voices();
    if (voices.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      voices = _voices();
    }
    if (voices.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      voices = _voices();
    }

    for (final lang in const ['ko', 'ja', 'zh', 'en', 'de', 'fr', 'vi', 'ru']) {
      final langVoices = voices.where((voice) {
        final locale = voice.lang.toLowerCase();
        final name = voice.name.toLowerCase();
        return locale.startsWith(lang) || name.contains(lang);
      }).toList();
      if (langVoices.isEmpty) continue;

      _voiceCache['${lang}_fallback'] = langVoices.first;
      _voiceCache['${lang}_female'] =
          _firstMatching(langVoices, _looksFemale) ?? langVoices.first;
      _voiceCache['${lang}_male'] =
          _firstMatching(langVoices, _looksMale) ??
          (langVoices.length >= 2 ? langVoices.last : langVoices.first);
    }
    _voicesCached = true;
  }

  List<web.SpeechSynthesisVoice> _voices() {
    try {
      return web.window.speechSynthesis.getVoices().toDart;
    } catch (_) {
      return const [];
    }
  }

  web.SpeechSynthesisVoice? _firstMatching(
    List<web.SpeechSynthesisVoice> voices,
    bool Function(String lowerName) test,
  ) {
    for (final voice in voices) {
      if (test(voice.name.toLowerCase())) return voice;
    }
    return null;
  }

  bool _looksFemale(String lowerName) {
    return lowerName.contains('female') ||
        lowerName.contains('woman') ||
        lowerName.contains('여') ||
        lowerName.contains('f-');
  }

  bool _looksMale(String lowerName) {
    return (lowerName.contains('male') && !lowerName.contains('female')) ||
        lowerName.contains('man') ||
        lowerName.contains('남') ||
        lowerName.contains('m-');
  }

  String _baseLang(String lang) {
    final index = lang.indexOf('-');
    return (index <= 0 ? lang : lang.substring(0, index)).toLowerCase();
  }

  String _localeFor(String lang) {
    return switch (_baseLang(lang)) {
      'ko' => 'ko-KR',
      'ja' => 'ja-JP',
      'zh' => 'zh-CN',
      'en' => 'en-US',
      'de' => 'de-DE',
      'fr' => 'fr-FR',
      'vi' => 'vi-VN',
      'ru' => 'ru-RU',
      _ => lang,
    };
  }
}
