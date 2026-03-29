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
  String _mode = 'browser'; // browser, openai, realtime
  String _model = 'gpt-5.4-nano';
  bool _ttsJaEnabled = false;
  bool _ttsKoEnabled = false;
  String _voiceJa = 'onyx';
  String _voiceKo = 'nova';
  double _fontSize = 16;
  String _micLang = 'ko';
  bool _showSettings = false;
  double _ttsSpeed = 1.0;
  int _pauseSeconds = 3;
  double _vadThreshold = 0.9;
  double _noiseThreshold = -30; // dB, below this = silence
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
      _ttsJaEnabled = prefs.getBool('ttsJa') ?? false;
      _ttsKoEnabled = prefs.getBool('ttsKo') ?? false;
      _voiceJa = prefs.getString('voiceJa') ?? 'onyx';
      _voiceKo = prefs.getString('voiceKo') ?? 'nova';
      _fontSize = prefs.getDouble('fontSize') ?? 16;
      _mode = prefs.getString('mode') ?? 'browser';
      _model = prefs.getString('model') ?? 'gpt-5.4-nano';
      _ttsSpeed = prefs.getDouble('ttsSpeed') ?? 1.0;
      _pauseSeconds = prefs.getInt('pauseSeconds') ?? 3;
      _realtimeModel = prefs.getString('realtimeModel') ?? 'gpt-realtime-mini';
      _noiseThreshold = prefs.getDouble('noiseThreshold') ?? -30;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('ttsJa', _ttsJaEnabled);
    prefs.setBool('ttsKo', _ttsKoEnabled);
    prefs.setString('voiceJa', _voiceJa);
    prefs.setString('voiceKo', _voiceKo);
    prefs.setDouble('fontSize', _fontSize);
    prefs.setString('mode', _mode);
    prefs.setString('model', _model);
    prefs.setDouble('ttsSpeed', _ttsSpeed);
    prefs.setInt('pauseSeconds', _pauseSeconds);
    prefs.setString('realtimeModel', _realtimeModel);
    prefs.setDouble('noiseThreshold', _noiseThreshold);
  }

  String _detectLang(String text) {
    int ko = 0, ja = 0;
    for (final ch in text.runes) {
      if ((ch >= 0xAC00 && ch <= 0xD7AF) ||
          (ch >= 0x1100 && ch <= 0x11FF) ||
          (ch >= 0x3130 && ch <= 0x318F)) ko++;
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) {
        ja++;
      }
      if (ch >= 0x4E00 && ch <= 0x9FFF) ja++;
    }
    return ko >= ja ? 'ko' : 'ja';
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

    final direction =
        forceDirection ?? (_detectLang(text) == 'ko' ? 'ko2ja' : 'ja2ko');

    String translated = '';
    String? backTranslation;

    try {
      final result = await _openai.translate(text, direction, model: _model);
      translated = result['translated'] ?? '';
      backTranslation = result['back_translation'];

      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            original: text,
            translated: translated,
            backTranslation: backTranslation,
            direction: direction,
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }

    // TTS after processing flag released — doesn't block next input
    if (translated.isNotEmpty) {
      final ttsLang = direction == 'ko2ja' ? 'ja' : 'ko';
      final shouldPlay =
          (ttsLang == 'ja' && _ttsJaEnabled) ||
          (ttsLang == 'ko' && _ttsKoEnabled);
      if (shouldPlay) {
        if (_mode == 'browser') {
          final gender = (ttsLang == 'ja' ? _voiceJa : _voiceKo) == 'nova' || (ttsLang == 'ja' ? _voiceJa : _voiceKo) == 'coral' ? 'female' : 'male';
          _speech.speak(translated, ttsLang, rate: _ttsSpeed, gender: gender);
        } else {
          _playOpenAITTS(translated, ttsLang, ttsLang == 'ja' ? _voiceJa : _voiceKo);
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
      final g = (lang == 'ja' ? _voiceJa : _voiceKo) == 'nova' || (lang == 'ja' ? _voiceJa : _voiceKo) == 'coral' ? 'female' : 'male';
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

    await _speech.startListening(
      locale: _micLang == 'ko' ? 'ko_KR' : 'ja_JP',
      pauseSeconds: _pauseSeconds,
      onResult: (text, isFinal) {
        setState(() => _interimText = text);
        if (isFinal && text.isNotEmpty) {
          _stopListening();
          _handleTranslation(text);
        }
      },
      onDone: () => setState(() => _isListening = false),
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
    if (_mode == 'realtime' && _realtimeActive) {
      _realtime?.sendText(text);
    } else {
      _handleTranslation(text);
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
      final shouldMute = !_ttsJaEnabled && !_ttsKoEnabled;
      _realtime!.muteAudio(shouldMute);
    }
  }

  // ===== Realtime =====
  String _detectLangSimple(String text) {
    int ko = 0, ja = 0;
    for (final ch in text.runes) {
      if ((ch >= 0xAC00 && ch <= 0xD7AF)) ko++;
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) ja++;
    }
    return ko >= ja ? 'ko' : 'ja';
  }

  Future<void> _startRealtime() async {
    if (_realtimeActive) return;
    setState(() => _interimText = 'Realtime 연결 중...');

    _realtime = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _voiceJa == 'onyx' ? 'ash' : 'coral',
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
          final outputLang = _detectLangSimple(turn.output);
          final direction = outputLang == 'ja' ? 'ko2ja' : 'ja2ko';
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

          // Back-translation only if no input transcript available
          if (turn.input.isEmpty) {
            final reverseDir = outputLang == 'ja' ? 'ja2ko' : 'ko2ja';
            _openai.translate(turn.output, reverseDir, model: _model).then((r) {
              if (!mounted) return;
              if (r['translated']?.isNotEmpty ?? false) {
                setState(() {
                  final idx = _messages.indexOf(msg);
                  if (idx >= 0) {
                    _messages[idx] = ChatMessage(
                      original: r['translated']!,
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
      final gr = (lang == 'ja' ? _voiceJa : _voiceKo) == 'nova' || (lang == 'ja' ? _voiceJa : _voiceKo) == 'coral' ? 'female' : 'male';
      await _speech.speak(msg.translated, lang, gender: gr);
    } else {
      await _playOpenAITTS(
          msg.translated, lang, lang == 'ja' ? _voiceJa : _voiceKo);
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
          onReplay: () => _replayMessage(msg),
        );
      },
    );
  }

  Widget _buildSettingsRow() {
    if (!_showSettings) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          _labeledSetting('모드', _buildDropdown<String>(
            value: _mode,
            items: {'browser': '브라우저', 'openai': 'OpenAI', 'realtime': 'RT'},
            onChanged: (v) => setState(() { _mode = v!; _saveSettings(); }),
          )),
          if (_mode == 'realtime')
            _labeledSetting('모델', _buildDropdown<String>(
              value: _realtimeModel,
              items: {'gpt-realtime-mini': 'mini', 'gpt-realtime': 'std', 'gpt-realtime-1.5': '1.5'},
              onChanged: (v) => setState(() { _realtimeModel = v!; _saveSettings(); }),
            ))
          else
            _labeledSetting('모델', _buildDropdown<String>(
              value: _model,
              items: {'gpt-4.1-nano': '4.1n', 'gpt-4.1-mini': '4.1m', 'gpt-5.4-nano': '5.4n', 'gpt-5.4-mini': '5.4m', 'gpt-5.4': '5.4'},
              onChanged: (v) => setState(() { _model = v!; _saveSettings(); }),
            )),
          _labeledSetting('JA', _buildToggle('', _ttsJaEnabled, () {
            setState(() => _ttsJaEnabled = !_ttsJaEnabled); _saveSettings();
            _updateRealtimeAudioMute();
          })),
          _labeledSetting('JA음성', _buildDropdown<String>(
            value: _voiceJa,
            items: {'onyx': '남', 'coral': '여'},
            onChanged: (v) => setState(() { _voiceJa = v!; _saveSettings(); }),
          )),
          _labeledSetting('KO', _buildToggle('', _ttsKoEnabled, () {
            setState(() => _ttsKoEnabled = !_ttsKoEnabled); _saveSettings();
            _updateRealtimeAudioMute();
          })),
          _labeledSetting('KO음성', _buildDropdown<String>(
            value: _voiceKo,
            items: {'nova': '여', 'ash': '남'},
            onChanged: (v) => setState(() { _voiceKo = v!; _saveSettings(); }),
          )),
          _labeledSetting('크기', _buildDropdown<double>(
            value: _fontSize,
            items: {12.0: '12', 14.0: '14', 16.0: '16', 18.0: '18', 20.0: '20', 24.0: '24', 28.0: '28', 32.0: '32'},
            onChanged: (v) => setState(() { _fontSize = v!; _saveSettings(); }),
          )),
          // TTS Speed (browser only)
          if (_mode == 'browser')
            _labeledSetting('속도', _buildDropdown<double>(
              value: _ttsSpeed,
              items: {0.5: '0.5x', 0.75: '0.75x', 1.0: '1x', 1.25: '1.25x', 1.5: '1.5x'},
              onChanged: (v) => setState(() { _ttsSpeed = v!; _saveSettings(); }),
            )),
          // Silence timeout (browser + openai)
          if (_mode == 'browser' || _mode == 'openai')
            _labeledSetting('묵음', _buildDropdown<int>(
              value: _pauseSeconds,
              items: {1: '1s', 2: '2s', 3: '3s', 5: '5s', 7: '7s', 30: 'OFF'},
              onChanged: (v) => setState(() { _pauseSeconds = v!; _saveSettings(); }),
            )),
          // Noise threshold (openai only)
          if (_mode == 'openai')
            _labeledSetting('소음', _buildDropdown<double>(
              value: _noiseThreshold,
              items: {-20.0: '높음', -30.0: '보통', -40.0: '낮음', -50.0: '조용'},
              onChanged: (v) => setState(() { _noiseThreshold = v!; _saveSettings(); }),
            )),
          // VAD threshold (realtime only)
          if (_mode == 'realtime')
            _labeledSetting('감도', _buildDropdown<double>(
              value: _vadThreshold,
              items: {0.3: '0.3', 0.5: '0.5', 0.7: '0.7', 0.8: '0.8', 0.9: '0.9', 0.95: '0.95'},
              onChanged: (v) => setState(() { _vadThreshold = v!; _saveSettings(); }),
            )),
        ],
      ),
    );
  }

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
          // Mic
          _buildCircleButton(
            icon: Icons.mic,
            size: 36,
            color: (_isListening || _realtimeActive || _isRecording) ? Colors.red : const Color(0xFF4A90D9),
            onTap: () {
              if (_mode == 'realtime') {
                _realtimeActive ? _stopRealtime() : _startRealtime();
              } else if (_mode == 'openai') {
                _isRecording ? _stopOpenAIRecording() : _startOpenAIRecording();
              } else {
                _isListening ? _stopListening() : _startListening();
              }
            },
          ),
          if (_mode != 'realtime') ...[
          const SizedBox(width: 4),
          // Language toggle
          GestureDetector(
            onTap: () {
              if (_isListening) return;
              setState(() => _micLang = _micLang == 'ko' ? 'ja' : 'ko');
            },
            child: Container(
              width: 28,
              height: 36,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _micLang == 'ko'
                      ? const Color(0xFF4A90D9)
                      : const Color(0xFFE85D75),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                _micLang.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: _micLang == 'ko'
                      ? const Color(0xFF4A90D9)
                      : const Color(0xFFE85D75),
                ),
              ),
            ),
          ),
          ],
          const SizedBox(width: 4),
          // Settings toggle
          _buildCircleButton(
            icon: _showSettings ? Icons.expand_more : Icons.settings,
            size: 28,
            color: _showSettings ? const Color(0xFF4A90D9) : Colors.grey,
            onTap: () => setState(() => _showSettings = !_showSettings),
            outlined: true,
          ),
        ],
      ),
    );
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
            // === Mirror half (rotated) ===
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
                        '韓国語⇄日本語通訳 / 한국어⇄일본어통역',
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
                                  '押して話す→翻訳',
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
            // === Divider ===
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
                      '한국어⇄일본어통역 / 韓国語⇄日本語通訳',
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
                  _buildSettingsRow(),
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
