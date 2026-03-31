import 'dart:async';
import 'dart:io' as java_io;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http_client;
import '../services/openai_service.dart';
import '../services/speech_service.dart';
import '../services/realtime_service.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/settings_sheet.dart';
import '../models/language.dart';
import '../prompts.dart';
import '../main.dart' show clearApiKey, ApiKeyScreen;

class TranslatorScreen extends StatefulWidget {
  final String apiKey;
  const TranslatorScreen({super.key, required this.apiKey});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen> {
  late OpenAIService _openai;
  final SpeechService _speech = SpeechService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _myScrollController = ScrollController();
  final ScrollController _mirrorScrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  bool _isListening = false;
  bool _isMirrorListening = false;
  bool _isProcessing = false;
  String _interimText = '';
  String _mirrorInterimText = '';

  // Realtime
  RealtimeService? _realtime;
  bool _realtimeActive = false;

  // Settings
  String _textDirection = 'source2target'; // for text input
  bool _aiMode = false;
  String _mode = 'openai'; // browser, openai, realtime
  String _model = 'gpt-5.4-nano';
  String _aiModel = 'gpt-5.4-mini';
  int _aiPauseSeconds = 5; // AI mode silence timeout (longer than translation)
  String _sourceLang = 'ko';
  String _targetLang = 'ja';
  String _displayMode = 'face'; // 'face' (대면) or 'one' (단방향)
  bool _ttsSourceEnabled = false;
  bool _ttsTargetEnabled = false;
  String _voiceSource = 'nova';
  String _voiceTarget = 'onyx';
  double _fontSize = 16;
  String _micLang = 'ko';
  double _ttsSpeed = 1.0;
  int _pauseSeconds = 3;
  double _vadThreshold = 0.9;
  double _noiseThreshold = -30;
  String _toneMode = 'normal'; // normal, polite, casual
  ToneMode get _tone => switch (_toneMode) {
    'polite' => ToneMode.polite,
    'casual' => ToneMode.casual,
    _ => ToneMode.normal,
  };
  String _realtimeVoice = 'coral';
  String _realtimeModel = 'gpt-realtime-mini';
  String _detectModel = 'gpt-5.4-nano'; // model for RT language detection
  bool _backTranslateSource = true;
  bool _backTranslateTarget = true;
  bool _showPronunciation = false;
  bool _deleteConversationItems = true;
  bool _injectFewShot = true;
  bool _translationContext = false;
  double _translationTemp = 0.3;
  double _classifyTemp = 0.1;
  double _pronunciationTemp = 0.3;
  PromptTemplateSet _promptTemplates = AppPrompts.defaults;

  @override
  void initState() {
    super.initState();
    _openai = OpenAIService(widget.apiKey);
    _speech.initialize();
    _loadSettings();
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _silenceTimer?.cancel();
    _speech.stopListening();
    _speech.stopSpeaking();
    _realtime?.stop();
    _recorder.dispose();
    _textController.dispose();
    _myScrollController.dispose();
    _mirrorScrollController.dispose();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final promptTemplates = await AppPrompts.loadTemplates();
    setState(() {
      _sourceLang = prefs.getString('sourceLang') ?? 'ko';
      _targetLang = prefs.getString('targetLang') ?? 'ja';
      _displayMode = prefs.getString('displayMode') ?? 'face';
      _ttsSourceEnabled = prefs.getBool('ttsSource') ?? false;
      _ttsTargetEnabled = prefs.getBool('ttsTarget') ?? false;
      _voiceSource = prefs.getString('voiceSource') ?? 'nova';
      _voiceTarget = prefs.getString('voiceTarget') ?? 'onyx';
      _fontSize = prefs.getDouble('fontSize') ?? 16;
      final savedMode = prefs.getString('mode') ?? 'openai';
      _mode = (savedMode == 'browser') ? 'openai' : savedMode; // migrate legacy
      final savedModel = prefs.getString('model') ?? 'gpt-5.4-nano';
      _model = savedModel.startsWith('gpt-4.1') ? 'gpt-5.4-nano' : savedModel;
      final savedAiModel = prefs.getString('aiModel') ?? 'gpt-5.4-mini';
      _aiModel = savedAiModel.startsWith('gpt-4.1') ? 'gpt-5.4-mini' : savedAiModel;
      _aiPauseSeconds = prefs.getInt('aiPauseSeconds') ?? 5;
      _ttsSpeed = prefs.getDouble('ttsSpeed') ?? 1.0;
      _pauseSeconds = prefs.getInt('pauseSeconds') ?? 3;
      _toneMode = prefs.getString('toneMode') ?? 'normal';
      _realtimeVoice = prefs.getString('realtimeVoice') ?? 'coral';
      _realtimeModel = prefs.getString('realtimeModel') ?? 'gpt-realtime-mini';
      _detectModel = prefs.getString('detectModel') ?? 'gpt-5.4-nano';
      _backTranslateSource = prefs.getBool('backTranslateSource') ?? true;
      _backTranslateTarget = prefs.getBool('backTranslateTarget') ?? true;
      _showPronunciation = prefs.getBool('showPronunciation') ?? false;
      _deleteConversationItems = prefs.getBool('deleteConversationItems') ?? true;
      _injectFewShot = prefs.getBool('injectFewShot') ?? true;
      _translationContext = prefs.getBool('translationContext') ?? false;
      _translationTemp = prefs.getDouble('translationTemp') ?? 0.3;
      _classifyTemp = prefs.getDouble('classifyTemp') ?? 0.1;
      _pronunciationTemp = prefs.getDouble('pronunciationTemp') ?? 0.3;
      _noiseThreshold = prefs.getDouble('noiseThreshold') ?? (kIsWeb ? -60 : -30);
      _vadThreshold = prefs.getDouble('vadThreshold') ?? 0.9;
      _micLang = _sourceLang;
      _promptTemplates = promptTemplates;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('sourceLang', _sourceLang);
    prefs.setString('targetLang', _targetLang);
    prefs.setString('displayMode', _displayMode);
    prefs.setBool('ttsSource', _ttsSourceEnabled);
    prefs.setBool('ttsTarget', _ttsTargetEnabled);
    prefs.setString('voiceSource', _voiceSource);
    prefs.setString('voiceTarget', _voiceTarget);
    prefs.setDouble('fontSize', _fontSize);
    prefs.setString('mode', _mode);
    prefs.setString('model', _model);
    prefs.setString('aiModel', _aiModel);
    prefs.setInt('aiPauseSeconds', _aiPauseSeconds);
    prefs.setDouble('ttsSpeed', _ttsSpeed);
    prefs.setInt('pauseSeconds', _pauseSeconds);
    prefs.setString('toneMode', _toneMode);
    prefs.setString('realtimeVoice', _realtimeVoice);
    prefs.setString('realtimeModel', _realtimeModel);
    prefs.setString('detectModel', _detectModel);
    prefs.setBool('backTranslateSource', _backTranslateSource);
    prefs.setBool('backTranslateTarget', _backTranslateTarget);
    prefs.setBool('showPronunciation', _showPronunciation);
    prefs.setBool('deleteConversationItems', _deleteConversationItems);
    prefs.setBool('injectFewShot', _injectFewShot);
    prefs.setBool('translationContext', _translationContext);
    prefs.setDouble('translationTemp', _translationTemp);
    prefs.setDouble('classifyTemp', _classifyTemp);
    prefs.setDouble('pronunciationTemp', _pronunciationTemp);
    prefs.setDouble('noiseThreshold', _noiseThreshold);
    prefs.setDouble('vadThreshold', _vadThreshold);
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) => SettingsSheet(
        mode: _mode,
        model: _model,
        realtimeModel: _realtimeModel,
        sourceLang: _sourceLang,
        targetLang: _targetLang,
        displayMode: _displayMode,
        ttsSourceEnabled: _ttsSourceEnabled,
        ttsTargetEnabled: _ttsTargetEnabled,
        voiceSource: _voiceSource,
        voiceTarget: _voiceTarget,
        fontSize: _fontSize,
        ttsSpeed: _ttsSpeed,
        pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
        noiseThreshold: _noiseThreshold,
        vadThreshold: _vadThreshold,
        toneMode: _toneMode,
        realtimeActive: _realtimeActive,
        realtimeVoice: _realtimeVoice,
        onRealtimeVoiceChanged: (v) { setState(() => _realtimeVoice = v); setSheetState((){}); _saveSettings(); },
        aiModel: _aiModel,
        aiPauseSeconds: _aiPauseSeconds,
        onToneModeChanged: (v) { setState(() => _toneMode = v); setSheetState((){}); _saveSettings(); },
        onAiModelChanged: (v) { setState(() => _aiModel = v); setSheetState((){}); _saveSettings(); },
        onAiPauseSecondsChanged: (v) { setState(() => _aiPauseSeconds = v); setSheetState((){}); _saveSettings(); },
        onModeChanged: (v) {
          if (v != 'realtime' && _realtimeActive) _stopRealtime();
          setState(() => _mode = v); setSheetState((){}); _saveSettings();
        },
        onModelChanged: (v) { setState(() => _model = v); setSheetState((){}); _saveSettings(); },
        onRealtimeModelChanged: (v) { setState(() => _realtimeModel = v); setSheetState((){}); _saveSettings(); },
        onSourceLangChanged: (v) { setState(() { _sourceLang = v; _micLang = v; }); setSheetState((){}); _saveSettings(); },
        onTargetLangChanged: (v) { setState(() => _targetLang = v); setSheetState((){}); _saveSettings(); },
        onDisplayModeChanged: (v) { setState(() => _displayMode = v); setSheetState((){}); _saveSettings(); },
        onTtsSourceChanged: (v) { setState(() => _ttsSourceEnabled = v); setSheetState((){}); _saveSettings(); _updateRealtimeAudioMute(); },
        onTtsTargetChanged: (v) { setState(() => _ttsTargetEnabled = v); setSheetState((){}); _saveSettings(); _updateRealtimeAudioMute(); },
        onVoiceSourceChanged: (v) { setState(() => _voiceSource = v); setSheetState((){}); _saveSettings(); },
        onVoiceTargetChanged: (v) { setState(() => _voiceTarget = v); setSheetState((){}); _saveSettings(); },
        onFontSizeChanged: (v) { setState(() => _fontSize = v); setSheetState((){}); _saveSettings(); },
        onTtsSpeedChanged: (v) { setState(() => _ttsSpeed = v); setSheetState((){}); _saveSettings(); },
        onPauseSecondsChanged: (v) { setState(() => _pauseSeconds = v); setSheetState((){}); _saveSettings(); },
        onNoiseThresholdChanged: (v) { setState(() => _noiseThreshold = v); setSheetState((){}); _saveSettings(); },
        onVadThresholdChanged: (v) { setState(() => _vadThreshold = v); setSheetState((){}); _saveSettings(); },
        deleteConversationItems: _deleteConversationItems,
        onDeleteConversationItemsChanged: (v) { setState(() => _deleteConversationItems = v); setSheetState((){}); _saveSettings(); },
        injectFewShot: _injectFewShot,
        onInjectFewShotChanged: (v) { setState(() => _injectFewShot = v); setSheetState((){}); _saveSettings(); },
        translationContext: _translationContext,
        onTranslationContextChanged: (v) { setState(() => _translationContext = v); setSheetState((){}); _saveSettings(); },
        translationTemp: _translationTemp,
        onTranslationTempChanged: (v) { setState(() => _translationTemp = v); setSheetState((){}); _saveSettings(); },
        classifyTemp: _classifyTemp,
        onClassifyTempChanged: (v) { setState(() => _classifyTemp = v); setSheetState((){}); _saveSettings(); },
        pronunciationTemp: _pronunciationTemp,
        onPronunciationTempChanged: (v) { setState(() => _pronunciationTemp = v); setSheetState((){}); _saveSettings(); },
        detectModel: _detectModel,
        backTranslateSource: _backTranslateSource,
        backTranslateTarget: _backTranslateTarget,
        onDetectModelChanged: (v) { setState(() => _detectModel = v); setSheetState((){}); _saveSettings(); },
        onBackTranslateSourceChanged: (v) { setState(() => _backTranslateSource = v); setSheetState((){}); _saveSettings(); },
        onBackTranslateTargetChanged: (v) { setState(() => _backTranslateTarget = v); setSheetState((){}); _saveSettings(); },
        showPronunciation: _showPronunciation,
        onShowPronunciationChanged: (v) { setState(() => _showPronunciation = v); setSheetState((){}); _saveSettings(); },
        promptTemplates: _promptTemplates,
        onPromptChanged: (key, value) async {
          await AppPrompts.saveTemplate(key, value);
          if (!mounted) return;
          setState(() => _promptTemplates = _updatedPromptTemplates(key, value));
          setSheetState(() {});
        },
        onPromptReset: (key) async {
          await AppPrompts.resetTemplate(key);
          if (!mounted) return;
          final templates = await AppPrompts.loadTemplates();
          if (!mounted) return;
          setState(() => _promptTemplates = templates);
          setSheetState(() {});
        },
        onResetApiKey: () { Navigator.pop(context); _resetApiKey(); },
      )),
    );
  }

