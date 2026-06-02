import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, debugPrint, TargetPlatform;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/language.dart';
import 'web_speech_tts.dart';

class SpeechService {
  static const _listenForDuration = Duration(seconds: 30);
  static const _webSttRestartGap = Duration(milliseconds: 220);
  static const _nextSpeechPrimeHoldDuration = Duration(milliseconds: 120);
  static const _nextSpeechPrimeUtterance = '.';
  static SpeechListenOptions _listenOptions({required bool fastInterim}) {
    return SpeechListenOptions(
      cancelOnError: true,
      partialResults: true,
      listenMode: fastInterim && defaultTargetPlatform == TargetPlatform.android
          ? ListenMode.search
          : ListenMode.dictation,
      autoPunctuation: !fastInterim,
    );
  }

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final WebSpeechTtsService _webSpeech = WebSpeechTtsService();
  Future<bool>? _initializeFuture;
  Future<void>? _ttsPrepareFuture;
  Future<void>? _voiceCacheFuture;
  bool _initialized = false;
  bool _ttsPrepared = false;
  bool _voicesCached = false;
  bool _voiceCacheRetryScheduled = false;
  bool _ttsWarmupRestorePending = false;
  bool _ttsMayBeSpeaking = false;
  bool _ttsWarmupSpeechActive = false;
  DateTime? _lastSttStopAt;
  String? _activeTtsLocale;
  double? _activeTtsRate;
  String? _activeTtsVoice;
  void Function()? _ttsStartCallback;
  int _ttsCommandGeneration = 0;
  int _voiceCacheRetryCount = 0;
  static const _verboseLogs = false;
  static const _voiceLangCodes = [
    'ko',
    'ja',
    'zh',
    'en',
    'de',
    'fr',
    'vi',
    'ru',
  ];
  final Map<String, String> _voiceCache = {}; // 'ja_male' -> voice name

  Future<bool> initialize() async {
    if (_initialized) return true;
    final current = _initializeFuture;
    if (current != null) return current;

    final future = _stt.initialize().then((initialized) {
      _initialized = initialized;
      return initialized;
    });
    _initializeFuture = future;
    try {
      return await future;
    } finally {
      _initializeFuture = null;
    }
  }

  Future<void> _prepareTts() async {
    if (_ttsPrepared) return;
    final current = _ttsPrepareFuture;
    if (current != null) return current;

    final future = () async {
      try {
        await _tts.setSharedInstance(true);
      } catch (_) {}
      _tts.setStartHandler(() {
        final callback = _ttsStartCallback;
        _ttsStartCallback = null;
        callback?.call();
      });
      _tts.setCompletionHandler(() {
        _ttsStartCallback = null;
        _ttsMayBeSpeaking = false;
        unawaited(_restoreWarmupVolume());
      });
      _tts.setCancelHandler(() {
        _ttsStartCallback = null;
        _ttsMayBeSpeaking = false;
        unawaited(_restoreWarmupVolume());
      });
      _tts.setErrorHandler((_) {
        _ttsStartCallback = null;
        _ttsMayBeSpeaking = false;
        unawaited(_restoreWarmupVolume());
      });
      _ttsPrepared = true;
    }();
    _ttsPrepareFuture = future;
    try {
      await future;
    } finally {
      _ttsPrepareFuture = null;
    }
  }

  Future<void> _cacheVoices() async {
    if (_voicesCached) return;
    final current = _voiceCacheFuture;
    if (current != null) return current;

    final future = _cacheVoicesNow();
    _voiceCacheFuture = future;
    try {
      await future;
    } finally {
      _voiceCacheFuture = null;
    }
  }

  Future<void> _cacheVoicesNow() async {
    try {
      await _prepareTts();
      var voices = await _tts.getVoices as List<dynamic>;
      if (voices.isEmpty) {
        _scheduleVoiceCacheRetry();
        _voicesCached = true;
        return;
      }

      _log('Total voices: ${voices.length}');

      final selections = {
        for (final lang in _voiceLangCodes) lang: _VoiceSelection(),
      };
      for (final voice in voices) {
        final locale = (voice['locale'] ?? voice['name'] ?? '')
            .toString()
            .toLowerCase();
        final name = (voice['name'] ?? '').toString().toLowerCase();
        for (final lang in _voiceLangCodes) {
          if (!locale.contains(lang)) continue;
          selections[lang]!.add(voice, name);
          _log('  ${voice['name']} (${voice['locale']})');
        }
      }

      for (final lang in _voiceLangCodes) {
        final selection = selections[lang]!;
        _log('$lang voices: ${selection.count}');
        if (selection.count == 0) continue;

        final female = selection.femaleVoice ?? selection.firstVoice;
        final male =
            selection.maleVoice ??
            (selection.count >= 2 ? selection.lastVoice : selection.firstVoice);
        _voiceCache['${lang}_female'] = female['name'];
        _voiceCache['${lang}_male'] = male['name'];
      }

      _log('Voice cache: $_voiceCache');
      _voicesCached = true;
    } catch (e) {
      _log('Voice cache error: $e');
      _voicesCached = true;
    }
  }

