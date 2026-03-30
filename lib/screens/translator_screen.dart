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
  String _mode = 'browser'; // browser, openai, realtime
  String _model = 'gpt-5.4-nano';
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
  String _realtimeModel = 'gpt-realtime-mini';

  @override
  void initState() {
    super.initState();
    _openai = OpenAIService(widget.apiKey);
    _speech.initialize();
    _loadSettings();
  }

  @override
  void dispose() {
    _realtime?.stop();
    _recorder.dispose();
    _textController.dispose();
    _myScrollController.dispose();
    _mirrorScrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sourceLang = prefs.getString('sourceLang') ?? 'ko';
      _targetLang = prefs.getString('targetLang') ?? 'ja';
      _displayMode = prefs.getString('displayMode') ?? 'face';
      _ttsSourceEnabled = prefs.getBool('ttsSource') ?? false;
      _ttsTargetEnabled = prefs.getBool('ttsTarget') ?? false;
      _voiceSource = prefs.getString('voiceSource') ?? 'nova';
      _voiceTarget = prefs.getString('voiceTarget') ?? 'onyx';
      _fontSize = prefs.getDouble('fontSize') ?? 16;
      _mode = prefs.getString('mode') ?? 'browser';
      _model = prefs.getString('model') ?? 'gpt-5.4-nano';
      _ttsSpeed = prefs.getDouble('ttsSpeed') ?? 1.0;
      _pauseSeconds = prefs.getInt('pauseSeconds') ?? 3;
      _realtimeModel = prefs.getString('realtimeModel') ?? 'gpt-realtime-mini';
      _noiseThreshold = prefs.getDouble('noiseThreshold') ?? -30;
      _vadThreshold = prefs.getDouble('vadThreshold') ?? 0.9;
      _micLang = _sourceLang;
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
    prefs.setDouble('ttsSpeed', _ttsSpeed);
    prefs.setInt('pauseSeconds', _pauseSeconds);
    prefs.setString('realtimeModel', _realtimeModel);
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
        pauseSeconds: _pauseSeconds,
        noiseThreshold: _noiseThreshold,
        vadThreshold: _vadThreshold,
        onModeChanged: (v) { setState(() => _mode = v); setSheetState((){}); _saveSettings(); },
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
        onResetApiKey: () { Navigator.pop(context); _resetApiKey(); },
      )),
    );
  }

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
      final result = await _openai.translate(text,
        sourceLang: direction == 'source2target' ? srcName : tgtName,
        targetLang: direction == 'source2target' ? tgtName : srcName,
        model: _model,
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

      // Async back-translation for verification
      if (translated.isNotEmpty && mounted) {
        final btSrcName = direction == 'source2target' ? tgtName : srcName;
        final btTgtName = direction == 'source2target' ? srcName : tgtName;
        _openai.translate(translated, sourceLang: btSrcName, targetLang: btTgtName, model: _model).then((r) {
          if (!mounted) return;
          final bt = r['translated'] ?? '';
          if (bt.isNotEmpty) {
            setState(() {
              final idx = _messages.indexOf(msg);
              if (idx >= 0) {
                _messages[idx] = ChatMessage(
                  original: msg.original,
                  translated: msg.translated,
                  backTranslation: bt,
                  direction: msg.direction,
                );
              }
            });
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
        if (_mode == 'browser') {
          final gender = (voice == 'nova' || voice == 'coral') ? 'female' : 'male';
          _speech.speak(translated, ttsLangCode, rate: _ttsSpeed, gender: gender);
        } else {
          _playOpenAITTS(translated, ttsLangCode, voice);
        }
      }
    }
  }

  Future<void> _playOpenAITTS(String text, String lang, String voice) async {
    try {
      final audioBytes = await _openai.tts(text, lang, voice: voice);
      await _audioPlayer.play(BytesSource(audioBytes));
    } catch (e) {
      // Fallback to browser TTS
      final g = (lang == 'ja' ? _voiceTarget : _voiceSource) == 'nova' || (lang == 'ja' ? _voiceTarget : _voiceSource) == 'coral' ? 'female' : 'male';
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
      pauseSeconds: _pauseSeconds,
      onResult: (text, isFinal) {
        if (!mounted) return;
        setState(() => _interimText = text);
        if (isFinal && text.isNotEmpty) {
          _stopListening();
          _handleTranslation(text, forceDirection: direction);
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
      if (_pauseSeconds < 30) {
        _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
          if (amp.current < _noiseThreshold) {
            _silenceTimer ??= Timer(Duration(seconds: _pauseSeconds), () {
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
        locale: 'ja_JP',
        pauseSeconds: _pauseSeconds,
        onResult: (text, isFinal) {
          setState(() => _mirrorInterimText = text);
          if (isFinal && text.isNotEmpty) {
            _stopMirrorListening();
            _handleTranslation(text, forceDirection: 'ja2ko');
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
            final text = await _openai.stt(bytes, 'ja');
            setState(() => _mirrorInterimText = '');
            if (text.isNotEmpty) {
              _handleTranslation(text, forceDirection: 'ja2ko');
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
    if (_textDirection == 'ai') {
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

      final answer = await _openai.askAssistant(question, conversationContext: ctx, model: _model);

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
    if (_pauseSeconds < 30) { // 30 = OFF
      _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
        if (amp.current < _noiseThreshold) {
          // Silence — start timer if not started
          _silenceTimer ??= Timer(Duration(seconds: _pauseSeconds), () {
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
        _handleTranslation(text, forceDirection: forceDirection);
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
      final shouldMute = !_ttsTargetEnabled && !_ttsSourceEnabled;
      _realtime!.muteAudio(shouldMute);
    }
  }

  // ===== Realtime =====
  String? _detectLangSimple(String text) {
    final scores = <String, int>{};
    for (final ch in text.runes) {
      if ((ch >= 0xAC00 && ch <= 0xD7AF)) scores['ko'] = (scores['ko'] ?? 0) + 1;
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) scores['ja'] = (scores['ja'] ?? 0) + 1;
      if (ch >= 0x4E00 && ch <= 0x9FFF) scores['zh'] = (scores['zh'] ?? 0) + 1;
      if (ch >= 0x0400 && ch <= 0x04FF) scores['ru'] = (scores['ru'] ?? 0) + 1;
    }
    if (scores.isEmpty) return null;
    return scores.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  Future<void> _startRealtime() async {
    if (_realtimeActive) return;
    setState(() => _interimText = 'Realtime 연결 중...');

    _realtime = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _voiceTarget == 'onyx' ? 'ash' : 'coral',
      onEvent: _handleRealtimeEvent,
    );

    try {
      await _realtime!.start();
      setState(() {
        _realtimeActive = true;
        _interimText = 'Realtime 활성 — 말하세요';
      });
      _updateRealtimeAudioMute();
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
        if (turn != null && turn.output.isNotEmpty) {
          // Realtime: output = AI's translated speech transcript
          // Detect output language to determine direction
          final outputLang = _detectLangSimple(turn.output);
          final didTranslate = outputLang != null && outputLang != _sourceLang;
          final direction = didTranslate
              ? '${_sourceLang}2${_targetLang}'
              : '${_targetLang}2${_sourceLang}';

          // For display: translated text is the output, original needs to be reconstructed
          // turn.input = transcript of what was said (in source lang)
          // turn.output = AI's translation (in target lang)
          final msg = ChatMessage(
            original: turn.input.isNotEmpty ? turn.input : turn.output,
            translated: turn.output,
            direction: direction,
          );
          setState(() {
            _messages.add(msg);
            _interimText = '';
            _mirrorInterimText = '';
          });
          _scrollToBottom();

          // Always fetch reverse translation for the "original" line
          // This gives us the input in the source language for display
          {
            // Reverse: translate output back to figure out what was originally said
            final fromName = getLangByCode(didTranslate ? _targetLang : _sourceLang).name;
            final toName = getLangByCode(didTranslate ? _sourceLang : _targetLang).name;
            _openai.translate(turn.output, sourceLang: fromName, targetLang: toName, model: _model).then((r) {
              if (!mounted) return;
              if (r['translated']?.isNotEmpty ?? false) {
                setState(() {
                  final idx = _messages.indexOf(msg);
                  if (idx >= 0) {
                    _messages[idx] = ChatMessage(
                      original: turn.input.isNotEmpty ? turn.input : r['translated']!,
                      translated: msg.translated,
                      backTranslation: r['translated'],
                      direction: msg.direction,
                    );
                  }
                });
              }
            }).catchError((_) {});
          }

          // Clean turn
          if (rid != null) _realtime!.turns.remove(rid);
        }
        break;

      case 'connection_lost':
        _stopRealtime();
        _showError('Realtime 연결이 끊어졌습니다');
        break;

      case 'remote_stream':
        // Audio playback handled by RealtimeService's RTCVideoRenderer
        break;
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  Future<void> _replayMessage(ChatMessage msg) async {
    final lang = msg.direction == 'ko2ja' ? 'ja' : 'ko';
    if (_mode == 'browser') {
      final gr = (lang == 'ja' ? _voiceTarget : _voiceSource) == 'nova' || (lang == 'ja' ? _voiceTarget : _voiceSource) == 'coral' ? 'female' : 'male';
      await _speech.speak(msg.translated, lang, gender: gr);
    } else {
      await _playOpenAITTS(
          msg.translated, lang, lang == 'ja' ? _voiceTarget : _voiceSource);
    }
  }

  Widget _buildChatList(ScrollController controller) {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          '한국어 또는 일본어로 입력하세요',
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
          // Direction toggle: source→target / target→source / AI
          GestureDetector(
            onTap: () => setState(() {
              if (_textDirection == 'source2target') {
                _textDirection = 'target2source';
              } else if (_textDirection == 'target2source') {
                _textDirection = 'ai';
              } else {
                _textDirection = 'source2target';
              }
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              decoration: BoxDecoration(
                color: _textDirection == 'source2target'
                    ? const Color(0xFF4A90D9)
                    : _textDirection == 'target2source'
                        ? const Color(0xFFE85D75)
                        : const Color(0xFF8B5CF6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _textDirection == 'source2target'
                    ? '${_sourceLang.toUpperCase()}→${_targetLang.toUpperCase()}'
                    : _textDirection == 'target2source'
                        ? '${_targetLang.toUpperCase()}→${_sourceLang.toUpperCase()}'
                        : 'AI',
                style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
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
                  hintText: '한국어 또는 일본어 입력...',
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
          if (_mode == 'realtime') ...[
            // Realtime: single mic button
            _buildCircleButton(
              icon: Icons.mic,
              size: 36,
              color: _realtimeActive ? Colors.red : const Color(0xFF4A90D9),
              onTap: () => _realtimeActive ? _stopRealtime() : _startRealtime(),
            ),
          ] else ...[
            // Source language mic
            _buildLangMicButton(
              langCode: _sourceLang,
              color: const Color(0xFF4A90D9),
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
    // If already listening/recording in this language, stop
    if ((_isListening || _isRecording) && _micLang == lang) {
      if (_isRecording) {
        _stopOpenAIRecording(forceDirection: direction);
      } else {
        _stopListening();
      }
      return;
    }

    // Start listening in the selected language
    setState(() => _micLang = lang);
    if (_mode == 'openai') {
      _startOpenAIRecording(forceDirection: direction);
    } else {
      _startListening();
    }
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
                              'そのまま話してください',
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
                                  '${getLangByCode(_targetLang).name}→${getLangByCode(_sourceLang).name}',
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