  PromptTemplateSet _updatedPromptTemplates(String key, String value) {
    switch (key) {
      case AppPrompts.translationSystemKey:
        return _promptTemplates.copyWith(translationSystem: value);
      case AppPrompts.assistantSystemKey:
        return _promptTemplates.copyWith(assistantSystem: value);
      case AppPrompts.ttsInstructionsKey:
        return _promptTemplates.copyWith(ttsInstructions: value);
      case AppPrompts.realtimeTranslationKey:
        return _promptTemplates.copyWith(realtimeTranslation: value);
      case AppPrompts.postProcessKey:
        return _promptTemplates.copyWith(postProcess: value);
      default:
        return _promptTemplates;
    }
  }

  String _translationPrompt({required String sourceLang, required String targetLang}) {
    return AppPrompts.translationSystem(
      PromptLanguagePair(sourceLang: sourceLang, targetLang: targetLang),
      tone: _tone,
      template: _promptTemplates.translationSystem,
    );
  }

  String _assistantPrompt({required bool hasContext}) {
    return AppPrompts.assistantSystem(
      hasContext: hasContext,
      template: _promptTemplates.assistantSystem,
    );
  }

  String get _ttsPrompt => AppPrompts.ttsInstructions(
    template: _promptTemplates.ttsInstructions,
  );