  void _scheduleVoiceCacheRetry() {
    if (_voiceCacheRetryScheduled || _voiceCacheRetryCount >= 2) return;
    _voiceCacheRetryScheduled = true;
    _voiceCacheRetryCount++;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 500), () async {
        _voiceCacheRetryScheduled = false;
        _voicesCached = false;
        try {
          await _cacheVoices();
        } catch (_) {}
      }),
    );
  }

  bool get isAvailable => _initialized;

  Future<bool> startListening({
    required String locale,
    required Function(String text, bool isFinal) onResult,
    required Function() onDone,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
    int pauseSeconds = 3,
    bool fastInterim = false,
  }) async {
    if (!_initialized && !await initialize()) {
      onDone();
      return false;
    }
    if (_stt.isListening) {
      await stopListening();
    }
    await _waitForWebSttRestartGap();

    _stt.statusListener = (status) {
      onStatus?.call(status);
      if (status == 'done' || status == 'notListening') {
        onDone();
      }
    };

    _stt.errorListener = (error) {
      final message = '${error.errorMsg} permanent=${error.permanent}';
      onError?.call(message);
      onDone();
    };

    try {
      await _listenWithOptions(
        locale: locale,
        pauseSeconds: pauseSeconds,
        fastInterim: fastInterim,
        onResult: onResult,
      );
    } catch (error) {
      if (!_isAlreadyStartedError(error)) rethrow;
      try {
        await _stt.cancel();
      } catch (_) {}
      _markSttStopped();
      await _waitForWebSttRestartGap();
      await _listenWithOptions(
        locale: locale,
        pauseSeconds: pauseSeconds,
        fastInterim: fastInterim,
        onResult: onResult,
      );
    }
    return true;
  }

  Future<void> _listenWithOptions({
    required String locale,
    required int pauseSeconds,
    required bool fastInterim,
    required Function(String text, bool isFinal) onResult,
  }) {
    return _stt.listen(
      localeId: locale,
      onResult: (result) {
        onResult(result.recognizedWords, result.finalResult);
      },
      listenFor: _listenForDuration,
      pauseFor: Duration(seconds: pauseSeconds),
      listenOptions: _listenOptions(fastInterim: fastInterim),
    );
  }

  Future<void> stopListening() async {
    if (!_initialized) return;
    if (_stt.isListening) {
      await _stt.stop();
    }
    _markSttStopped();
  }

  bool get isListening => _stt.isListening;

  void _markSttStopped() {
    if (kIsWeb) _lastSttStopAt = DateTime.now();
  }

  Future<void> _waitForWebSttRestartGap() async {
    if (!kIsWeb) return;
    final stoppedAt = _lastSttStopAt;
    if (stoppedAt == null) return;
    final elapsed = DateTime.now().difference(stoppedAt);
    if (elapsed >= _webSttRestartGap) return;
    await Future<void>.delayed(_webSttRestartGap - elapsed);
  }

  bool _isAlreadyStartedError(Object error) {
    if (!kIsWeb) return false;
    final message = error.toString().toLowerCase();
    return message.contains('already started') ||
        message.contains('recognition has already started');
  }

  String _resolveLocale(String code) {
    return getLangByCode(code).ttsLocale;
  }

  void _log(String msg) {
    if (_verboseLogs) debugPrint('[TTS] $msg');
  }

  Future<bool> _configureTts({
    required int generation,
    required String lang,
    required double rate,
    required String gender,
  }) async {
    await _prepareTts();
    if (generation != _ttsCommandGeneration) return false;
    await _cacheVoices();
    if (generation != _ttsCommandGeneration) return false;
    if (_ttsWarmupRestorePending || _ttsWarmupSpeechActive) {
      await _restoreWarmupVolume(stopWarmup: !kIsWeb);
      if (generation != _ttsCommandGeneration) return false;
    }

    // Use proper locale from language model (e.g. ko→ko-KR, ja→ja-JP)
    final locale = lang.contains('-') ? lang : _resolveLocale(lang);
    if (_activeTtsLocale != locale) {
      await _tts.setLanguage(locale);
      if (generation != _ttsCommandGeneration) return false;
      _activeTtsLocale = locale;
      _activeTtsVoice = null;
    }

    // Android: flutter_tts internally multiplies rate by 2x
    // So 0.5 in flutter_tts = 1.0 native = normal speed
    final adjustedRate = kIsWeb ? rate : rate * 0.5;
    if (_activeTtsRate != adjustedRate) {
      await _tts.setSpeechRate(adjustedRate);
      if (generation != _ttsCommandGeneration) return false;
      _activeTtsRate = adjustedRate;
    }

    // Use cached voice (index-based on Android since no gender metadata)
    final key = '${lang}_$gender';
    final voice = _voiceCache[key];
    if (voice != null && _activeTtsVoice != voice) {
      await _tts.setVoice({'name': voice, 'locale': locale});
      if (generation != _ttsCommandGeneration) return false;
      _activeTtsVoice = voice;
    }
    return true;
  }

  Future<void> prepareTtsVoice(
    String lang, {
    double rate = 1.0,
    String gender = 'female',
    bool directWebSpeech = false,
  }) async {
    if (kIsWeb && directWebSpeech) {
      await _webSpeech.prepareVoice(lang, rate: rate, gender: gender);
      return;
    }
    if (_ttsMayBeSpeaking) return;
    final generation = _ttsCommandGeneration;
    await _configureTts(
      generation: generation,
      lang: lang,
      rate: rate,
      gender: gender,
    );
  }

  Future<void> primeTtsForNextSpeech(
    String lang, {
    double rate = 1.0,
    String gender = 'female',
    bool webSilentUtterance = false,
    bool directWebSpeech = false,
  }) async {
    if (kIsWeb && directWebSpeech) {
      await _webSpeech.prepareVoice(lang, rate: rate, gender: gender);
      return;
    }
    if (kIsWeb && !webSilentUtterance) {
      await prepareTtsVoice(lang, rate: rate, gender: gender);
      return;
    }
    if (!kIsWeb) {
      await prepareTtsVoice(lang, rate: rate, gender: gender);
      return;
    }
    if (_ttsMayBeSpeaking) return;
    final generation = ++_ttsCommandGeneration;
    final configured = await _configureTts(
      generation: generation,
      lang: lang,
      rate: rate,
      gender: gender,
    );
    if (!configured) return;

    try {
      _ttsWarmupRestorePending = true;
      await _tts.setVolume(0);
      if (generation != _ttsCommandGeneration) {
        await _restoreWarmupVolume();
        return;
      }
      _ttsMayBeSpeaking = true;
      _ttsWarmupSpeechActive = true;
      await _tts.speak(_nextSpeechPrimeUtterance);
      unawaited(
        Future<void>.delayed(_nextSpeechPrimeHoldDuration, () async {
          if (generation != _ttsCommandGeneration ||
              !_ttsWarmupRestorePending) {
            return;
          }
          try {
            _ttsMayBeSpeaking = false;
            await _restoreWarmupVolume(stopWarmup: !kIsWeb);
          } catch (_) {}
        }),
      );
    } catch (_) {
      if (generation == _ttsCommandGeneration) {
        _ttsMayBeSpeaking = false;
        await _restoreWarmupVolume();
      }
    }
  }

  Future<void> speak(
    String text,
    String lang, {
    double rate = 1.0,
    String gender = 'female',
    bool directWebSpeech = false,
    void Function()? onStart,
    void Function()? onReadyToSpeak,
    void Function()? onSpeakReturned,
  }) async {
    if (kIsWeb && directWebSpeech) {
      final generation = ++_ttsCommandGeneration;
      var started = false;
      Timer? fallbackTimer;
      _ttsMayBeSpeaking = true;
      await _webSpeech.speak(
        text,
        lang,
        rate: rate,
        gender: gender,
        onReadyToSpeak: onReadyToSpeak,
        onStart: () {
          if (generation != _ttsCommandGeneration) return;
          started = true;
          fallbackTimer?.cancel();
          onStart?.call();
        },
        onSpeakReturned: onSpeakReturned,
        onDone: () {
          fallbackTimer?.cancel();
          if (generation == _ttsCommandGeneration) {
            _ttsMayBeSpeaking = false;
          }
        },
      );
      fallbackTimer = Timer(const Duration(milliseconds: 900), () {
        if (started || generation != _ttsCommandGeneration) return;
        unawaited(
          _fallbackFromDirectWebSpeech(
            generation: generation,
            text: text,
            lang: lang,
            rate: rate,
            gender: gender,
            onStart: onStart,
          ),
        );
      });
      return;
    }
    final generation = ++_ttsCommandGeneration;
    await _speakWithFlutterTts(
      generation: generation,
      text: text,
      lang: lang,
      rate: rate,
      gender: gender,
      onStart: onStart,
      onReadyToSpeak: onReadyToSpeak,
      onSpeakReturned: onSpeakReturned,
    );
  }

  Future<String?> synthesizeToFile(
    String text,
    String lang, {
    required String filePath,
    double rate = 1.0,
    String gender = 'female',
  }) async {
    if (kIsWeb) return null;
    final generation = ++_ttsCommandGeneration;
    final configured = await _configureTts(
      generation: generation,
      lang: lang,
      rate: rate,
      gender: gender,
    );
    if (!configured) return null;

    _ttsMayBeSpeaking = true;
    try {
      await _tts.awaitSynthCompletion(true);
      await _tts.synthesizeToFile(text, filePath, true);
      if (generation != _ttsCommandGeneration) return null;
      return filePath;
    } finally {
      if (generation == _ttsCommandGeneration) {
        _ttsMayBeSpeaking = false;
      }
    }
  }

  Future<void> _fallbackFromDirectWebSpeech({
    required int generation,
    required String text,
    required String lang,
    required double rate,
    required String gender,
    void Function()? onStart,
  }) async {
    if (generation != _ttsCommandGeneration) return;
    try {
      await _webSpeech.stop();
    } catch (_) {}
    if (generation != _ttsCommandGeneration) return;
    await _speakWithFlutterTts(
      generation: generation,
      text: text,
      lang: lang,
      rate: rate,
      gender: gender,
      onStart: onStart,
    );
  }

  Future<void> _speakWithFlutterTts({
    required int generation,
    required String text,
    required String lang,
    required double rate,
    required String gender,
    void Function()? onStart,
    void Function()? onReadyToSpeak,
    void Function()? onSpeakReturned,
  }) async {
    final configured = await _configureTts(
      generation: generation,
      lang: lang,
      rate: rate,
      gender: gender,
    );
    if (!configured) return;

    _ttsMayBeSpeaking = true;
    _ttsStartCallback = onStart == null
        ? null
        : () {
            if (generation == _ttsCommandGeneration) onStart();
          };
    onReadyToSpeak?.call();
    await _tts.speak(text);
    if (generation == _ttsCommandGeneration) onSpeakReturned?.call();
  }

  Future<void> stopSpeaking() async {
    _ttsCommandGeneration++;
    if (!_ttsMayBeSpeaking &&
        !_ttsWarmupRestorePending &&
        !_ttsWarmupSpeechActive) {
      return;
    }
    _ttsMayBeSpeaking = false;
    _ttsWarmupSpeechActive = false;
    await _webSpeech.stop();
    await _tts.stop();
    await _restoreWarmupVolume();
  }

  Future<void> _restoreWarmupVolume({bool stopWarmup = false}) async {
    if (!_ttsWarmupRestorePending && !_ttsWarmupSpeechActive) return;
    final shouldStop = stopWarmup && _ttsWarmupSpeechActive;
    _ttsWarmupRestorePending = false;
    _ttsWarmupSpeechActive = false;
    try {
      if (shouldStop) {
        _ttsMayBeSpeaking = false;
        await _tts.stop();
      }
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  bool _ttsWarmedUp = false;
  Future<void> warmupTts() async {
    if (_ttsWarmedUp) return;
    _ttsWarmedUp = true;
    final generation = _ttsCommandGeneration;
    await _prepareTts();
    if (generation != _ttsCommandGeneration) return;
    _log('warmup start');
    await _cacheVoices();
    if (generation != _ttsCommandGeneration) return;
    if (kIsWeb) {
      try {
        await _tts.setVolume(1.0);
      } catch (_) {}
      _log('warmup done');
      return;
    }
    _ttsWarmupRestorePending = true;
    try {
      await _tts.setVolume(0);
      if (generation != _ttsCommandGeneration) {
        await _restoreWarmupVolume();
        return;
      }
      _ttsMayBeSpeaking = true;
      _ttsWarmupSpeechActive = true;
      final r = await _tts.speak('.');
      _log('warmup speak result: $r');
      unawaited(
        Future.delayed(const Duration(milliseconds: 200), () async {
          if (generation != _ttsCommandGeneration ||
              !_ttsWarmupRestorePending) {
            return;
          }
          try {
            _ttsMayBeSpeaking = false;
            await _restoreWarmupVolume(stopWarmup: !kIsWeb);
          } catch (_) {}
        }),
      );
    } catch (e) {
      if (generation == _ttsCommandGeneration) {
        await _restoreWarmupVolume();
      }
      _log('warmup error: $e');
    }
    _log('warmup done');
  }
}

class _VoiceSelection {
  dynamic firstVoice;
  dynamic lastVoice;
  dynamic femaleVoice;
  dynamic maleVoice;
  var count = 0;

  void add(dynamic voice, String lowerName) {
    count++;
    firstVoice ??= voice;
    lastVoice = voice;

    if (femaleVoice == null &&
        (lowerName.contains('female') ||
            lowerName.contains('여') ||
            lowerName.contains('f-'))) {
      femaleVoice = voice;
    }
    if (maleVoice == null &&
        ((lowerName.contains('male') && !lowerName.contains('female')) ||
            lowerName.contains('남') ||
            lowerName.contains('m-'))) {
      maleVoice = voice;
    }
  }
}