  String _realtimePrompt() {
    final src = getLangByCode(_sourceLang).name;
    final tgt = getLangByCode(_targetLang).name;
    return AppPrompts.realtimeTranslation(
      PromptLanguagePair(sourceLang: src, targetLang: tgt),
      tone: _tone,
      template: _promptTemplates.realtimeTranslation,
      sourceLangCode: _sourceLang,
      targetLangCode: _targetLang,
    );
  }

  static const _latinLangs = {'en', 'de', 'fr', 'vi'};
  static const _micHints = {
    'ko': '이 버튼을 누르고 말씀하세요',
    'ja': 'このボタンを押して話してください',
    'zh': '请按此按钮后说话',
    'en': 'Press this button and speak',
    'de': 'Drücken Sie diese Taste und sprechen Sie',
    'fr': 'Appuyez sur ce bouton et parlez',
    'vi': 'Nhấn nút này và nói',
    'ru': 'Нажмите эту кнопку и говорите',
  };
  static const _realtimeHints = {
    'ko': '그대로 말씀하세요',
    'ja': 'そのまま話してください',
    'zh': '请直接说话',
    'en': 'Just speak',
    'de': 'Sprechen Sie einfach',
    'fr': 'Parlez simplement',
    'vi': 'Hãy nói',
    'ru': 'Просто говорите',
  };
  bool _isLatinLang(String code) => _latinLangs.contains(code);

  String? _detectLang(String text) {
    // Detect by unicode ranges. Returns null if undetectable (Latin etc.)
    final scores = <String, int>{};
    for (final ch in text.runes) {
      if ((ch >= 0xAC00 && ch <= 0xD7AF) || (ch >= 0x1100 && ch <= 0x11FF) || (ch >= 0x3130 && ch <= 0x318F)) {
        scores['ko'] = (scores['ko'] ?? 0) + 1;
      }
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) {
        scores['ja'] = (scores['ja'] ?? 0) + 1;
      }
      if (ch >= 0x4E00 && ch <= 0x9FFF) {
        scores['zh'] = (scores['zh'] ?? 0) + 1;
        scores['ja'] = (scores['ja'] ?? 0) + 1;
      }
      if ((ch >= 0x0400 && ch <= 0x04FF)) {
        scores['ru'] = (scores['ru'] ?? 0) + 1;
      }
    }

    if (scores.isEmpty) return null; // undetectable (Latin, etc.)

    final best = scores.entries.reduce((a, b) => a.value > b.value ? a : b);
    return best.key;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_myScrollController.hasClients) {
        _myScrollController.animateTo(
          _myScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      if (_mirrorScrollController.hasClients) {
        _mirrorScrollController.animateTo(
          _mirrorScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleTranslation(String text,
      {String? forceDirection}) async {
    if (text.isEmpty || _isProcessing) return;
    setState(() => _isProcessing = true);

    // forceDirection: 'source2target' or 'target2source'
    // Auto-detect based on text content
    final direction = forceDirection ?? 'source2target';

    String translated = '';
    String? backTranslation;

    try {
      final srcName = getLangByCode(_sourceLang).name;
      final tgtName = getLangByCode(_targetLang).name;
      // direction determines source→target or target→source
      // Build conversation context if enabled
      List<Map<String, String>>? ctx;
      if (_translationContext && _messages.isNotEmpty) {
        ctx = _messages.reversed.take(6).toList().reversed.map((m) {
          return {'role': 'user', 'content': '${m.original} → ${m.translated}'};
        }).toList();
      }

      final result = await _openai.translate(text,
        sourceLang: direction == 'source2target' ? srcName : tgtName,
        targetLang: direction == 'source2target' ? tgtName : srcName,
        model: _model,
        tone: _tone,
        temperature: _translationTemp,
        systemPrompt: _translationPrompt(
          sourceLang: direction == 'source2target' ? srcName : tgtName,
          targetLang: direction == 'source2target' ? tgtName : srcName,
        ),
        context: ctx,
      );
      translated = result['translated'] ?? '';
      backTranslation = result['back_translation'];

      final msgDir = direction == 'source2target' ? '${_sourceLang}2${_targetLang}' : '${_targetLang}2${_sourceLang}';
      final msg = ChatMessage(
        original: text,
        translated: translated,
        backTranslation: null,
        direction: msgDir,
      );

      if (mounted) {
        setState(() => _messages.add(msg));
        _scrollToBottom();
      }

      // Async back-translation for verification (per-language setting)
      final wantBT = direction == 'source2target' ? _backTranslateTarget : _backTranslateSource;
      if (translated.isNotEmpty && mounted && wantBT) {
        final btSrcName = direction == 'source2target' ? tgtName : srcName;
        final btTgtName = direction == 'source2target' ? srcName : tgtName;
        _openai.translate(
          translated,
          sourceLang: btSrcName,
          targetLang: btTgtName,
          model: _model,
          systemPrompt: _translationPrompt(sourceLang: btSrcName, targetLang: btTgtName),
        ).then((r) async {
          if (!mounted) return;
          final bt = r['translated'] ?? '';
          // Pronunciation for non-KO/EN
          // Pronunciation: pronounce whichever text is foreign (not KO/EN)
          String? pron;
          if (_showPronunciation) {
            final outputLangCode = direction == 'source2target' ? _targetLang : _sourceLang;
            String? textToPronounce;
            if (outputLangCode != 'ko' && outputLangCode != 'en') {
              textToPronounce = translated; // output is foreign
            } else if (bt.isNotEmpty) {
              final btLangCode = direction == 'source2target' ? _sourceLang : _targetLang;
              if (btLangCode != 'ko' && btLangCode != 'en') {
                textToPronounce = bt; // back-translation is foreign
              }
            }
            if (textToPronounce != null) {
              try {
                final pronResult = await _openai.askAssistant(
                  'Write how this text sounds using Korean characters (한글로 발음 표기). Example: こんにちは → 곤니치와. Reply with ONLY the 한글 pronunciation: $textToPronounce',
                  model: 'gpt-5.4-nano',
                  temperature: _pronunciationTemp,
                );
                pron = pronResult.trim();
              } catch (_) {}
            }
          }
          if (!mounted) return;
          if (bt.isNotEmpty || pron != null) {
            setState(() {
              final idx = _messages.indexOf(msg);
              if (idx >= 0) {
                _messages[idx] = ChatMessage(
                  original: msg.original,
                  translated: msg.translated,
                  backTranslation: bt.isNotEmpty ? bt : null,
                  pronunciation: pron,
                  direction: msg.direction,
                );
              }
            });
            _scrollToBottom();
          }
        }).catchError((_) {});
      }
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }

    // TTS after processing flag released
    if (translated.isNotEmpty) {
      final ttsLangCode = direction == 'source2target' ? _targetLang : _sourceLang;
      final shouldPlay = direction == 'source2target' ? _ttsTargetEnabled : _ttsSourceEnabled;
      final voice = direction == 'source2target' ? _voiceTarget : _voiceSource;
      if (shouldPlay) {
        _playOpenAITTS(translated, ttsLangCode, voice);
      }
    }
  }

  Future<void> _playOpenAITTS(String text, String lang, String voice) async {
    try {
      final audioBytes = await _openai.tts(
        text,
        lang,
        voice: voice,
        instructions: _ttsPrompt,
      );
      await _audioPlayer.play(BytesSource(audioBytes));
    } catch (e) {
      // Fallback to browser TTS
      final g = (lang == _targetLang ? _voiceTarget : _voiceSource) == 'nova' || (lang == _targetLang ? _voiceTarget : _voiceSource) == 'coral' ? 'female' : 'male';
      await _speech.speak(text, lang, gender: g);
    }
  }

  Future<void> _stopAll() async {
    if (_isListening) await _stopListening();
    if (_isMirrorListening) await _stopMirrorListening();
    if (_isRecording) await _stopOpenAIRecording();
  }

  Future<void> _startListening() async {
    if (_isListening || _isProcessing) return;
    await _stopAll();

    // Warmup TTS on first user interaction (browser requires gesture)
    await _speech.warmupTts();
    await _speech.initialize();
    setState(() {
      _isListening = true;
      _interimText = '';
    });

    final sttLocale = getLangByCode(_micLang).sttLocale;
    final direction = _micLang == _sourceLang ? 'source2target' : 'target2source';

    await _speech.startListening(
      locale: sttLocale,
      pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
      onResult: (text, isFinal) {
        if (!mounted) return;
        setState(() => _interimText = text);
        if (isFinal && text.isNotEmpty) {
          _stopListening();
          if (_aiMode) {
            _handleAIQuestion(text);
          } else {
            _handleTranslation(text, forceDirection: direction);
          }
        }
      },
      onDone: () { if (mounted) setState(() => _isListening = false); },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stopListening();
    setState(() {
      _isListening = false;
      _interimText = '';
    });
  }

  Future<void> _startMirrorListening() async {
    if (_isMirrorListening || _isProcessing) return;
    await _stopAll();

    await _speech.warmupTts();

    if (_mode == 'openai') {
      // OpenAI STT: record + Whisper
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _showError('마이크 권한이 필요합니다');
        return;
      }
      setState(() {
        _isMirrorListening = true;
        _mirrorInterimText = '録音中... (ボタンを押して停止)';
      });
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
        path: kIsWeb ? '' : '${(await getTemporaryDirectory()).path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );

      // Silence detection for mirror mic
      final mirrorPause = _aiMode ? _aiPauseSeconds : _pauseSeconds;
      if (mirrorPause < 30) {
        _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
          if (amp.current < _noiseThreshold) {
            final timeout = _aiMode ? _aiPauseSeconds : _pauseSeconds;
            _silenceTimer ??= Timer(Duration(seconds: timeout), () {
              if (_isMirrorListening) _stopMirrorListening();
            });
          } else {
            _silenceTimer?.cancel();
            _silenceTimer = null;
          }
        });
      }
    } else {
      // Browser STT
      await _speech.initialize();
      setState(() {
        _isMirrorListening = true;
        _mirrorInterimText = '';
      });
      await _speech.startListening(
        locale: getLangByCode(_targetLang).sttLocale,
        pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
        onResult: (text, isFinal) {
          setState(() => _mirrorInterimText = text);
          if (isFinal && text.isNotEmpty) {
            _stopMirrorListening();
            _handleTranslation(text, forceDirection: 'target2source');
          }
        },
        onDone: () => setState(() => _isMirrorListening = false),
      );
    }
  }

  Future<void> _stopMirrorListening() async {
    if (_mode == 'openai' && _isMirrorListening) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      _ampSub?.cancel();
      _ampSub = null;
      final path = await _recorder.stop();
      setState(() {
        _isMirrorListening = false;
        _mirrorInterimText = '音声認識中...';
      });
      if (path != null) {
        try {
          final bytes = await _readFileBytes(path);
          if (bytes.isNotEmpty && bytes.length >= 1000) {
            final text = await _openai.stt(bytes, _targetLang);
            setState(() => _mirrorInterimText = '');
            if (text.isNotEmpty) {
              _handleTranslation(text, forceDirection: 'target2source');
            }
          } else {
            setState(() => _mirrorInterimText = '');
          }
        } catch (e) {
          setState(() => _mirrorInterimText = '');
          _showError(e.toString());
        }
      } else {
        setState(() => _mirrorInterimText = '');
      }
    } else {
      await _speech.stopListening();
      setState(() {
        _isMirrorListening = false;
        _mirrorInterimText = '';
      });
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isProcessing) return;
    await _speech.warmupTts();
    _textController.clear();
    if (_aiMode) {
      _handleAIQuestion(text);
    } else if (_mode == 'realtime' && _realtimeActive) {
      _realtime?.sendText(text);
    } else {
      final detected = _detectLang(text);
      String direction;
      if (detected != null && detected == _sourceLang) {
        direction = 'source2target';
      } else if (detected != null && detected == _targetLang) {
        direction = 'target2source';
      } else {
        direction = _textDirection;
      }
      _handleTranslation(text, forceDirection: direction);
    }
  }

  Future<void> _resetApiKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API 키 초기화'),
        content: const Text('API 키를 초기화하시겠습니까?\n앱이 처음 화면으로 돌아갑니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await clearApiKey();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ApiKeyScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _handleAIQuestion(String question) async {
    if (question.isEmpty || _isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      // Build context from recent messages
      final ctx = _messages.reversed.take(8).toList().reversed.map((m) {
        if (m.isAI) return <String, String>{'content': 'Q: ${m.original}\nA: ${m.translated}'};
        return <String, String>{'content': '${m.direction}: ${m.original} → ${m.translated}'};
      }).toList();

      final answer = await _openai.askAssistant(
        question,
        conversationContext: ctx,
        model: _aiModel,
        systemPrompt: _assistantPrompt(hasContext: ctx.isNotEmpty),
      );

      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            original: question,
            translated: answer,
            direction: 'ai',
            isAI: true,
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _clearChat() {
    if (_realtimeActive && _realtime != null) {
      _realtime!.clearState();
    }
    setState(() {
      _messages.clear();
      _interimText = '';
      _mirrorInterimText = '';
    });
  }

  // ===== OpenAI STT (record + Whisper) =====
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _silenceTimer;

  Future<void> _startOpenAIRecording({String? forceDirection}) async {
    if (_isRecording || _isProcessing) return;
    await _stopAll();

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showError('마이크 권한이 필요합니다');
      return;
    }

    setState(() {
      _isRecording = true;
      _interimText = '녹음 중...';
    });

    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
      path: kIsWeb ? '' : '${(await getTemporaryDirectory()).path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    // Silence detection
    final effectivePause = _aiMode ? _aiPauseSeconds : _pauseSeconds;
    if (effectivePause < 30) { // 30 = OFF
      _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
        debugPrint('[AMP] ${amp.current.toStringAsFixed(1)} dB (threshold: $_noiseThreshold)');
        if (amp.current < _noiseThreshold) {
          _silenceTimer ??= Timer(Duration(seconds: effectivePause), () {
            if (_isRecording) _stopOpenAIRecording(forceDirection: forceDirection);
          });
        } else {
          // Sound detected — reset timer
          _silenceTimer?.cancel();
          _silenceTimer = null;
        }
      });
    }
  }

  Future<void> _stopOpenAIRecording({String? forceDirection}) async {
    if (!_isRecording) return;

    _silenceTimer?.cancel();
    _silenceTimer = null;
    _ampSub?.cancel();
    _ampSub = null;

    final path = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _interimText = '음성 인식 중...';
    });

    if (path == null) {
      setState(() => _interimText = '');
      return;
    }

    try {
      // Read recorded file as bytes
      final bytes = await _readFileBytes(path);
      // Web uses blob URLs (auto garbage collected), no cleanup needed

      if (bytes.isEmpty || bytes.length < 1000) {
        setState(() => _interimText = '');
        return;
      }

      final text = await _openai.stt(bytes, forceDirection == 'ja2ko' ? 'ja' : _micLang);
      setState(() => _interimText = '');

      if (text.isNotEmpty) {
        if (_aiMode) {
          _handleAIQuestion(text);
        } else {
          _handleTranslation(text, forceDirection: forceDirection);
        }
      }
    } catch (e) {
      setState(() => _interimText = '');
      _showError(e.toString());
    }
  }

  Future<Uint8List> _readFileBytes(String path) async {
    try {
      if (kIsWeb) {
        // Web: path is a blob URL
        final response = await http_client.get(Uri.parse(path));
        return response.bodyBytes;
      } else {
        // Android/iOS: path is a file path
        final file = java_io.File(path);
        return await file.readAsBytes();
      }
    } catch (_) {
      return Uint8List(0);
    }
  }

  void _updateRealtimeAudioMute() {
    if (_realtimeActive && _realtime != null) {
      // Realtime UI shows single toggle mapped to _ttsTargetEnabled
      _realtime!.muteAudio(!_ttsTargetEnabled);
    }
  }

  // ===== Realtime =====
  Future<void> _startRealtime() async {
    if (_realtimeActive) return;
    setState(() => _interimText = 'Realtime 연결 중...');

    _realtime = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _realtimeVoice,
      sourceLangCode: _sourceLang,
      targetLangCode: _targetLang,
      vadThreshold: _vadThreshold,
      tone: _tone,
      instructions: _realtimePrompt(),
      deleteConversationItems: _deleteConversationItems,
      injectFewShot: _injectFewShot,
      onEvent: _handleRealtimeEvent,
    );

    try {
      await _realtime!.start();
      setState(() {
        _realtimeActive = true;
        _interimText = 'Realtime 활성 — 말하세요';
      });
      _updateRealtimeAudioMute();
      // If AI mode is active, enter hold immediately
      if (_aiMode) {
        _realtime!.enterAIHold();
      }
    } catch (e) {
      await _realtime?.stop();
      _showError(e.toString());
      if (mounted) {
        setState(() {
          _realtimeActive = false;
          _interimText = '';
        });
      }
    }
  }

  void _stopRealtime() {
    _realtime?.stop();
    setState(() {
      _realtimeActive = false;
      _interimText = '';
      _mirrorInterimText = '';
    });
  }

  void _handleRealtimeEvent(String type, Map<String, dynamic> event) {
    if (!mounted || !_realtimeActive || _realtime == null) return;
    switch (type) {
      case 'input_audio_buffer.speech_started':
        setState(() {
          _interimText = '듣고 있습니다...';
          _mirrorInterimText = '聞いています...';
        });
        break;

      case 'input_audio_buffer.speech_stopped':
        setState(() {
          _interimText = '번역 중...';
          _mirrorInterimText = '翻訳中...';
        });
        break;


      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
        final rid = event['response_id'] as String?;
        if (rid != null && _realtime!.turns.containsKey(rid)) {
          setState(() {
            _interimText = _realtime!.turns[rid]!.output;
            _mirrorInterimText = _realtime!.turns[rid]!.output;
          });
        }
        break;

      case 'response.done':
        final rid = event['response']?['id'] as String?;
        final turn = rid != null ? _realtime!.turns[rid] : null;
        // Filter out non-translation responses (model outputting meta-text)
        final outputText = turn?.output.trim() ?? '';
        final lower = outputText.toLowerCase();
        final isJunk = outputText.isEmpty ||
            lower.contains('output nothing') ||
            lower.contains('no output') ||
            lower.contains('silence') ||
            lower.contains('silent') ||
            lower.contains('say anything') ||
            lower.contains('completely silent') ||
            lower.contains('침묵') ||
            lower.contains('何も出力') ||
            outputText.length < 2 ||
            (outputText.startsWith('(') && outputText.endsWith(')'));
        // Skip if duplicate of last message (caused by noise/cough triggering repeat)
        final isDuplicate = _messages.isNotEmpty &&
            !_messages.last.isAI &&
            _messages.last.translated == outputText;
        if (turn != null && !isJunk && !isDuplicate) {
          // Try unicode detection first, fallback to nano model
          final outputLang = _detectLang(turn.output);
          final direction = (outputLang != null)
              ? (outputLang != _sourceLang
                  ? '${_sourceLang}2${_targetLang}'
                  : '${_targetLang}2${_sourceLang}')
              : '${_sourceLang}2${_targetLang}'; // default for Latin pairs

          final msg = ChatMessage(
            original: turn.output, // back-translation will serve as "what was said"
            translated: turn.output,
            direction: direction,
            turnId: rid,
          );
          setState(() {
            _messages.add(msg);
            _interimText = '';
            _mirrorInterimText = '';
          });
          _scrollToBottom();

          // Async: detect language via nano + back-translate
          final msgIndex = _messages.length - 1;
          _asyncRealtimePostProcess(msgIndex, turn.output, outputLang);

          // Delay turn cleanup to allow late transcript to arrive
          if (rid != null) {
            Future.delayed(const Duration(seconds: 10), () {
              _realtime?.turns.remove(rid);
            });
          }
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? 'Unknown error';
        // Show error in UI for debugging (benign errors already filtered in service)
        if (!errMsg.toString().contains('no active response')) {
          _showError('Realtime: $errMsg');
        }
        break;

      case 'connection_lost':
        _stopRealtime();
        _showError('Realtime 연결이 끊어졌습니다');
        break;

      case 'remote_stream':
        // Re-apply mute setting now that remote stream is available
        _updateRealtimeAudioMute();
        break;
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  /// Async post-process for Realtime: detect language (nano) + back-translate
  Future<void> _asyncRealtimePostProcess(int msgIndex, String output, String? detectedLang) async {
    if (!mounted || msgIndex < 0 || msgIndex >= _messages.length) return;

    String direction = _messages[msgIndex].direction;
    String? backTranslation;

    // If unicode couldn't detect language, ask nano model as classifier
    if (detectedLang == null && output.isNotEmpty) {
      try {
        final srcName = getLangByCode(_sourceLang).name;
        final tgtName = getLangByCode(_targetLang).name;
        final result = await _openai.askAssistant(
          'Which language is this text? Reply with ONLY one word: $srcName or $tgtName\n\nText: $output',
          model: _detectModel,
          systemPrompt: 'You are a language classifier. The text is either $srcName or $tgtName. Reply with exactly one of these two names. No explanation.',
          temperature: _classifyTemp,
        );
        final answer = result.trim().toLowerCase();
        if (answer.contains(tgtName.toLowerCase())) {
          detectedLang = _targetLang;
          direction = '${_sourceLang}2${_targetLang}';
        } else if (answer.contains(srcName.toLowerCase())) {
          detectedLang = _sourceLang;
          direction = '${_targetLang}2${_sourceLang}';
        }
      } catch (_) {}
    }

    // Back-translate (respecting per-language settings)
    if (detectedLang != null && output.isNotEmpty && mounted) {
      final isTarget = detectedLang != _sourceLang;
      final wantBT = isTarget ? _backTranslateTarget : _backTranslateSource;
      if (wantBT) {
        try {
          final fromName = getLangByCode(isTarget ? _targetLang : _sourceLang).name;
          final toName = getLangByCode(isTarget ? _sourceLang : _targetLang).name;
          final r = await _openai.translate(
            output,
            sourceLang: fromName,
            targetLang: toName,
            model: _detectModel,
            systemPrompt: _translationPrompt(sourceLang: fromName, targetLang: toName),
          );
          backTranslation = r['translated'];
        } catch (_) {}
      }
    }

    // Pronunciation: Korean reading of the FOREIGN language text
    // If output is foreign → pronounce output
    // If output is Korean → pronounce back-translation (which is foreign)
    String? pronunciation;
    if (_showPronunciation && detectedLang != null && mounted) {
      final outputLangCode = detectedLang != _sourceLang ? _targetLang : _sourceLang;
      String? textToPronounce;
      if (outputLangCode != 'ko' && outputLangCode != 'en') {
        textToPronounce = output; // output is foreign
      } else if (backTranslation != null && backTranslation!.isNotEmpty) {
        // output is KO/EN, but back-translation is in the foreign language
        final btLangCode = outputLangCode == _sourceLang ? _targetLang : _sourceLang;
        if (btLangCode != 'ko' && btLangCode != 'en') {
          textToPronounce = backTranslation;
        }
      }
      if (textToPronounce != null) {
        try {
          final result = await _openai.askAssistant(
            'Write how this text sounds using Korean characters (한글로 발음 표기). Example: こんにちは → 곤니치와. Reply with ONLY the 한글 pronunciation: $textToPronounce',
            model: _detectModel,
            temperature: 0.3,
          );
          final p = result.trim();
          if (p.isNotEmpty) pronunciation = p;
        } catch (_) {}
      }
    }

    if (!mounted || msgIndex >= _messages.length) return;
    final cur = _messages[msgIndex];
    debugPrint('[RT] postProcess: idx=$msgIndex dir=$direction bt=$backTranslation pron=$pronunciation');
    if (direction != cur.direction || backTranslation != null || pronunciation != null) {
      setState(() {
        _messages[msgIndex] = ChatMessage(
          original: cur.original,
          translated: cur.translated,
          backTranslation: backTranslation ?? cur.backTranslation,
          pronunciation: pronunciation ?? cur.pronunciation,
          direction: direction,
          turnId: cur.turnId,
        );
      });
      _scrollToBottom();
    }
  }

  Future<void> _replayMessage(ChatMessage msg) async {
    if (msg.isAI) return; // AI messages don't have audio
    final parts = msg.direction.split('2');
    final lang = parts.length > 1 ? parts[1] : _targetLang;
    final voice = lang == _targetLang ? _voiceTarget : _voiceSource;
    await _playOpenAITTS(msg.translated, lang, voice);
  }

  Widget _buildChatList(ScrollController controller) {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          '${getLangByCode(_sourceLang).name} 또는 ${getLangByCode(_targetLang).name}로 입력하세요',
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return ChatBubble(
          message: msg,
          fontSize: _fontSize,
          sourceLang: _sourceLang,
          onReplay: () => _replayMessage(msg),
        );
      },
    );
  }

  // Settings now in BottomSheet via _openSettings()

  Widget _labeledSetting(String label, Widget child) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        const SizedBox(width: 2),
        child,
      ],
    );
  }

  Widget _buildToggle(String label, bool value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? Colors.green : Colors.grey.shade300,
              ),
            ),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<T>(
        value: value,
        underline: const SizedBox(),
        isDense: true,
        style: const TextStyle(fontSize: 11, color: Colors.black87),
        items: items.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildInputRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Clear
          _buildCircleButton(
            icon: Icons.delete_outline,
            size: 28,
            color: Colors.grey,
            onTap: _clearChat,
            outlined: true,
          ),
          const SizedBox(width: 4),
          // Direction toggle: source→target / target→source (hidden in Realtime)
          if (!_aiMode && !(_mode == 'realtime' && _realtimeActive))
            GestureDetector(
              onTap: () => setState(() {
                _textDirection = _textDirection == 'source2target' ? 'target2source' : 'source2target';
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                decoration: BoxDecoration(
                  color: _textDirection == 'source2target'
                      ? const Color(0xFF4A90D9)
                      : const Color(0xFFE85D75),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _textDirection == 'source2target'
                      ? '${_sourceLang.toUpperCase()}→${_targetLang.toUpperCase()}'
                      : '${_targetLang.toUpperCase()}→${_sourceLang.toUpperCase()}',
                  style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),
          // AI toggle
          GestureDetector(
            onTap: () async {
              // Stop any in-progress recording/listening before toggling
              if (_isListening || _isRecording) await _stopAll();
              setState(() => _aiMode = !_aiMode);
              // Realtime: enter/exit AI hold
              if (_realtimeActive && _realtime != null) {
                if (_aiMode) {
                  _realtime!.enterAIHold();
                } else {
                  _realtime!.exitAIHold();
                }
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
              decoration: BoxDecoration(
                color: _aiMode ? const Color(0xFF8B5CF6) : Colors.grey.shade400,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.smart_toy, size: 10, color: Colors.white),
                  const SizedBox(width: 2),
                  Text('AI', style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Text input
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: '${getLangByCode(_sourceLang).localName} 또는 ${getLangByCode(_targetLang).localName} 입력...',
                  hintStyle: const TextStyle(fontSize: 13),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                style: const TextStyle(fontSize: 14),
                onSubmitted: (_) => _sendText(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Send
          _buildCircleButton(
            icon: Icons.send,
            size: 36,
            color: const Color(0xFF4A90D9),
            onTap: _sendText,
          ),
          const SizedBox(width: 4),
          if (_mode == 'realtime' && !_aiMode) ...[
            // Realtime: single mic button (translation mode)
            _buildCircleButton(
              icon: Icons.mic,
              size: 36,
              color: _realtimeActive ? Colors.red : const Color(0xFF4A90D9),
              onTap: () => _realtimeActive ? _stopRealtime() : _startRealtime(),
            ),
          ] else if (_mode == 'realtime' && _aiMode) ...[
            // Realtime + AI mode: use OpenAI STT for AI question
            _buildLangMicButton(
              langCode: 'AI',
              color: const Color(0xFF8B5CF6),
              isActive: _isRecording,
              onTap: () {
                if (_isRecording) {
                  _stopOpenAIRecording();
                } else {
                  setState(() => _micLang = _sourceLang);
                  _startOpenAIRecording();
                }
              },
            ),
            const SizedBox(width: 3),
            // Still show realtime toggle
            _buildCircleButton(
              icon: Icons.translate,
              size: 28,
              color: _realtimeActive ? Colors.green : Colors.grey,
              onTap: () => _realtimeActive ? _stopRealtime() : _startRealtime(),
              outlined: !_realtimeActive,
            ),
          ] else ...[
            // Source language mic (purple when AI mode)
            _buildLangMicButton(
              langCode: _aiMode ? 'AI' : _sourceLang,
              color: _aiMode ? const Color(0xFF8B5CF6) : const Color(0xFF4A90D9),
              isActive: (_isListening || _isRecording) && _micLang == _sourceLang,
              onTap: () => _handleMicTap(_sourceLang, 'source2target'),
            ),
            const SizedBox(width: 3),
            // Target language mic
            _buildLangMicButton(
              langCode: _targetLang,
              color: const Color(0xFFE85D75),
              isActive: (_isListening || _isRecording) && _micLang == _targetLang,
              onTap: () => _handleMicTap(_targetLang, 'target2source'),
            ),
          ],
          const SizedBox(width: 4),
          // Settings toggle
          _buildCircleButton(
            icon: Icons.settings,
            size: 28,
            color: Colors.grey,
            onTap: _openSettings,
            outlined: true,
          ),
        ],
      ),
    );
  }

  Widget _buildLangMicButton({
    required String langCode,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: _PulsatingMic(
        isActive: isActive,
        color: color,
        langCode: langCode,
      ),
    );
  }

  void _handleMicTap(String lang, String direction) {
    // If already listening/recording, stop
    if ((_isListening || _isRecording) && _micLang == lang) {
      if (_isRecording) {
        _stopOpenAIRecording(forceDirection: direction);
      } else {
        _stopListening();
      }
      return;
    }

    setState(() => _micLang = lang);

    // All modes use OpenAI STT (record + Whisper)
    _startOpenAIRecording(forceDirection: _aiMode ? null : direction);
  }

  Widget _buildCircleButton({
    required IconData icon,
    required double size,
    required Color color,
    required VoidCallback onTap,
    bool outlined = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: outlined ? Colors.transparent : color,
          border: outlined ? Border.all(color: color) : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: size * 0.5,
          color: outlined ? color : Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // === Mirror half (only in face-to-face mode) ===
            if (_displayMode == 'face')
            Expanded(
              child: Transform.rotate(
                angle: 3.14159,
                child: Column(
                  children: [
                    // Label
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                      ),
                      child: Text(
                        '${getLangByCode(_targetLang).name}⇄${getLangByCode(_sourceLang).name}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Chat
                    Expanded(child: _buildChatList(_mirrorScrollController)),
                    // Mirror mic
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.grey.shade300)),
                      ),
                      child: Column(
                        children: [
                          if (_mirrorInterimText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                _mirrorInterimText,
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (_mode == 'realtime')
                            Text(
                              _realtimeHints[_targetLang] ?? 'Just speak',
                              style: TextStyle(fontSize: 10, color: Colors.grey),
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _buildCircleButton(
                                  icon: Icons.mic,
                                  size: 36,
                                  color: _isMirrorListening
                                      ? Colors.red
                                      : const Color(0xFFE85D75),
                                  onTap: _isMirrorListening
                                      ? _stopMirrorListening
                                      : _startMirrorListening,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _micHints[_targetLang] ?? 'Press and speak',
                                  style: TextStyle(fontSize: 10, color: Colors.grey),
                                ),
                              ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // === Divider (face-to-face only) ===
            if (_displayMode == 'face')
            Container(
              height: 3,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF4A90D9), Color(0xFFE85D75)],
                ),
              ),
            ),
            // === My half ===
            Expanded(
              child: Column(
                children: [
                  // Label
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                    ),
                    child: Text(
                      '${getLangByCode(_sourceLang).name}⇄${getLangByCode(_targetLang).name}',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  // Chat
                  Expanded(child: _buildChatList(_myScrollController)),
                  // Interim text
                  if (_interimText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        _interimText,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // Processing indicator
                  if (_isProcessing)
                    const Padding(
                      padding: EdgeInsets.all(4),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  // Settings
                  // Settings via BottomSheet (gear icon in input row)
                  // Input
                  _buildInputRow(),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsatingMic extends StatefulWidget {
  final bool isActive;
  final Color color;
  final String langCode;

  const _PulsatingMic({
    required this.isActive,
    required this.color,
    required this.langCode,
  });

  @override
  State<_PulsatingMic> createState() => _PulsatingMicState();
}

class _PulsatingMicState extends State<_PulsatingMic> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(_PulsatingMic old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: widget.isActive ? _scaleAnim.value : 1.0,
          child: Container(
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: widget.isActive ? Colors.red : widget.color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: widget.isActive ? [
                BoxShadow(
                  color: Colors.red.withOpacity(0.4 * (1.25 - _scaleAnim.value)),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ] : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic, size: 16, color: Colors.white),
                Text(
                  widget.langCode.toUpperCase(),
                  style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
