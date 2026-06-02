import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as java_io;
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http_client;
import '../services/openai_service.dart';
import '../services/blob_url.dart';
import '../services/realtime_postprocess_ws_service.dart';
import '../services/responses_text_ws_service.dart';
import '../services/speech_service.dart';
import '../services/realtime_service.dart';
import '../services/realtime_translation_service.dart';
import '../services/realtime_transcription_ws_service.dart';
import '../services/wav_audio.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/settings_sheet.dart';
import '../models/language.dart';
import '../prompts.dart';
import '../main.dart' show clearApiKey, ApiKeyScreen;

typedef _TtsAudioCacheKey = ({
  String text,
  String lang,
  String model,
  String voice,
  String responseFormat,
  int instructionsRevision,
});

typedef _RenderedPromptCacheKey = ({
  String kind,
  String sourceLang,
  String targetLang,
  String sourceLangCode,
  String targetLangCode,
  String toneMode,
  int revision,
  bool hasContext,
});

typedef _StoppedRecording = ({
  String path,
  Uint8List? bytes,
  String filename,
  RealtimeTranscriptionWsService? realtimeStt,
});

typedef _SttBenchmarkResult = ({
  String model,
  String text,
  int? firstDeltaMs,
  int doneMs,
});

typedef _TranslationBenchmarkResult = ({
  String model,
  String translated,
  int doneMs,
});

class TranslatorScreen extends StatefulWidget {
  final String apiKey;
  const TranslatorScreen({super.key, required this.apiKey});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen>
    with WidgetsBindingObserver {
  late OpenAIService _openai;
  final SpeechService _speech = SpeechService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _audioPlayerStateSub;
  bool _audioPlayerMayBeActive = false;
  final AudioRecorder _recorder = AudioRecorder();
  static const String _primaryRecorderOwner = 'primary';
  static const String _mirrorRecorderOwner = 'mirror';
  final http_client.Client _blobHttpClient = http_client.Client();
  static const int _ttsAudioCacheMaxEntries = 16;
  static const int _ttsAudioCacheMaxBytes = 8 * 1024 * 1024;
  static const int _ttsPrerollSampleRate = 24000;
  static const int _ttsPrerollMs = 240;
  static final Uint8List _ttsPrerollAudio = _buildTtsPrerollAudio();
  static const RecordConfig _openAIRecordConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 64000,
    sampleRate: 24000,
    numChannels: 1,
    autoGain: true,
    echoCancel: true,
    noiseSuppress: true,
  );
  static const int _webStreamSampleRate = 24000;
  static const int _webStreamChannels = 1;
  static const RecordConfig _openAIStreamRecordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: _webStreamSampleRate,
    numChannels: _webStreamChannels,
    autoGain: true,
    echoCancel: true,
    noiseSuppress: true,
  );
  Future<bool>? _micPermissionFuture;
  Future<String>? _tempDirectoryPathFuture;
  bool _isRecording = false;
  final LinkedHashMap<_TtsAudioCacheKey, Uint8List> _ttsAudioCache =
      LinkedHashMap();
  final Map<_TtsAudioCacheKey, Future<Uint8List>> _ttsAudioRequests = {};
  int _ttsAudioCacheBytes = 0;
  int _playbackGeneration = 0;
  DateTime? _lastTtsOutputPrimeAt;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _myScrollController = ScrollController();
  final ScrollController _mirrorScrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  bool _isListening = false;
  bool _isMirrorListening = false;
  bool _isProcessing = false;
  bool _isRecordingStarting = false;
  bool _isMirrorStarting = false;
  bool _mirrorUsesOpenAIRecording = false;
  String? _activeRecorderOwner;
  String? _streamRecorderOwner;
  String _systemSttText = '';
  String? _systemSttDirection;
  int _systemSttSerial = 0;
  int _systemSttGeneration = 0;
  bool _systemSttAskAI = false;
  bool _systemSttAcceptingResults = false;
  String? _systemSttError;
  String _systemSttLang = 'ko';
  Future<void>? _systemSttFallbackRecorderStart;
  String _systemSttCommittedText = '';
  bool _systemSttStopRequested = false;
  Future<void>? _systemSttRestartFuture;
  Timer? _systemSttAutoStopTimer;
  bool _systemSttSegmentHadText = false;
  String _mirrorSystemSttText = '';
  bool _mirrorSystemSttAcceptingResults = false;
  String? _mirrorSystemSttError;
  Future<void>? _mirrorSystemSttFallbackRecorderStart;
  String _mirrorSystemSttCommittedText = '';
  bool _mirrorSystemSttStopRequested = false;
  Future<void>? _mirrorSystemSttRestartFuture;
  Timer? _mirrorSystemSttAutoStopTimer;
  bool _mirrorSystemSttSegmentHadText = false;
  StreamSubscription<Uint8List>? _recordStreamSub;
  Completer<void>? _recordStreamDone;
  List<Uint8List>? _recordStreamChunks;
  RealtimeTranscriptionWsService? _recordStreamRealtimeStt;
  String? _recordStreamRealtimeSttOwner;
  Future<void>? _recordingStopFuture;
  Future<void>? _mirrorStopFuture;
  int _recordingSerial = 0;
  int _mirrorRecordingSerial = 0;
  int _recordingFileSerial = 0;
  int _conversationGeneration = 0;
  int _processingToken = 0;
  Future<void> _translationQueue = Future.value();
  String _interimText = '';
  String _mirrorInterimText = '';
  final ValueNotifier<String> _interimTextNotifier = ValueNotifier('');
  final ValueNotifier<String> _mirrorInterimTextNotifier = ValueNotifier('');
  Timer? _interimFlashTimer;
  Timer? _interimUpdateTimer;
  final Stopwatch _interimClock = Stopwatch()..start();
  int? _lastInterimUpdateMs;
  RealtimeTurn? _pendingInterimTurn;
  bool _scrollToBottomScheduled = false;
  String? _lastErrorMessage;
  DateTime? _lastErrorShownAt;
  Timer? _realtimeGraceTimer;
  Timer? _pingPongWsGraceTimer;
  Timer? _liveTranslateCommitTimer;
  // Realtime translation usually streams deltas first; done events are used
  // when present and this no-delta gap is the fallback commit path.
  static const Duration _liveTranslateCommitDelay = Duration(
    milliseconds: 1800,
  );
  static const Duration _systemSttFinalFlushDelay = Duration(milliseconds: 40);
  static const Duration _systemSttEmptyFlushTimeout = Duration(
    milliseconds: 1200,
  );
  static const Duration _androidSystemSttRestartGap = Duration(
    milliseconds: 120,
  );
  String? _liveTranslateBufferSession;
  StringBuffer _liveTranslateOutputBuffer = StringBuffer();
  DateTime? _liveTranslateLastServerEventAt;
  DateTime? _liveTranslateLastNoServerLogAt;
  DateTime? _liveTranslateLastOutputLogAt;
  int _liveTranslateOutputEventCount = 0;
  Timer? _settingsSaveTimer;
  Future<void>? _settingsSaveFuture;
  bool _settingsDirty = false;
  bool _settingsSaveAgain = false;
  Map<String, Object> _persistedSettings = {};
  final Map<String, Timer> _promptSaveTimers = {};
  final Map<String, String> _pendingPromptSaves = {};
  final Map<String, Future<void>> _promptSaveChains = {};
  Future<SharedPreferences>? _prefsFuture;
  final Set<String> _retryablePingPongTurnIds = {};
  bool _appInBackground = false;
  bool _disposed = false;

  // Realtime
  RealtimeService? _realtime;
  RealtimeTranslationService? _realtimeTranslate; // 실시간통역 A: source → target
  RealtimeTranslationService? _realtimeTranslateB; // 실시간통역 B: target → source
  RealtimeTranslationService? _drainingRealtimeTranslate;
  String? _drainingRealtimeTranslateSession;
  RealtimePostProcessWsService? _rtPostProcessor;
  String? _rtPostProcessorKey;
  Future<RealtimePostProcessWsService>? _rtPostProcessorStartFuture;
  String? _rtPostProcessorStartKey;
  Future<void> _rtPostProcessQueue = Future.value();
  final Map<String, ({int index, int generation})>
  _realtimeInputItemMessageIndex = {};
  bool _realtimeActive = false;
  bool _realtimeMicPaused = false;
  Future<void>? _realtimeStartFuture;
  Future<void>? _realtimeStopFuture;
  Future<void>? _realtimeTranslateAStartFuture;
  Future<void>? _realtimeTranslateBStartFuture;
  int _realtimeLifecycleId = 0;
  int _liveTranslateSwitchSerial = 0;
  bool _realtimePausedByBackground = false;
  bool _realtimeWasPausedBeforeBackground = false;
  bool _directionalWasPausedBeforeBackground = false;
  DateTime? _realtimeBackgroundedAt;
  DateTime? _pingPongWsBackgroundedAt;

  // Realtime (방향) — dual sessions
  RealtimeService? _realtimeA; // source → target
  RealtimeService? _realtimeB; // target → source
  Future<void>? _realtimeAStartFuture;
  Future<void>? _realtimeBStartFuture;
  String _activeDirectionalSession = 'a';
  bool _directionalPaused = false;

  bool get _isRt => _isLiveTranslateMode;
  bool get _isRealtimeTranslateMode => _mode == 'realtime_translate';
  bool get _isLiveTranslateMode => _isRealtimeTranslateMode;
  bool get _isDirectionalMode => _mode == 'realtime_dir';

  // Settings
  String _textDirection = 'source2target'; // for text input
  bool _inputExpanded = false;
  bool _aiMode = false;
  String _mode = 'openai'; // openai, realtime_translate
  String _model = 'gpt-5.4-mini';
  String _aiModel = 'gpt-5.4-mini';
  int _aiPauseSeconds = 5; // AI mode silence timeout (longer than translation)
  String _sourceLang = 'ko';
  String _targetLang = 'ja';
  String _sourceLangName = getLangByCode('ko').name;
  String _targetLangName = getLangByCode('ja').name;
  String _sourceToTargetDirection = 'ko2ja';
  String _targetToSourceDirection = 'ja2ko';
  String _textInputHint = _buildTextInputHintFor('ko', 'ja');
  String _rtPostProcessPairPayloadSegment =
      _buildRtPostProcessPairPayloadSegment(
        sourceLang: 'ko',
        sourceLangName: '한국어',
        targetLang: 'ja',
        targetLangName: '日本語',
      );
  String _displayMode = 'one'; // 'face' (대면) or 'one' (단방향)
  bool _ttsSourceEnabled = false;
  bool _ttsTargetEnabled = false;
  bool _liveTranslateAudioEnabled = false;
  String _liveTranslateAudioRoute = 'mono';
  double _liveTranslateAudioBoostGain = 1.65;
  int _liveTranslateAudioBoostMs = 1100;
  String _liveTranslateInputNoiseReduction = 'near_field';
  double _liveTranslateCaptionFontSize = 28;
  String _ttsModel = 'gpt-4o-mini-tts';
  String _ttsAudioRoute = 'mono';
  String _systemTtsEngine = 'flutter';
  bool _systemTtsSilentPrimeEnabled = false;
  String _voiceSource = 'nova';
  String _voiceTarget = 'onyx';
  double _fontSize = 16;
  double _secondaryFontSize = 11;
  String _micLang = 'ko';
  double _ttsSpeed = 1.0;
  int _pauseSeconds = 3;
  double _vadThreshold = 0.9;
  String _turnDetectionType = 'server_vad'; // server_vad | semantic_vad
  String _vadEagerness = 'low'; // semantic_vad only
  int _silenceDurationMs = 500; // server_vad only
  double _noiseThreshold = -30;
  String _toneMode = 'normal'; // normal, polite, casual
  ToneMode get _tone => switch (_toneMode) {
    'polite' => ToneMode.polite,
    'casual' => ToneMode.casual,
    _ => ToneMode.normal,
  };
  String _realtimeVoice = 'coral';
  String _realtimeModel = 'gpt-realtime-2';
  static const String _detectModel = 'gpt-5.4-nano';
  static const String _detectReasoningEffort = 'minimal';
  String _rtPostProcessMode = 'chat'; // chat or realtime2
  bool _backTranslateSource = true;
  bool _backTranslateTarget = true;
  bool _showPronunciation = false;
  bool _deleteConversationItems = true;
  bool _injectFewShot = true;
  bool _translationContext = false;
  double _translationTemp = 0.3;
  String _translationReasoningEffort = 'low';
  bool _translationBenchmarkEnabled = false;
  String _sttModel = 'gpt-4o-transcribe';
  bool _sttBenchmarkEnabled = false;
  bool _androidSystemSttFastInterim = true;
  String _realtimeSttDelay = 'minimal';
  String _sttPrompt = '';
  double _classifyTemp = 0.1;
  double _pronunciationTemp = 0.3;
  String _postProcessBackTranslationModel = 'gpt-5.4-mini';
  String _postProcessBackTranslationReasoningEffort = 'low';
  String _postProcessPronunciationModel = 'gpt-5.4-mini';
  String _postProcessPronunciationReasoningEffort = 'minimal';
  int _realtimeBackgroundGraceSeconds = 300;
  bool _pingPongTransportOptimized = true;
  int _pingPongWsBackgroundGraceSeconds = 300;
  String _pingPongWebWsProxyUrl = _defaultPingPongWebWsProxyUrl;
  PromptTemplateSet _promptTemplates = AppPrompts.defaults;
  int _promptRevision = 0;
  int _ttsInstructionsRevision = 0;
  final LinkedHashMap<_RenderedPromptCacheKey, String> _renderedPromptCache =
      LinkedHashMap();
  static const int _renderedPromptCacheMaxEntries = 32;
  static const _verboseRealtimePostProcessLogs = false;
  static const _verbosePingPongTimingLogs = true;
  static const _verboseLiveTranslateLogs = true;
  static const _verboseTtsAudioLogs = true;
  static const String _defaultPingPongWebWsProxyUrl = String.fromEnvironment(
    'PINGPONG_WS_PROXY_URL',
    defaultValue: '',
  );
  static const int _appLogMaxEntries = 400;
  static final RegExp _whitespacePattern = RegExp(r'\s+');
  final Map<String, ResponsesTextWsService> _pingPongTextWsServices = {};
  final Expando<int> _pingPongTimingLastElapsedMs = Expando<int>();
  final List<String> _appLogLines = [];

  void _appendAppLog(String line) {
    final now = DateTime.now();
    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    _appLogLines.add('$timestamp $line');
    if (_appLogLines.length > _appLogMaxEntries) {
      _appLogLines.removeRange(0, _appLogLines.length - _appLogMaxEntries);
    }
  }

  void _logAppLine(String line) {
    _appendAppLog(line);
    debugPrint(line);
  }

  void _logRealtimePostProcess(String Function() message) {
    if (_verboseRealtimePostProcessLogs) _logAppLine(message());
  }

  void _logLiveTranslate(String Function() message) {
    if (_verboseLiveTranslateLogs) _logAppLine('[LT] ${message()}');
  }

  void _logTtsAudio(String Function() message) {
    if (_verboseTtsAudioLogs) _logAppLine('[TTS] ${message()}');
  }

  void _logPingPongTiming(String event, Stopwatch clock) {
    if (!_verbosePingPongTimingLogs) return;
    if (event.startsWith('stt_bench')) return;
    final elapsedMs = clock.elapsedMilliseconds;
    final previousMs = _pingPongTimingLastElapsedMs[clock];
    final stepMs = previousMs == null ? elapsedMs : elapsedMs - previousMs;
    _pingPongTimingLastElapsedMs[clock] = elapsedMs;
    _logAppLine(
      '[핑퐁 시간] ${_pingPongTimingLabel(event)} '
      '| 누적 ${_formatPingPongMs(elapsedMs)} '
      '| 직전 +${_formatPingPongMs(stepMs)}',
    );
  }

  String _formatPingPongMs(int milliseconds) {
    final safeMs = milliseconds < 0 ? 0 : milliseconds;
    if (safeMs < 1000) return '${safeMs}ms';
    final seconds = safeMs / 1000;
    final decimals = safeMs >= 10000 ? 1 : 2;
    return '${seconds.toStringAsFixed(decimals)}초 (${safeMs}ms)';
  }

  String _pingPongTimingLabel(String event) {
    return switch (event) {
      'record_stop_clicked' => '발화 종료 버튼 입력',
      'recorder_stop_done' => '녹음 중지 완료',
      'audio_bytes_ready' => '녹음파일/오디오 데이터 준비 완료',
      'stt_ws_commit' => '실시간 STT 버퍼 확정',
      'stt_ws_first_delta' => '실시간 STT 첫 글자 수신',
      'stt_ws_done' => '실시간 STT 완료',
      'stt_request_sent' => 'STT 요청 전송',
      'stt_multipart_ready' => 'STT 전송 파일 구성 완료',
      'stt_upload_start' => 'STT 오디오 업로드 시작',
      'stt_response_headers' => 'STT 업로드 완료/응답 시작',
      'stt_response_body_done' => 'STT 응답 본문 수신 완료',
      'stt_first_delta' => 'STT 첫 글자 수신',
      'stt_done' => 'STT 완료',
      'system_stt_stop_done' => '시스템 STT 중지 완료',
      'system_stt_text_ready' => '시스템 STT 텍스트 준비 완료',
      'system_stt_openai_fallback' => '시스템 STT 실패: OpenAI STT 대체',
      'translation_request_sent' => '번역 요청 전송',
      'translation_ws_ready' => '번역 WebSocket 준비 완료',
      'translation_ws_request_sent' => '번역 WebSocket 요청 전송',
      'translation_first_delta' => '번역 첫 글자 수신',
      'translation_done' => '번역 완료',
      'translation_rest_request_sent' => '번역 REST 요청 전송',
      'translation_bubble_ready' => '번역 말풍선 표시',
      'tts_disabled' => 'TTS 꺼짐: 텍스트만 표시',
      'tts_prepare_start' => 'TTS 오디오 준비 시작',
      'tts_audio_ready' => 'TTS 오디오 수신 완료',
      'tts_play_start' => 'TTS 재생 직전',
      'tts_system_start' => '시스템 TTS 호출',
      'tts_system_ready_to_speak' => '시스템 TTS 내부 준비 완료',
      'tts_system_speak_returned' => '시스템 TTS speak 반환',
      'tts_system_start_event' => '시스템 TTS 시작 이벤트',
      'tts_system_fallback_start' => 'API TTS 실패: 시스템 TTS 대체 호출',
      'tts_system_fallback_ready_to_speak' => '대체 시스템 TTS 내부 준비 완료',
      'tts_system_fallback_speak_returned' => '대체 시스템 TTS speak 반환',
      'tts_system_fallback_start_event' => '대체 시스템 TTS 시작 이벤트',
      _ => event,
    };
  }

  void _logSttBenchmark(String Function() message) {
    _logAppLine('[PP-STT-BENCH] ${message()}');
  }

  void _logTranslationBenchmark(String Function() message) {
    _logAppLine('[PP-TR-BENCH] ${message()}');
  }

  void _logPingPongWs(String Function() message) {
    _logAppLine('[PP-WS] ${message()}');
  }

  void _logPingPongPostProcess(String Function() message) {
    _logAppLine('[PP-POST] ${message()}');
  }

  void _setInterimTextValue(String value) {
    _interimText = value;
    if (!_disposed && _interimTextNotifier.value != value) {
      _interimTextNotifier.value = value;
    }
  }

  void _setMirrorInterimTextValue(String value) {
    _mirrorInterimText = value;
    if (!_disposed && _mirrorInterimTextNotifier.value != value) {
      _mirrorInterimTextNotifier.value = value;
    }
  }

  void _setInterimTextPair(String text, String mirrorText) {
    _setInterimTextValue(text);
    _setMirrorInterimTextValue(mirrorText);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openai = OpenAIService(widget.apiKey);
    _audioPlayerStateSub = _audioPlayer.onPlayerStateChanged.listen((state) {
      _audioPlayerMayBeActive =
          state == PlayerState.playing || state == PlayerState.paused;
    });
    if (!kIsWeb) {
      _tempDirectoryPathFuture = getTemporaryDirectory().then(
        (directory) => directory.path,
      );
    }
    _loadSettings();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _ampSub?.cancel();
    _silenceTimer?.cancel();
    _interimFlashTimer?.cancel();
    _interimUpdateTimer?.cancel();
    _realtimeGraceTimer?.cancel();
    _pingPongWsGraceTimer?.cancel();
    _liveTranslateCommitTimer?.cancel();
    _cancelPrimarySystemSttAutoStop();
    _cancelMirrorSystemSttAutoStop();
    _flushSettings();
    _flushPromptSaves();
    _speech.stopListening();
    _speech.stopSpeaking();
    _realtime?.stop();
    _realtimeTranslate?.stop();
    _realtimeTranslateB?.stop();
    _drainingRealtimeTranslate?.stop();
    _drainingRealtimeTranslateSession = null;
    _rtPostProcessor?.stop();
    _discardPingPongTextWs();
    _recordStreamRealtimeStt?.stop();
    _recordStreamSub?.cancel();
    _realtimeA?.stop();
    _realtimeB?.stop();
    _recorder.dispose();
    _textController.dispose();
    _myScrollController.dispose();
    _mirrorScrollController.dispose();
    _audioPlayerStateSub?.cancel();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    _interimTextNotifier.dispose();
    _mirrorInterimTextNotifier.dispose();
    _blobHttpClient.close();
    _ttsAudioCache.clear();
    _ttsAudioRequests.clear();
    _openai.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _handleAppResumed();
        break;
      case AppLifecycleState.inactive:
        if (!kIsWeb) {
          _handleAppBackgrounded(reason: state.name);
        }
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _handleAppBackgrounded(reason: state.name);
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  void _handleAppBackgrounded({String reason = 'background'}) {
    _flushSettings();
    _flushPromptSaves();
    _handlePingPongWsBackgrounded();
    _logLiveTranslate(
      () =>
          'lifecycle.background reason=$reason active=$_realtimeActive '
          'mode=$_mode appInBackground=$_appInBackground',
    );
    if (_appInBackground || !_realtimeActive) {
      _appInBackground = true;
      return;
    }
    _appInBackground = true;
    _realtimePausedByBackground = true;
    _realtimeWasPausedBeforeBackground = _realtimeMicPaused;
    _directionalWasPausedBeforeBackground = _directionalPaused;
    _realtimeBackgroundedAt = DateTime.now();
    _pauseRealtimeForGrace(reason: reason);
    _realtimeGraceTimer?.cancel();
    if (_realtimeBackgroundGraceSeconds <= 0) {
      _stopRealtime();
      return;
    }
    _realtimeGraceTimer = Timer(
      Duration(seconds: _realtimeBackgroundGraceSeconds),
      () {
        if (!_appInBackground || !_realtimeActive) return;
        _stopRealtime();
      },
    );
  }

  void _handleAppResumed() {
    _handlePingPongWsResumed();
    final backgroundedAt = _realtimeBackgroundedAt;
    _realtimeBackgroundedAt = null;
    _appInBackground = false;
    _realtimeGraceTimer?.cancel();
    _realtimeGraceTimer = null;
    if (!_realtimeActive) return;
    if (_realtimeBackgroundGraceSeconds > 0 && backgroundedAt != null) {
      final elapsed = DateTime.now().difference(backgroundedAt);
      final grace = Duration(seconds: _realtimeBackgroundGraceSeconds);
      if (elapsed >= grace) {
        _stopRealtime();
        return;
      }
    }
    if (_realtimePausedByBackground) {
      final wasPaused = (_isDirectionalMode || _isRealtimeTranslateMode)
          ? _directionalWasPausedBeforeBackground
          : _realtimeWasPausedBeforeBackground;
      _realtimePausedByBackground = false;
      _realtimeWasPausedBeforeBackground = false;
      _directionalWasPausedBeforeBackground = false;
      if (!wasPaused) {
        if (_isRealtimeTranslateMode) {
          unawaited(_resumeLiveTranslateMic());
        } else if (_isDirectionalMode) {
          _resumeDirectionalMic();
        } else {
          _resumeRealtimeMic();
        }
        return;
      }
    }
    _pauseRealtimeForGrace(showStatus: true, reason: 'resumed_keep_paused');
  }

  void _handlePingPongWsBackgrounded() {
    if (_pingPongTextWsServices.isEmpty) return;
    _pingPongWsBackgroundedAt = DateTime.now();
    _pingPongWsGraceTimer?.cancel();
    if (!_pingPongTransportOptimized ||
        _pingPongWsBackgroundGraceSeconds <= 0) {
      _discardPingPongTextWs();
      return;
    }
    _pingPongWsGraceTimer = Timer(
      Duration(seconds: _pingPongWsBackgroundGraceSeconds),
      () {
        if (!_appInBackground) return;
        _discardPingPongTextWs();
      },
    );
  }

  void _handlePingPongWsResumed() {
    final backgroundedAt = _pingPongWsBackgroundedAt;
    _pingPongWsBackgroundedAt = null;
    _pingPongWsGraceTimer?.cancel();
    _pingPongWsGraceTimer = null;
    if (backgroundedAt == null || _pingPongWsBackgroundGraceSeconds <= 0) {
      return;
    }
    final grace = Duration(seconds: _pingPongWsBackgroundGraceSeconds);
    if (DateTime.now().difference(backgroundedAt) >= grace) {
      _discardPingPongTextWs();
    }
  }

  void _pauseRealtimeForGrace({
    bool showStatus = false,
    String reason = 'background',
  }) {
    if (!_realtimeActive) return;
    _logLiveTranslate(
      () =>
          'pauseForGrace reason=$reason mode=$_mode '
          'activeSession=$_activeDirectionalSession paused=$_directionalPaused',
    );
    _cancelPendingInterimUpdate();
    _realtime?.muteMic(true);
    _realtimeTranslate?.muteMic(true);
    _realtimeTranslateB?.muteMic(true);
    _realtimeA?.muteMic(true);
    _realtimeB?.muteMic(true);
    final pauseText = _isRealtimeTranslateMode
        ? '실시간 통역 일시정지'
        : 'Realtime 일시정지';
    final mirrorPauseText = _isRealtimeTranslateMode
        ? 'リアルタイム通訳 一時停止'
        : 'Realtime 一時停止';
    if (mounted) {
      setState(() {
        _realtimeMicPaused = true;
        if (_isDirectionalMode || _isRealtimeTranslateMode) {
          _directionalPaused = true;
        }
        if (showStatus) {
          _setInterimTextPair(pauseText, mirrorPauseText);
        }
      });
    } else {
      _realtimeMicPaused = true;
      if (_isDirectionalMode || _isRealtimeTranslateMode) {
        _directionalPaused = true;
      }
    }
  }

  Future<SharedPreferences> _prefs() {
    final current = _prefsFuture;
    if (current != null) return current;
    return _prefsFuture = SharedPreferences.getInstance();
  }

  String _normalizeMode(String? mode) {
    return switch (mode) {
      'openai' || 'browser' || null => 'openai',
      'realtime_translate' ||
      'realtime' ||
      'realtime_dir' ||
      'google_translate' => 'realtime_translate',
      _ => 'openai',
    };
  }

  String _normalizeDisplayMode(String? displayMode) {
    return switch (displayMode) {
      'face' || 'face_v2' => 'face',
      'one' => 'one',
      null => 'one',
      _ => 'one',
    };
  }

  String _normalizeLiveTranslateAudioRoute(String? route) {
    return switch (route) {
      'mine_left' || 'mine_right' => route!,
      _ => 'mono',
    };
  }

  String _normalizeLiveTranslateInputNoiseReduction(String? value) {
    return switch (value) {
      'near_field' || 'far_field' || 'none' => value!,
      _ => 'near_field',
    };
  }

  String _normalizeReasoningEffort(String? value, {String fallback = 'low'}) {
    return switch (value) {
      '' => '',
      'minimal' || 'low' || 'medium' || 'high' || 'xhigh' => value!,
      _ => fallback,
    };
  }

  String _normalizeSttModel(String? value) {
    return switch (value) {
      'gpt-realtime-whisper' ||
      'gpt-4o-mini-transcribe' ||
      'gpt-4o-transcribe' ||
      'system-stt' ||
      'whisper-1' => value!,
      _ => 'gpt-4o-transcribe',
    };
  }

  String _normalizeRealtimeSttDelay(String? value) {
    return switch (value) {
      'minimal' || 'low' || 'medium' || 'high' || 'xhigh' => value!,
      _ => 'minimal',
    };
  }

  double _normalizeLiveTranslateAudioBoostGain(double? value) {
    final normalized = (value ?? 1.65).clamp(1.0, 2.5).toDouble();
    const options = [1.0, 1.25, 1.65, 2.0, 2.35];
    return options.reduce(
      (a, b) => (normalized - a).abs() <= (normalized - b).abs() ? a : b,
    );
  }

  int _normalizeLiveTranslateAudioBoostMs(int? value) {
    final normalized = (value ?? 1100).clamp(0, 2500).toInt();
    const options = [0, 500, 800, 1100, 1500, 2000];
    return options.reduce(
      (a, b) => (normalized - a).abs() <= (normalized - b).abs() ? a : b,
    );
  }

  String _normalizeRealtimeVoice(String? value) {
    return switch (value) {
      'alloy' ||
      'ash' ||
      'ballad' ||
      'coral' ||
      'echo' ||
      'sage' ||
      'shimmer' ||
      'verse' ||
      'marin' ||
      'cedar' => value!,
      _ => 'coral',
    };
  }

  Future<void> _loadSettings() async {
    final prefs = await _prefs();
    final promptTemplates = await AppPrompts.loadTemplates(prefs: prefs);
    if (!mounted) return;
    final sourceLang = prefs.getString('sourceLang') ?? 'ko';
    final targetLang = prefs.getString('targetLang') ?? 'ja';
    final savedMode = prefs.getString('mode');
    final normalizedMode = _normalizeMode(savedMode);
    if (savedMode != null && savedMode != normalizedMode) {
      unawaited(prefs.setString('mode', normalizedMode));
    }
    final savedDisplayMode = prefs.getString('displayMode');
    final normalizedDisplayMode = _normalizeDisplayMode(savedDisplayMode);
    if (savedDisplayMode != null && savedDisplayMode != normalizedDisplayMode) {
      unawaited(prefs.setString('displayMode', normalizedDisplayMode));
    }
    setState(() {
      _sourceLang = sourceLang;
      _targetLang = targetLang;
      _refreshLanguageDerivedFields();
      _displayMode = normalizedDisplayMode;
      _ttsSourceEnabled = prefs.getBool('ttsSource') ?? false;
      _ttsTargetEnabled = prefs.getBool('ttsTarget') ?? false;
      _liveTranslateAudioEnabled =
          prefs.getBool('liveTranslateAudioEnabled') ?? false;
      _liveTranslateAudioRoute = _normalizeLiveTranslateAudioRoute(
        prefs.getString('liveTranslateAudioRoute'),
      );
      _liveTranslateAudioBoostGain = _normalizeLiveTranslateAudioBoostGain(
        prefs.getDouble('liveTranslateAudioBoostGain'),
      );
      _liveTranslateAudioBoostMs = _normalizeLiveTranslateAudioBoostMs(
        prefs.getInt('liveTranslateAudioBoostMs'),
      );
      _liveTranslateInputNoiseReduction =
          _normalizeLiveTranslateInputNoiseReduction(
            prefs.getString('liveTranslateInputNoiseReduction'),
          );
      _liveTranslateCaptionFontSize =
          (prefs.getDouble('liveTranslateCaptionFontSize') ?? 28)
              .clamp(16, 42)
              .toDouble();
      _ttsModel = prefs.getString('ttsModel') ?? 'gpt-4o-mini-tts';
      _ttsAudioRoute = _normalizeLiveTranslateAudioRoute(
        prefs.getString('ttsAudioRoute'),
      );
      _systemTtsEngine = prefs.getString('systemTtsEngine') == 'direct_web'
          ? 'direct_web'
          : 'flutter';
      _systemTtsSilentPrimeEnabled =
          prefs.getBool('systemTtsSilentPrimeEnabled') ?? false;
      _voiceSource = prefs.getString('voiceSource') ?? 'nova';
      _voiceTarget = prefs.getString('voiceTarget') ?? 'onyx';
      _fontSize = prefs.getDouble('fontSize') ?? 16;
      _secondaryFontSize = (prefs.getDouble('secondaryFontSize') ?? 11)
          .clamp(8, 22)
          .toDouble();
      _inputExpanded = prefs.getBool('inputExpanded') ?? false;
      _mode = normalizedMode;
      if (_isLiveTranslateMode) {
        _sourceLang = 'ko';
        _targetLang = 'ja';
        _refreshLanguageDerivedFields();
      }
      final savedModel = prefs.getString('model') ?? 'gpt-5.4-mini';
      _model = savedModel.startsWith('gpt-4.1') ? 'gpt-5.4-mini' : savedModel;
      final savedAiModel = prefs.getString('aiModel') ?? 'gpt-5.4-mini';
      _aiModel = savedAiModel.startsWith('gpt-4.1')
          ? 'gpt-5.4-mini'
          : savedAiModel;
      _aiPauseSeconds = prefs.getInt('aiPauseSeconds') ?? 5;
      _ttsSpeed = prefs.getDouble('ttsSpeed') ?? 1.0;
      _pauseSeconds = prefs.getInt('pauseSeconds') ?? 3;
      _toneMode = prefs.getString('toneMode') ?? 'normal';
      _realtimeVoice = _normalizeRealtimeVoice(
        prefs.getString('realtimeVoice'),
      );
      _realtimeModel = prefs.getString('realtimeModel') ?? 'gpt-realtime-2';
      _rtPostProcessMode = prefs.getString('rtPostProcessMode') ?? 'chat';
      _backTranslateSource = prefs.getBool('backTranslateSource') ?? true;
      _backTranslateTarget = prefs.getBool('backTranslateTarget') ?? true;
      _showPronunciation = prefs.getBool('showPronunciation') ?? false;
      _deleteConversationItems =
          prefs.getBool('deleteConversationItems') ?? true;
      _injectFewShot = prefs.getBool('injectFewShot') ?? true;
      _translationContext = prefs.getBool('translationContext') ?? false;
      _translationTemp = prefs.getDouble('translationTemp') ?? 0.3;
      _translationReasoningEffort = _normalizeReasoningEffort(
        prefs.getString('translationReasoningEffort'),
        fallback: 'low',
      );
      _translationBenchmarkEnabled =
          prefs.getBool('translationBenchmarkEnabled') ?? false;
      _sttModel = _normalizeSttModel(prefs.getString('sttModel'));
      if (_isAndroidSystemStt &&
          !_isAndroidSystemSttSilenceSetting(_pauseSeconds)) {
        _pauseSeconds = 3;
      }
      _sttBenchmarkEnabled = prefs.getBool('sttBenchmarkEnabled') ?? false;
      _androidSystemSttFastInterim =
          prefs.getBool('androidSystemSttFastInterim') ?? true;
      _realtimeSttDelay = _normalizeRealtimeSttDelay(
        prefs.getString('realtimeSttDelay'),
      );
      _sttPrompt = prefs.getString('sttPrompt') ?? '';
      _classifyTemp = prefs.getDouble('classifyTemp') ?? 0.1;
      _pronunciationTemp = prefs.getDouble('pronunciationTemp') ?? 0.3;
      _postProcessBackTranslationModel =
          prefs.getString('postProcessBackTranslationModel') ?? 'gpt-5.4-mini';
      _postProcessBackTranslationReasoningEffort = _normalizeReasoningEffort(
        prefs.getString('postProcessBackTranslationReasoningEffort'),
        fallback: 'low',
      );
      _postProcessPronunciationModel =
          prefs.getString('postProcessPronunciationModel') ?? 'gpt-5.4-mini';
      _postProcessPronunciationReasoningEffort = _normalizeReasoningEffort(
        prefs.getString('postProcessPronunciationReasoningEffort'),
        fallback: 'minimal',
      );
      _realtimeBackgroundGraceSeconds =
          prefs.getInt('realtimeBackgroundGraceSeconds') ?? 300;
      _pingPongTransportOptimized =
          prefs.getBool('pingPongTransportOptimized') ?? true;
      _pingPongWsBackgroundGraceSeconds =
          prefs.getInt('pingPongWsBackgroundGraceSeconds') ?? 300;
      _pingPongWebWsProxyUrl =
          prefs.getString('pingPongWebWsProxyUrl') ??
          _defaultPingPongWebWsProxyUrl;
      _noiseThreshold =
          prefs.getDouble('noiseThreshold') ?? (kIsWeb ? -60 : -30);
      _vadThreshold = prefs.getDouble('vadThreshold') ?? 0.9;
      _turnDetectionType = prefs.getString('turnDetectionType') ?? 'server_vad';
      _vadEagerness = prefs.getString('vadEagerness') ?? 'low';
      _silenceDurationMs = prefs.getInt('silenceDurationMs') ?? 500;
      _micLang = _sourceLang;
      _promptTemplates = promptTemplates;
    });
    _persistedSettings = _currentSettingsSnapshot();
    _prewarmTtsIfNeeded();
    if (widget.apiKey != 'test-key') {
      _prewarmPingPongTextWsIfNeeded(includePostProcess: true);
    }
  }

  void _saveSettings() {
    _settingsDirty = true;
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(
      const Duration(milliseconds: 350),
      _flushSettings,
    );
  }

  void _flushSettings() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = null;
    if (_settingsDirty || _settingsSaveFuture != null) {
      unawaited(_writeSettings());
    }
  }

  Future<void> _writeSettings() async {
    final activeWrite = _settingsSaveFuture;
    if (activeWrite != null) {
      _settingsSaveAgain = true;
      return activeWrite;
    }
    if (!_settingsDirty) return;

    _settingsDirty = false;
    final write = _persistSettings();
    _settingsSaveFuture = write;
    try {
      await write;
    } finally {
      _settingsSaveFuture = null;
      if (_settingsDirty || _settingsSaveAgain) {
        _settingsSaveAgain = false;
        await _writeSettings();
      }
    }
  }

  Future<void> _persistSettings() async {
    final prefs = await _prefs();
    final snapshot = _currentSettingsSnapshot();
    final writes = <Future<bool>>[];

    for (final entry in snapshot.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_persistedSettings[key] == value) continue;
      switch (value) {
        case final String stringValue:
          writes.add(prefs.setString(key, stringValue));
        case final bool boolValue:
          writes.add(prefs.setBool(key, boolValue));
        case final int intValue:
          writes.add(prefs.setInt(key, intValue));
        case final double doubleValue:
          writes.add(prefs.setDouble(key, doubleValue));
      }
    }

    if (writes.isNotEmpty) {
      await Future.wait(writes);
    }
    _persistedSettings = snapshot;
  }

  Map<String, Object> _currentSettingsSnapshot() {
    return {
      'sourceLang': _sourceLang,
      'targetLang': _targetLang,
      'displayMode': _displayMode,
      'ttsSource': _ttsSourceEnabled,
      'ttsTarget': _ttsTargetEnabled,
      'liveTranslateAudioEnabled': _liveTranslateAudioEnabled,
      'liveTranslateAudioRoute': _liveTranslateAudioRoute,
      'liveTranslateAudioBoostGain': _liveTranslateAudioBoostGain,
      'liveTranslateAudioBoostMs': _liveTranslateAudioBoostMs,
      'liveTranslateInputNoiseReduction': _liveTranslateInputNoiseReduction,
      'liveTranslateCaptionFontSize': _liveTranslateCaptionFontSize,
      'ttsModel': _ttsModel,
      'ttsAudioRoute': _ttsAudioRoute,
      'systemTtsEngine': _systemTtsEngine,
      'systemTtsSilentPrimeEnabled': _systemTtsSilentPrimeEnabled,
      'voiceSource': _voiceSource,
      'voiceTarget': _voiceTarget,
      'fontSize': _fontSize,
      'secondaryFontSize': _secondaryFontSize,
      'inputExpanded': _inputExpanded,
      'mode': _mode,
      'model': _model,
      'aiModel': _aiModel,
      'aiPauseSeconds': _aiPauseSeconds,
      'ttsSpeed': _ttsSpeed,
      'pauseSeconds': _pauseSeconds,
      'toneMode': _toneMode,
      'realtimeVoice': _realtimeVoice,
      'realtimeModel': _realtimeModel,
      'rtPostProcessMode': _rtPostProcessMode,
      'backTranslateSource': _backTranslateSource,
      'backTranslateTarget': _backTranslateTarget,
      'showPronunciation': _showPronunciation,
      'deleteConversationItems': _deleteConversationItems,
      'injectFewShot': _injectFewShot,
      'translationContext': _translationContext,
      'translationTemp': _translationTemp,
      'translationReasoningEffort': _translationReasoningEffort,
      'translationBenchmarkEnabled': _translationBenchmarkEnabled,
      'sttModel': _sttModel,
      'sttBenchmarkEnabled': _sttBenchmarkEnabled,
      'androidSystemSttFastInterim': _androidSystemSttFastInterim,
      'realtimeSttDelay': _realtimeSttDelay,
      'sttPrompt': _sttPrompt,
      'classifyTemp': _classifyTemp,
      'pronunciationTemp': _pronunciationTemp,
      'postProcessBackTranslationModel': _postProcessBackTranslationModel,
      'postProcessBackTranslationReasoningEffort':
          _postProcessBackTranslationReasoningEffort,
      'postProcessPronunciationModel': _postProcessPronunciationModel,
      'postProcessPronunciationReasoningEffort':
          _postProcessPronunciationReasoningEffort,
      'realtimeBackgroundGraceSeconds': _realtimeBackgroundGraceSeconds,
      'pingPongTransportOptimized': _pingPongTransportOptimized,
      'pingPongWsBackgroundGraceSeconds': _pingPongWsBackgroundGraceSeconds,
      'pingPongWebWsProxyUrl': _pingPongWebWsProxyUrl,
      'noiseThreshold': _noiseThreshold,
      'vadThreshold': _vadThreshold,
      'turnDetectionType': _turnDetectionType,
      'vadEagerness': _vadEagerness,
      'silenceDurationMs': _silenceDurationMs,
    };
  }

  void _schedulePromptSave(String key, String value) {
    _pendingPromptSaves[key] = value;
    _promptSaveTimers.remove(key)?.cancel();
    _promptSaveTimers[key] = Timer(
      const Duration(milliseconds: 500),
      () => _flushPromptSave(key),
    );
  }

  void _flushPromptSaves() {
    for (final key in List<String>.from(_promptSaveTimers.keys)) {
      _flushPromptSave(key);
    }
  }

  void _flushPromptSave(String key) {
    _promptSaveTimers.remove(key)?.cancel();
    final value = _pendingPromptSaves.remove(key);
    if (value == null) return;

    final previous = _promptSaveChains[key] ?? Future<void>.value();
    late final Future<void> chained;
    chained = previous
        .catchError((_) {})
        .then((_) async {
          final prefs = await _prefs();
          await AppPrompts.saveTemplate(key, value, prefs: prefs);
        })
        .whenComplete(() {
          if (_promptSaveChains[key] == chained) {
            _promptSaveChains.remove(key);
          }
        });
    _promptSaveChains[key] = chained;
    unawaited(chained);
  }

  void _cancelPromptSave(String key) {
    _promptSaveTimers.remove(key)?.cancel();
    _pendingPromptSaves.remove(key);
  }

  String _appLogText() {
    if (_appLogLines.isEmpty) return '아직 기록된 로그가 없습니다.';
    return _appLogLines.join('\n');
  }

  void _openAppLogViewer() {
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final logText = _appLogText();
          return AlertDialog(
            title: const Text('로그 보기'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.sizeOf(dialogContext).height * 0.62,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    logText,
                    style: const TextStyle(
                      color: Color(0xFFE5E7EB),
                      fontSize: 11,
                      height: 1.35,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await Clipboard.setData(ClipboardData(text: logText));
                  if (!dialogContext.mounted) return;
                  messenger?.showSnackBar(
                    const SnackBar(
                      behavior: SnackBarBehavior.floating,
                      duration: Duration(milliseconds: 900),
                      content: Text('로그 복사됨'),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('복사'),
              ),
              TextButton.icon(
                onPressed: () {
                  _appLogLines.clear();
                  setDialogState(() {});
                },
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('삭제'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          void updateSheetSetting(VoidCallback update) {
            update();
            setSheetState(() {});
            _saveSettings();
          }

          return SettingsSheet(
            mode: _mode,
            model: _model,
            realtimeModel: _realtimeModel,
            sourceLang: _sourceLang,
            targetLang: _targetLang,
            displayMode: _displayMode,
            ttsSourceEnabled: _ttsSourceEnabled,
            ttsTargetEnabled: _ttsTargetEnabled,
            liveTranslateAudioEnabled: _liveTranslateAudioEnabled,
            liveTranslateAudioRoute: _liveTranslateAudioRoute,
            liveTranslateAudioBoostGain: _liveTranslateAudioBoostGain,
            liveTranslateAudioBoostMs: _liveTranslateAudioBoostMs,
            liveTranslateInputNoiseReduction: _liveTranslateInputNoiseReduction,
            liveTranslateCaptionFontSize: _liveTranslateCaptionFontSize,
            ttsModel: _ttsModel,
            ttsAudioRoute: _ttsAudioRoute,
            systemTtsEngine: _systemTtsEngine,
            systemTtsSilentPrimeEnabled: _systemTtsSilentPrimeEnabled,
            voiceSource: _voiceSource,
            voiceTarget: _voiceTarget,
            fontSize: _fontSize,
            secondaryFontSize: _secondaryFontSize,
            ttsSpeed: _ttsSpeed,
            pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
            noiseThreshold: _noiseThreshold,
            vadThreshold: _vadThreshold,
            turnDetectionType: _turnDetectionType,
            vadEagerness: _vadEagerness,
            silenceDurationMs: _silenceDurationMs,
            realtimeBackgroundGraceSeconds: _realtimeBackgroundGraceSeconds,
            pingPongTransportOptimized: _pingPongTransportOptimized,
            pingPongWsBackgroundGraceSeconds: _pingPongWsBackgroundGraceSeconds,
            pingPongWebWsProxyUrl: _pingPongWebWsProxyUrl,
            toneMode: _toneMode,
            realtimeActive: _realtimeActive,
            realtimeVoice: _realtimeVoice,
            onRealtimeVoiceChanged: (v) {
              updateSheetSetting(() => _realtimeVoice = v);
            },
            aiModel: _aiModel,
            aiPauseSeconds: _aiPauseSeconds,
            onToneModeChanged: (v) {
              updateSheetSetting(() => _toneMode = v);
            },
            onAiModelChanged: (v) {
              updateSheetSetting(() => _aiModel = v);
            },
            onAiPauseSecondsChanged: (v) {
              updateSheetSetting(() => _aiPauseSeconds = v);
            },
            onModeChanged: (v) {
              if (v == _mode) return;
              _invalidateConversationWork();
              _discardPingPongTextWs();
              if (_realtimeActive) {
                _stopRealtime(
                  notify: false,
                  commitPendingRealtimeTranslate: false,
                );
              }
              setState(() {
                _mode = v;
                if (v == 'realtime_translate') {
                  _aiMode = false;
                  _sourceLang = 'ko';
                  _targetLang = 'ja';
                  _micLang = 'ko';
                  _refreshLanguageDerivedFields();
                }
              });
              setSheetState(() {});
              _saveSettings();
            },
            onModelChanged: (v) {
              updateSheetSetting(() {
                _model = v;
                _discardPingPongTextWs('translation');
              });
            },
            onRealtimeModelChanged: (v) {
              updateSheetSetting(() => _realtimeModel = v);
            },
            onSourceLangChanged: (v) {
              if (v == _sourceLang) return;
              _invalidateConversationWork();
              if (_realtimeActive) {
                _stopRealtime(
                  notify: false,
                  commitPendingRealtimeTranslate: false,
                );
              }
              setState(() {
                _sourceLang = v;
                _micLang = v;
                _refreshLanguageDerivedFields();
              });
              _discardRealtimePostProcessor();
              _discardPingPongTextWs();
              setSheetState(() {});
              _saveSettings();
            },
            onTargetLangChanged: (v) {
              if (v == _targetLang) return;
              _invalidateConversationWork();
              if (_realtimeActive) {
                _stopRealtime(
                  notify: false,
                  commitPendingRealtimeTranslate: false,
                );
              }
              setState(() {
                _targetLang = v;
                _refreshLanguageDerivedFields();
              });
              _discardRealtimePostProcessor();
              _discardPingPongTextWs();
              setSheetState(() {});
              _saveSettings();
            },
            onDisplayModeChanged: (v) {
              setState(() => _displayMode = v);
              setSheetState(() {});
              _saveSettings();
            },
            onTtsSourceChanged: (v) {
              _ttsSourceEnabled = v;
              setSheetState(() {});
              _saveSettings();
              _updateRealtimeAudioMute();
              if (v) _prewarmTtsIfNeeded();
            },
            onTtsTargetChanged: (v) {
              _ttsTargetEnabled = v;
              setSheetState(() {});
              _saveSettings();
              _updateRealtimeAudioMute();
              if (v) _prewarmTtsIfNeeded();
            },
            onLiveTranslateAudioEnabledChanged: (v) {
              _liveTranslateAudioEnabled = v;
              if (v) _warmUpLiveTranslateAudioIfNeeded();
              setSheetState(() {});
              _saveSettings();
              _updateRealtimeAudioMute();
            },
            onLiveTranslateAudioRouteChanged: (v) {
              _liveTranslateAudioRoute = _normalizeLiveTranslateAudioRoute(v);
              _warmUpLiveTranslateAudioIfNeeded();
              setSheetState(() {});
              _saveSettings();
              _updateRealtimeAudioMute();
            },
            onLiveTranslateAudioBoostGainChanged: (v) {
              _liveTranslateAudioBoostGain =
                  _normalizeLiveTranslateAudioBoostGain(v);
              _configureLiveTranslateAudioBoost();
              setSheetState(() {});
              _saveSettings();
            },
            onLiveTranslateAudioBoostMsChanged: (v) {
              _liveTranslateAudioBoostMs = _normalizeLiveTranslateAudioBoostMs(
                v,
              );
              _configureLiveTranslateAudioBoost();
              setSheetState(() {});
              _saveSettings();
            },
            onLiveTranslateInputNoiseReductionChanged: (v) {
              _liveTranslateInputNoiseReduction =
                  _normalizeLiveTranslateInputNoiseReduction(v);
              if (_realtimeActive && _isRealtimeTranslateMode) {
                _stopRealtime(
                  notify: false,
                  commitPendingRealtimeTranslate: false,
                );
              }
              setSheetState(() {});
              _saveSettings();
            },
            onLiveTranslateCaptionFontSizeChanged: (v) {
              setState(() => _liveTranslateCaptionFontSize = v);
              setSheetState(() {});
              _saveSettings();
            },
            onTtsModelChanged: (v) {
              updateSheetSetting(() {
                _ttsModel = v;
                _clearTtsAudioCache();
              });
              if (v == 'system-tts') _prewarmTtsIfNeeded();
            },
            onTtsAudioRouteChanged: (v) {
              updateSheetSetting(() {
                _ttsAudioRoute = _normalizeLiveTranslateAudioRoute(v);
              });
            },
            onSystemTtsEngineChanged: (v) {
              updateSheetSetting(() {
                _systemTtsEngine = v == 'direct_web' ? v : 'flutter';
              });
              _prewarmTtsIfNeeded();
            },
            onSystemTtsSilentPrimeEnabledChanged: (v) {
              updateSheetSetting(() {
                _systemTtsSilentPrimeEnabled = v;
              });
            },
            onVoiceSourceChanged: (v) {
              updateSheetSetting(() => _voiceSource = v);
            },
            onVoiceTargetChanged: (v) {
              updateSheetSetting(() => _voiceTarget = v);
            },
            onFontSizeChanged: (v) {
              setState(() => _fontSize = v);
              setSheetState(() {});
              _saveSettings();
            },
            onSecondaryFontSizeChanged: (v) {
              setState(() => _secondaryFontSize = v);
              setSheetState(() {});
              _saveSettings();
            },
            onTtsSpeedChanged: (v) {
              updateSheetSetting(() => _ttsSpeed = v);
            },
            onPauseSecondsChanged: (v) {
              updateSheetSetting(() => _pauseSeconds = v);
            },
            onNoiseThresholdChanged: (v) {
              updateSheetSetting(() => _noiseThreshold = v);
            },
            onVadThresholdChanged: (v) {
              updateSheetSetting(() => _vadThreshold = v);
              _applyTurnDetectionLive();
            },
            onTurnDetectionTypeChanged: (v) {
              updateSheetSetting(() => _turnDetectionType = v);
              _applyTurnDetectionLive();
            },
            onVadEagernessChanged: (v) {
              updateSheetSetting(() => _vadEagerness = v);
              _applyTurnDetectionLive();
            },
            onSilenceDurationMsChanged: (v) {
              updateSheetSetting(() => _silenceDurationMs = v);
              _applyTurnDetectionLive();
            },
            onRealtimeBackgroundGraceSecondsChanged: (v) {
              updateSheetSetting(() => _realtimeBackgroundGraceSeconds = v);
            },
            onPingPongTransportOptimizedChanged: (v) {
              updateSheetSetting(() {
                _pingPongTransportOptimized = v;
                if (!v) _discardPingPongTextWs();
              });
            },
            onPingPongWsBackgroundGraceSecondsChanged: (v) {
              updateSheetSetting(() => _pingPongWsBackgroundGraceSeconds = v);
            },
            onPingPongWebWsProxyUrlChanged: (v) {
              updateSheetSetting(() {
                _pingPongWebWsProxyUrl = v.trim();
                _discardPingPongTextWs();
              });
            },
            deleteConversationItems: _deleteConversationItems,
            onDeleteConversationItemsChanged: (v) {
              updateSheetSetting(() => _deleteConversationItems = v);
            },
            injectFewShot: _injectFewShot,
            onInjectFewShotChanged: (v) {
              updateSheetSetting(() => _injectFewShot = v);
            },
            translationContext: _translationContext,
            onTranslationContextChanged: (v) {
              updateSheetSetting(() {
                _translationContext = v;
                _discardPingPongTextWs('translation');
              });
            },
            translationTemp: _translationTemp,
            onTranslationTempChanged: (v) {
              updateSheetSetting(() {
                _translationTemp = v;
                _discardPingPongTextWs('translation');
              });
            },
            translationReasoningEffort: _translationReasoningEffort,
            onTranslationReasoningEffortChanged: (v) {
              updateSheetSetting(() {
                _translationReasoningEffort = v;
                _discardPingPongTextWs('translation');
              });
            },
            translationBenchmarkEnabled: _translationBenchmarkEnabled,
            onTranslationBenchmarkEnabledChanged: (v) {
              updateSheetSetting(() => _translationBenchmarkEnabled = v);
            },
            sttModel: _sttModel,
            onSttModelChanged: (v) {
              updateSheetSetting(() {
                _sttModel = v;
                if (_isAndroidSystemStt &&
                    !_isAndroidSystemSttSilenceSetting(_pauseSeconds)) {
                  _pauseSeconds = 3;
                }
              });
            },
            sttBenchmarkEnabled: _sttBenchmarkEnabled,
            onSttBenchmarkEnabledChanged: (v) {
              updateSheetSetting(() => _sttBenchmarkEnabled = v);
            },
            androidSystemSttFastInterim: _androidSystemSttFastInterim,
            onAndroidSystemSttFastInterimChanged: (v) {
              updateSheetSetting(() => _androidSystemSttFastInterim = v);
            },
            realtimeSttDelay: _realtimeSttDelay,
            onRealtimeSttDelayChanged: (v) {
              updateSheetSetting(() {
                _realtimeSttDelay = _normalizeRealtimeSttDelay(v);
              });
            },
            sttPrompt: _sttPrompt,
            onSttPromptChanged: (v) {
              updateSheetSetting(() => _sttPrompt = v);
            },
            classifyTemp: _classifyTemp,
            onClassifyTempChanged: (v) {
              updateSheetSetting(() => _classifyTemp = v);
            },
            pronunciationTemp: _pronunciationTemp,
            onPronunciationTempChanged: (v) {
              updateSheetSetting(() => _pronunciationTemp = v);
            },
            postProcessBackTranslationModel: _postProcessBackTranslationModel,
            onPostProcessBackTranslationModelChanged: (v) {
              updateSheetSetting(() {
                _postProcessBackTranslationModel = v;
                _discardPingPongTextWs('backTranslation');
              });
            },
            postProcessBackTranslationReasoningEffort:
                _postProcessBackTranslationReasoningEffort,
            onPostProcessBackTranslationReasoningEffortChanged: (v) {
              updateSheetSetting(() {
                _postProcessBackTranslationReasoningEffort = v;
                _discardPingPongTextWs('backTranslation');
              });
            },
            postProcessPronunciationModel: _postProcessPronunciationModel,
            onPostProcessPronunciationModelChanged: (v) {
              updateSheetSetting(() {
                _postProcessPronunciationModel = v;
                _discardPingPongTextWs('pronunciation');
              });
            },
            postProcessPronunciationReasoningEffort:
                _postProcessPronunciationReasoningEffort,
            onPostProcessPronunciationReasoningEffortChanged: (v) {
              updateSheetSetting(() {
                _postProcessPronunciationReasoningEffort = v;
                _discardPingPongTextWs('pronunciation');
              });
            },
            rtPostProcessMode: _rtPostProcessMode,
            onRtPostProcessModeChanged: (v) {
              _rtPostProcessMode = v;
              _discardRealtimePostProcessor();
              _refreshRealtimePostProcessorForSettings();
              setSheetState(() {});
              _saveSettings();
            },
            backTranslateSource: _backTranslateSource,
            backTranslateTarget: _backTranslateTarget,
            onBackTranslateSourceChanged: (v) {
              _backTranslateSource = v;
              _refreshRealtimePostProcessorForSettings();
              setSheetState(() {});
              _saveSettings();
            },
            onBackTranslateTargetChanged: (v) {
              _backTranslateTarget = v;
              _refreshRealtimePostProcessorForSettings();
              setSheetState(() {});
              _saveSettings();
            },
            showPronunciation: _showPronunciation,
            onShowPronunciationChanged: (v) {
              _showPronunciation = v;
              _discardRealtimePostProcessor();
              _refreshRealtimePostProcessorForSettings();
              setSheetState(() {});
              _saveSettings();
            },
            promptTemplates: _promptTemplates,
            onShowLogs: _openAppLogViewer,
            onPromptChanged: (key, value) {
              _promptTemplates = _updatedPromptTemplates(key, value);
              _discardPingPongTextWs();
              _schedulePromptSave(key, value);
              return Future.value();
            },
            onPromptReset: (key) async {
              _cancelPromptSave(key);
              final prefs = await _prefs();
              await AppPrompts.resetTemplate(key, prefs: prefs);
              if (!mounted) return;
              final templates = await AppPrompts.loadTemplates(prefs: prefs);
              if (!mounted) return;
              _promptRevision++;
              _renderedPromptCache.clear();
              _discardPingPongTextWs();
              if (key == AppPrompts.ttsInstructionsKey) {
                _ttsInstructionsRevision++;
                _clearTtsAudioCache();
              }
              setState(() => _promptTemplates = templates);
              setSheetState(() {});
            },
            onResetApiKey: () {
              Navigator.pop(context);
              _resetApiKey();
            },
          );
        },
      ),
    );
  }

  PromptTemplateSet _updatedPromptTemplates(String key, String value) {
    _promptRevision++;
    _renderedPromptCache.clear();
    if (key == AppPrompts.ttsInstructionsKey) {
      _ttsInstructionsRevision++;
      _clearTtsAudioCache();
    }
    switch (key) {
      case AppPrompts.translationSystemKey:
        return _promptTemplates.copyWith(translationSystem: value);
      case AppPrompts.assistantSystemKey:
        return _promptTemplates.copyWith(assistantSystem: value);
      case AppPrompts.ttsInstructionsKey:
        return _promptTemplates.copyWith(ttsInstructions: value);
      case AppPrompts.realtimeTranslationKey:
        return _promptTemplates.copyWith(realtimeTranslation: value);
      case AppPrompts.realtimeDirectionalKey:
        return _promptTemplates.copyWith(realtimeDirectional: value);
      case AppPrompts.postProcessKey:
        return _promptTemplates.copyWith(postProcess: value);
      default:
        return _promptTemplates;
    }
  }

  String _translationPrompt({
    required String sourceLang,
    required String targetLang,
  }) {
    final template = _promptTemplates.translationSystem;
    final tone = _tone;
    return _cachedRenderedPrompt(
      (
        kind: 'translation',
        sourceLang: sourceLang,
        targetLang: targetLang,
        sourceLangCode: '',
        targetLangCode: '',
        toneMode: _toneMode,
        revision: _promptRevision,
        hasContext: false,
      ),
      () => AppPrompts.translationSystem(
        PromptLanguagePair(sourceLang: sourceLang, targetLang: targetLang),
        tone: tone,
        template: template,
      ),
    );
  }

  String _assistantPrompt({required bool hasContext}) {
    final template = _promptTemplates.assistantSystem;
    return _cachedRenderedPrompt(
      (
        kind: 'assistant',
        sourceLang: '',
        targetLang: '',
        sourceLangCode: '',
        targetLangCode: '',
        toneMode: '',
        revision: _promptRevision,
        hasContext: hasContext,
      ),
      () => AppPrompts.assistantSystem(
        hasContext: hasContext,
        template: template,
      ),
    );
  }

  String get _ttsPrompt {
    final template = _promptTemplates.ttsInstructions;
    return _cachedRenderedPrompt((
      kind: 'tts',
      sourceLang: '',
      targetLang: '',
      sourceLangCode: '',
      targetLangCode: '',
      toneMode: '',
      revision: _promptRevision,
      hasContext: false,
    ), () => AppPrompts.ttsInstructions(template: template));
  }

  String _directionalPrompt({
    required String inputLang,
    required String outputLang,
  }) {
    final template = _promptTemplates.realtimeDirectional;
    final tone = _tone;
    return _cachedRenderedPrompt(
      (
        kind: 'directional',
        sourceLang: inputLang,
        targetLang: outputLang,
        sourceLangCode: '',
        targetLangCode: '',
        toneMode: _toneMode,
        revision: _promptRevision,
        hasContext: false,
      ),
      () => AppPrompts.realtimeDirectional(
        PromptLanguagePair(sourceLang: inputLang, targetLang: outputLang),
        tone: tone,
        template: template,
      ),
    );
  }

  String _realtimePrompt() {
    final template = _promptTemplates.realtimeTranslation;
    final tone = _tone;
    return _cachedRenderedPrompt(
      (
        kind: 'realtime',
        sourceLang: _sourceLangName,
        targetLang: _targetLangName,
        sourceLangCode: _sourceLang,
        targetLangCode: _targetLang,
        toneMode: _toneMode,
        revision: _promptRevision,
        hasContext: false,
      ),
      () => AppPrompts.realtimeTranslation(
        PromptLanguagePair(
          sourceLang: _sourceLangName,
          targetLang: _targetLangName,
        ),
        tone: tone,
        template: template,
        sourceLangCode: _sourceLang,
        targetLangCode: _targetLang,
      ),
    );
  }

  String _cachedRenderedPrompt(
    _RenderedPromptCacheKey key,
    String Function() builder,
  ) {
    final cached = _renderedPromptCache.remove(key);
    if (cached != null) {
      _renderedPromptCache[key] = cached;
      return cached;
    }

    final value = builder();
    _renderedPromptCache[key] = value;
    while (_renderedPromptCache.length > _renderedPromptCacheMaxEntries) {
      _renderedPromptCache.remove(_renderedPromptCache.keys.first);
    }
    return value;
  }

  static const _micHints = {
    'ko': '말하기',
    'ja': '話す',
    'zh': '说话',
    'en': 'Speak',
    'de': 'Sprechen',
    'fr': 'Parler',
    'vi': 'Nói',
    'ru': 'Говорить',
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
  static const _inputLabels = {
    'ko': '입력창',
    'ja': '入力欄',
    'zh': '输入框',
    'en': 'Input',
    'de': 'Eingabe',
    'fr': 'Saisie',
    'vi': 'Ô nhập',
    'ru': 'Ввод',
  };
  static const _realtimeJunkLowerPhrases = [
    'output nothing',
    'no output',
    'silence',
    'silent',
    'say anything',
    'completely silent',
  ];

  static String _buildTextInputHintFor(String sourceLang, String targetLang) {
    final sourceLabel = _inputLabels[sourceLang] ?? '입력창';
    final targetLabel = _inputLabels[targetLang] ?? 'Input';
    if (sourceLabel == targetLabel) return sourceLabel;
    return '$sourceLabel ($targetLabel)';
  }

  String _directionCode(String from, String to) =>
      '$from'
      '2'
      '$to';

  void _refreshLanguageDerivedFields() {
    final sourceLang = getLangByCode(_sourceLang);
    final targetLang = getLangByCode(_targetLang);
    _sourceLangName = sourceLang.name;
    _targetLangName = targetLang.name;
    _sourceToTargetDirection = _directionCode(_sourceLang, _targetLang);
    _targetToSourceDirection = _directionCode(_targetLang, _sourceLang);
    _textInputHint = _buildTextInputHintFor(_sourceLang, _targetLang);
    _rtPostProcessPairPayloadSegment = _buildRtPostProcessPairPayloadSegment(
      sourceLang: _sourceLang,
      sourceLangName: _sourceLangName,
      targetLang: _targetLang,
      targetLangName: _targetLangName,
    );
  }

  String _langNameForCode(String code) {
    if (code == _sourceLang) return _sourceLangName;
    if (code == _targetLang) return _targetLangName;
    return getLangByCode(code).name;
  }

  String? _detectLang(String text) {
    // Detect by unicode ranges. Returns null if undetectable (Latin etc.)
    var ko = 0;
    var ja = 0;
    var zh = 0;
    var ru = 0;
    var scriptRunes = 0;
    for (final ch in text.runes) {
      var matchedScript = false;
      if ((ch >= 0xAC00 && ch <= 0xD7AF) ||
          (ch >= 0x1100 && ch <= 0x11FF) ||
          (ch >= 0x3130 && ch <= 0x318F)) {
        ko++;
        matchedScript = true;
      }
      if ((ch >= 0x3040 && ch <= 0x309F) || (ch >= 0x30A0 && ch <= 0x30FF)) {
        ja++;
        matchedScript = true;
      }
      if (ch >= 0x4E00 && ch <= 0x9FFF) {
        zh++;
        ja++;
        matchedScript = true;
      }
      if ((ch >= 0x0400 && ch <= 0x04FF)) {
        ru++;
        matchedScript = true;
      }
      if (matchedScript && ++scriptRunes >= 96) {
        break;
      }
    }

    var bestCode = '';
    var bestScore = 0;
    if (ko > bestScore) {
      bestCode = 'ko';
      bestScore = ko;
    }
    if (ja > bestScore) {
      bestCode = 'ja';
      bestScore = ja;
    }
    if (zh > bestScore) {
      bestCode = 'zh';
      bestScore = zh;
    }
    if (ru > bestScore) {
      bestCode = 'ru';
      bestScore = ru;
    }
    return bestScore == 0 ? null : bestCode;
  }

  bool _isRealtimeJunkOutput(String outputText) {
    if (outputText.isEmpty) return true;
    if (outputText.startsWith('(') && outputText.endsWith(')')) return true;
    if (outputText.contains('침묵') || outputText.contains('何も出力')) {
      return true;
    }

    final lower = outputText.toLowerCase();
    for (final phrase in _realtimeJunkLowerPhrases) {
      if (lower.contains(phrase)) return true;
    }
    return false;
  }

  bool _isDuplicateRealtimeOutput(String outputText) {
    return _messages.isNotEmpty &&
        !_messages.last.isAI &&
        _messages.last.translated == outputText;
  }

  bool _isBenignRealtimeError(Object? message) {
    return message?.toString().contains('no active response') ?? false;
  }

  void _scrollToBottom({bool settle = false}) {
    if (!_scrollToBottomScheduled) {
      _scrollToBottomScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottomScheduled = false;
        _animateChatControllersToBottom();
      });
    }
    if (!settle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (_disposed) return;
        _animateChatControllersToBottom();
      });
    });
  }

  void _animateChatControllersToBottom() {
    _animateControllerToBottom(_myScrollController);
    _animateControllerToBottom(_mirrorScrollController);
  }

  bool _isNearBottom(ScrollController controller) {
    if (!controller.hasClients) return false;
    final position = controller.position;
    return position.maxScrollExtent - position.pixels <= 48;
  }

  bool _shouldKeepChatAtBottom() {
    final myHasClients = _myScrollController.hasClients;
    final mirrorHasClients = _mirrorScrollController.hasClients;
    if (!myHasClients && !mirrorHasClients) return true;
    return _isNearBottom(_myScrollController) ||
        _isNearBottom(_mirrorScrollController);
  }

  void _animateControllerToBottom(ScrollController controller) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final delta = position.maxScrollExtent - position.pixels;
    if (delta <= 2) return;
    unawaited(
      controller.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  void _setRealtimeStatus(String text, String mirrorText) {
    if (_interimText == text && _mirrorInterimText == mirrorText) return;
    _setInterimTextPair(text, mirrorText);
  }

  void _clearRealtimeStatus() {
    if (_interimText.isEmpty && _mirrorInterimText.isEmpty) return;
    _setInterimTextPair('', '');
  }

  bool _isPostProcessAnchorCurrent(int index, ChatMessage anchor) {
    if (!mounted || index < 0 || index >= _messages.length) return false;
    final current = _messages[index];
    return identical(current, anchor) ||
        (current.translated == anchor.translated &&
            current.direction == anchor.direction &&
            current.turnId == anchor.turnId &&
            current.isAI == anchor.isAI);
  }

  bool _isConversationCurrent(int generation) {
    return generation == _conversationGeneration;
  }

  void _invalidateConversationWork({bool resetProcessing = true}) {
    _conversationGeneration++;
    _translationQueue = Future.value();
    _realtimeInputItemMessageIndex.clear();
    _retryablePingPongTurnIds.clear();
    if (resetProcessing) {
      _processingToken++;
      _isProcessing = false;
    }
  }

  void _enqueueTranslation(
    String text, {
    String? forceDirection,
    int? generation,
    Stopwatch? timing,
    String? draftTurnId,
  }) {
    if (text.isEmpty) return;
    final requestGeneration = generation ?? _conversationGeneration;
    final previous = _translationQueue;
    late final Future<void> queued;
    queued = previous
        .catchError((_) {})
        .then((_) async {
          if (!mounted || !_isConversationCurrent(requestGeneration)) return;
          await _handleTranslation(
            text,
            forceDirection: forceDirection,
            generation: requestGeneration,
            timing: timing,
            draftTurnId: draftTurnId,
          );
        })
        .whenComplete(() {
          if (_translationQueue == queued) {
            _translationQueue = Future.value();
          }
        });
    _translationQueue = queued;
    unawaited(queued);
  }

  List<Map<String, String>> _recentTranslationContext(
    int limit, {
    String? excludeTurnId,
  }) {
    final start = _messages.length > limit ? _messages.length - limit : 0;
    final context = <Map<String, String>>[];
    for (var i = start; i < _messages.length; i++) {
      if (excludeTurnId != null && _messages[i].turnId == excludeTurnId) {
        continue;
      }
      context.add(_messages[i].translationContextEntry);
    }
    return context;
  }

  String _recentAssistantContextText(int limit) {
    final start = _messages.length > limit ? _messages.length - limit : 0;
    final buffer = StringBuffer();
    for (var i = start; i < _messages.length; i++) {
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.write(_messages[i].assistantContextText);
    }
    return buffer.toString();
  }

  Future<Map<String, String?>?> _tryRunTranslationBenchmark(
    String text, {
    required String sourceLang,
    required String targetLang,
    required String selectedModel,
    required ToneMode tone,
    required double temperature,
    required String? reasoningEffort,
    required String systemPrompt,
    List<Map<String, String>>? context,
    Stopwatch? timing,
  }) async {
    if (!_translationBenchmarkEnabled) return null;
    const models = ['gpt-5.4-nano', 'gpt-5.4-mini'];
    if (!models.contains(selectedModel)) return null;

    _logTranslationBenchmark(
      () =>
          'start selected=$selectedModel source=$sourceLang target=$targetLang '
          'chars=${text.length} context=${context?.length ?? 0} '
          'reasoning=${reasoningEffort ?? 'omit'} temp=$temperature',
    );
    if (timing != null) _logPingPongTiming('translation_request_sent', timing);
    final requestClock = Stopwatch()..start();
    final futures = <String, Future<_TranslationBenchmarkResult>>{
      for (final model in models)
        model: _runTranslationBenchmarkModel(
          text,
          sourceLang: sourceLang,
          targetLang: targetLang,
          model: model,
          tone: tone,
          temperature: temperature,
          reasoningEffort: reasoningEffort,
          systemPrompt: systemPrompt,
          context: context,
        ),
    };

    Future<({_TranslationBenchmarkResult? result, Object? error})> settle(
      Future<_TranslationBenchmarkResult> future,
    ) {
      return future
          .then<({_TranslationBenchmarkResult? result, Object? error})>(
            (result) => (result: result, error: null),
            onError: (Object error) => (result: null, error: error),
          );
    }

    unawaited(
      Future.wait([for (final model in models) settle(futures[model]!)]).then((
        settled,
      ) {
        final results = <String, _TranslationBenchmarkResult>{};
        for (var i = 0; i < models.length; i++) {
          final model = models[i];
          final settledItem = settled[i];
          final result = settledItem.result;
          if (result == null) {
            _logTranslationBenchmark(() => '$model error=${settledItem.error}');
            continue;
          }
          results[model] = result;
          _logTranslationBenchmark(
            () =>
                '$model done=${result.doneMs}ms chars=${result.translated.length} '
                'result=${jsonEncode(result.translated)}',
          );
        }

        final nano = results['gpt-5.4-nano'];
        final mini = results['gpt-5.4-mini'];
        if (nano != null && mini != null) {
          final faster = nano.doneMs <= mini.doneMs
              ? 'gpt-5.4-nano'
              : 'gpt-5.4-mini';
          _logTranslationBenchmark(
            () =>
                'winner=$faster total=${requestClock.elapsedMilliseconds}ms '
                'deltaDone=${(mini.doneMs - nano.doneMs).abs()}ms '
                'sameText=${nano.translated.trim() == mini.translated.trim()}',
          );
        }
      }),
    );

    try {
      final result = await futures[selectedModel]!;
      if (timing != null) _logPingPongTiming('translation_done', timing);
      _logTranslationBenchmark(
        () =>
            'selected=$selectedModel returned=${result.doneMs}ms '
            'chars=${result.translated.length}',
      );
      return {'translated': result.translated};
    } catch (error) {
      _logTranslationBenchmark(() => '$selectedModel selectedError=$error');
      return null;
    }
  }

  Future<_TranslationBenchmarkResult> _runTranslationBenchmarkModel(
    String text, {
    required String sourceLang,
    required String targetLang,
    required String model,
    required ToneMode tone,
    required double temperature,
    required String? reasoningEffort,
    required String systemPrompt,
    List<Map<String, String>>? context,
  }) async {
    final clock = Stopwatch()..start();
    final result = await _openai.translate(
      text,
      sourceLang: sourceLang,
      targetLang: targetLang,
      model: model,
      tone: tone,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      systemPrompt: systemPrompt,
      context: context,
    );
    return (
      model: model,
      translated: result['translated'] ?? '',
      doneMs: clock.elapsedMilliseconds,
    );
  }

  Future<Map<String, String?>> _translateForPingPong(
    String text, {
    required String sourceLang,
    required String targetLang,
    required String model,
    required ToneMode tone,
    required double temperature,
    required String? reasoningEffort,
    required String systemPrompt,
    List<Map<String, String>>? context,
    Stopwatch? timing,
    ValueChanged<String>? onPartialTranslated,
  }) async {
    final benchmarkResult = await _tryRunTranslationBenchmark(
      text,
      sourceLang: sourceLang,
      targetLang: targetLang,
      selectedModel: model,
      tone: tone,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      systemPrompt: systemPrompt,
      context: context,
      timing: timing,
    );
    if (benchmarkResult != null) return benchmarkResult;

    final streamedTranslation = StringBuffer();
    final wsText = await _tryPingPongWsText(
      purpose: 'translation',
      model: model,
      instructions: systemPrompt,
      text: text,
      context: context ?? const [],
      jsonObject: true,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      maxOutputTokens: 512,
      timeout: const Duration(seconds: 20),
      timing: timing,
      timingPrefix: 'translation',
      onTextDelta: onPartialTranslated == null
          ? null
          : (delta) {
              streamedTranslation.write(delta);
              final partial = _partialJsonStringField(
                streamedTranslation.toString(),
                'translated',
              ).replaceAll(_whitespacePattern, ' ').trim();
              if (partial.isNotEmpty) onPartialTranslated(partial);
            },
    );
    if (wsText != null) {
      try {
        final decoded = jsonDecode(wsText) as Map<String, dynamic>;
        final translated = decoded['translated']?.toString() ?? '';
        _logPingPongWs(
          () => 'translation.result source=ws chars=${translated.length}',
        );
        return {'translated': translated};
      } catch (error) {
        _logPingPongWs(
          () =>
              'translation.ws_parse_error chars=${wsText.length} '
              'error=$error',
        );
        _discardPingPongTextWs('translation');
      }
    } else {
      _logPingPongWs(() => 'translation.fallback source=rest reason=ws_null');
    }

    if (timing != null) {
      _logPingPongTiming('translation_rest_request_sent', timing);
    }
    final result = await _openai.translate(
      text,
      sourceLang: sourceLang,
      targetLang: targetLang,
      model: model,
      tone: tone,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      systemPrompt: systemPrompt,
      context: context,
    );
    if (timing != null) _logPingPongTiming('translation_done', timing);
    _logPingPongWs(
      () =>
          'translation.result source=rest chars=${result['translated']?.length ?? 0}',
    );
    return result;
  }

  String _partialJsonStringField(String raw, String field) {
    final key = '"$field"';
    final keyIndex = raw.indexOf(key);
    if (keyIndex < 0) return '';
    final colonIndex = raw.indexOf(':', keyIndex + key.length);
    if (colonIndex < 0) return '';
    final quoteIndex = raw.indexOf('"', colonIndex + 1);
    if (quoteIndex < 0) return '';

    final buffer = StringBuffer();
    var escaping = false;
    for (var i = quoteIndex + 1; i < raw.length; i++) {
      final char = raw[i];
      if (escaping) {
        switch (char) {
          case '"':
          case '\\':
          case '/':
            buffer.write(char);
            break;
          case 'b':
            buffer.write('\b');
            break;
          case 'f':
            buffer.write('\f');
            break;
          case 'n':
            buffer.write('\n');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case 't':
            buffer.write('\t');
            break;
          case 'u':
            if (i + 4 < raw.length) {
              final hex = raw.substring(i + 1, i + 5);
              final rune = int.tryParse(hex, radix: 16);
              if (rune != null) {
                buffer.writeCharCode(rune);
                i += 4;
              }
            }
            break;
          default:
            buffer.write(char);
        }
        escaping = false;
        continue;
      }
      if (char == '\\') {
        escaping = true;
        continue;
      }
      if (char == '"') break;
      buffer.write(char);
    }
    return buffer.toString();
  }

  Future<void> _handleTranslation(
    String text, {
    String? forceDirection,
    int? generation,
    Stopwatch? timing,
    String? draftTurnId,
  }) async {
    final requestGeneration = generation ?? _conversationGeneration;
    if (text.isEmpty ||
        _isProcessing ||
        !_isConversationCurrent(requestGeneration)) {
      return;
    }
    final processingToken = ++_processingToken;
    setState(() => _isProcessing = true);

    // forceDirection: 'source2target' or 'target2source'
    // Auto-detect based on text content
    final direction = forceDirection ?? 'source2target';
    final isSourceToTarget = direction == 'source2target';
    final msgDir = isSourceToTarget
        ? _sourceToTargetDirection
        : _targetToSourceDirection;
    final activeDraftTurnId = draftTurnId ?? 'pp-$processingToken';
    int? msgIndex = draftTurnId == null
        ? null
        : _messages.lastIndexWhere((message) => message.turnId == draftTurnId);
    if (msgIndex != null && msgIndex < 0) msgIndex = null;
    ChatMessage? msgAnchor;
    var lastDraftTranslation = '';

    void upsertTranslationDraft(String candidate) {
      final nextTranslated = candidate
          .replaceAll(_whitespacePattern, ' ')
          .trim();
      if (nextTranslated.isEmpty ||
          nextTranslated == lastDraftTranslation ||
          !mounted ||
          !_isConversationCurrent(requestGeneration)) {
        return;
      }
      lastDraftTranslation = nextTranslated;
      final draft = ChatMessage(
        original: text,
        translated: nextTranslated,
        direction: msgDir,
        turnId: activeDraftTurnId,
      );
      final keepAtBottom = _shouldKeepChatAtBottom();
      setState(() {
        final index = msgIndex;
        if (index != null &&
            index >= 0 &&
            index < _messages.length &&
            _messages[index].turnId == activeDraftTurnId) {
          _messages[index] = draft;
        } else {
          msgIndex = _messages.length;
          _messages.add(draft);
        }
        msgAnchor = draft;
        _setInterimTextPair('', '');
      });
      if (keepAtBottom) _scrollToBottom();
    }

    String translated = '';
    try {
      final srcName = _sourceLangName;
      final tgtName = _targetLangName;
      final inputLangName = isSourceToTarget ? srcName : tgtName;
      final outputLangName = isSourceToTarget ? tgtName : srcName;
      final outputLangCode = isSourceToTarget ? _targetLang : _sourceLang;
      final backTranslationLangCode = isSourceToTarget
          ? _sourceLang
          : _targetLang;
      final shouldPlayTts = isSourceToTarget
          ? _ttsTargetEnabled
          : _ttsSourceEnabled;
      final outputVoice = isSourceToTarget ? _voiceTarget : _voiceSource;
      // direction determines source→target or target→source
      // Build conversation context if enabled
      List<Map<String, String>>? ctx;
      if (_translationContext && _messages.isNotEmpty) {
        ctx = _recentTranslationContext(6, excludeTurnId: activeDraftTurnId);
      }

      _primeSystemTtsForOutput(
        outputLangCode,
        outputVoice,
        enabled: shouldPlayTts,
      );
      _applyInterimText('$text · 번역 중...', mirrorText: '$text · 翻訳中...');
      final result = await _translateForPingPong(
        text,
        sourceLang: inputLangName,
        targetLang: outputLangName,
        model: _model,
        tone: _tone,
        temperature: _translationTemp,
        reasoningEffort: _translationReasoningEffort,
        systemPrompt: _translationPrompt(
          sourceLang: inputLangName,
          targetLang: outputLangName,
        ),
        context: ctx,
        timing: timing,
        onPartialTranslated: upsertTranslationDraft,
      );
      if (!mounted || !_isConversationCurrent(requestGeneration)) return;
      translated = result['translated'] ?? '';
      _retryablePingPongTurnIds.remove(activeDraftTurnId);
      final msg = ChatMessage(
        original: text,
        translated: translated,
        backTranslation: null,
        direction: msgDir,
        turnId: activeDraftTurnId,
      );

      if (mounted) {
        setState(() {
          final index = msgIndex;
          if (index != null &&
              index >= 0 &&
              index < _messages.length &&
              _messages[index].turnId == activeDraftTurnId) {
            _messages[index] = msg;
          } else {
            msgIndex = _messages.length;
            _messages.add(msg);
          }
          msgAnchor = msg;
          _setInterimTextPair('', '');
        });
        _scrollToBottom();
        if (timing != null) {
          _logPingPongTiming('translation_bubble_ready', timing);
        }

        // TTS immediately after showing translation (non-blocking)
        if (translated.isNotEmpty) {
          if (shouldPlayTts) {
            _playOpenAITTS(
              translated,
              outputLangCode,
              outputVoice,
              timing: timing,
            );
          } else if (timing != null) {
            _logPingPongTiming('tts_disabled', timing);
          }
        }
      }

      // Async back-translation for verification (per-language setting)
      final wantBT = isSourceToTarget
          ? _backTranslateTarget
          : _backTranslateSource;
      if (translated.isNotEmpty &&
          mounted &&
          (wantBT || _showPronunciation) &&
          _isConversationCurrent(requestGeneration)) {
        final postProcessIndex = msgIndex;
        final postProcessAnchor = msgAnchor;
        if (postProcessIndex == null || postProcessAnchor == null) return;
        unawaited(
          _postProcessPingPongMessage(
            msgIndex: postProcessIndex,
            msg: postProcessAnchor,
            translated: translated,
            outputLangCode: outputLangCode,
            backTranslationLangCode: backTranslationLangCode,
            needBackTranslation: wantBT,
            requestGeneration: requestGeneration,
          ).catchError((_) {}),
        );
      }
    } catch (e) {
      if (mounted && _isConversationCurrent(requestGeneration)) {
        _showError(e.toString());
      }
    } finally {
      if (mounted && _processingToken == processingToken) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _postProcessPingPongMessage({
    required int msgIndex,
    required ChatMessage msg,
    required String translated,
    required String outputLangCode,
    required String backTranslationLangCode,
    required bool needBackTranslation,
    required int requestGeneration,
    bool placeBackTranslationInOriginal = false,
    bool forceScrollOnUpdate = false,
  }) async {
    if (!needBackTranslation && !_showPronunciation) return;

    _logPingPongPostProcess(
      () =>
          'start idx=$msgIndex bt=$needBackTranslation '
          'pron=$_showPronunciation translatedChars=${translated.length}',
    );
    final tasks = <Future<void>>[];
    Future<String?>? backTranslationFuture;
    if (_canUsePingPongWs) {
      if (needBackTranslation) {
        unawaited(
          _ensurePingPongTextWs(
            'backTranslation',
          ).start().catchError((Object _) {}),
        );
      }
      if (_showPronunciation) {
        unawaited(
          _ensurePingPongTextWs(
            'pronunciation',
          ).start().catchError((Object _) {}),
        );
      }
    }

    if (needBackTranslation) {
      backTranslationFuture = (() async {
        final clock = Stopwatch()..start();
        _logPingPongPostProcess(
          () =>
              'bt.start idx=$msgIndex model=$_postProcessBackTranslationModel '
              'target=$backTranslationLangCode',
        );
        if (!_isConversationCurrent(requestGeneration) ||
            !_isPostProcessAnchorCurrent(msgIndex, msg)) {
          _logPingPongPostProcess(() => 'bt.skip idx=$msgIndex reason=stale');
          return null;
        }
        String? candidate;
        try {
          candidate = await _realtimeBackTranslate(
            output: translated,
            outputLangCode: outputLangCode,
            targetLangCode: backTranslationLangCode,
          );
        } catch (e) {
          _logPingPongPostProcess(
            () =>
                'bt.error idx=$msgIndex elapsed=${clock.elapsedMilliseconds}ms '
                'error=$e',
          );
          return null;
        }
        if (candidate == null || candidate.isEmpty) {
          _logPingPongPostProcess(
            () =>
                'bt.empty idx=$msgIndex elapsed=${clock.elapsedMilliseconds}ms',
          );
          return null;
        }
        if (!_backTranslationLooksCompatible(
          candidate,
          backTranslationLangCode,
        )) {
          final rejectedCandidate = candidate;
          _logPingPongPostProcess(
            () =>
                'bt.rejected idx=$msgIndex target=$backTranslationLangCode '
                'chars=${rejectedCandidate.length} '
                'elapsed=${clock.elapsedMilliseconds}ms',
          );
          return null;
        }
        final acceptedCandidate = candidate;
        _applyPostProcessMessageUpdate(
          msgIndex: msgIndex,
          anchor: msg,
          requestGeneration: requestGeneration,
          original: placeBackTranslationInOriginal ? acceptedCandidate : null,
          backTranslation: placeBackTranslationInOriginal
              ? null
              : acceptedCandidate,
          forceScroll: forceScrollOnUpdate,
        );
        _logPingPongPostProcess(
          () =>
              'bt.done idx=$msgIndex chars=${acceptedCandidate.length} '
              'elapsed=${clock.elapsedMilliseconds}ms',
        );
        return acceptedCandidate;
      })();
      tasks.add(backTranslationFuture.then<void>((_) {}));
    }

    if (_showPronunciation) {
      tasks.add(() async {
        final clock = Stopwatch()..start();
        _logPingPongPostProcess(
          () =>
              'pron.start idx=$msgIndex model=$_postProcessPronunciationModel',
        );
        String? textToPronounce;
        if (outputLangCode != 'ko' && outputLangCode != 'en') {
          textToPronounce = translated;
        } else if (backTranslationFuture != null &&
            backTranslationLangCode != 'ko' &&
            backTranslationLangCode != 'en') {
          textToPronounce = await backTranslationFuture;
        }
        if (textToPronounce == null || textToPronounce.isEmpty) {
          _logPingPongPostProcess(
            () =>
                'pron.skip idx=$msgIndex reason=no_source '
                'elapsed=${clock.elapsedMilliseconds}ms',
          );
          return;
        }
        if (!_isConversationCurrent(requestGeneration) ||
            !_isPostProcessAnchorCurrent(msgIndex, msg)) {
          _logPingPongPostProcess(() => 'pron.skip idx=$msgIndex reason=stale');
          return;
        }
        String? pronunciation;
        try {
          pronunciation = await _hangulPronunciation(textToPronounce);
        } catch (e) {
          _logPingPongPostProcess(
            () =>
                'pron.error idx=$msgIndex elapsed=${clock.elapsedMilliseconds}ms '
                'error=$e',
          );
          return;
        }
        if (pronunciation == null || pronunciation.isEmpty) {
          _logPingPongPostProcess(
            () =>
                'pron.empty idx=$msgIndex elapsed=${clock.elapsedMilliseconds}ms',
          );
          return;
        }
        final acceptedPronunciation = pronunciation;
        _applyPostProcessMessageUpdate(
          msgIndex: msgIndex,
          anchor: msg,
          requestGeneration: requestGeneration,
          pronunciation: acceptedPronunciation,
          forceScroll: forceScrollOnUpdate,
        );
        _logPingPongPostProcess(
          () =>
              'pron.done idx=$msgIndex chars=${acceptedPronunciation.length} '
              'elapsed=${clock.elapsedMilliseconds}ms',
        );
      }());
    }

    if (tasks.isNotEmpty) await Future.wait(tasks);
    _logPingPongPostProcess(() => 'done idx=$msgIndex tasks=${tasks.length}');
  }

  void _applyPostProcessMessageUpdate({
    required int msgIndex,
    required ChatMessage anchor,
    required int requestGeneration,
    String? original,
    String? backTranslation,
    String? pronunciation,
    bool forceScroll = false,
  }) {
    if (!_isConversationCurrent(requestGeneration) ||
        !_isPostProcessAnchorCurrent(msgIndex, anchor) ||
        ((original == null || original.isEmpty) &&
            (backTranslation == null || backTranslation.isEmpty) &&
            (pronunciation == null || pronunciation.isEmpty))) {
      return;
    }

    final current = _messages[msgIndex];
    final nextOriginal = original != null && original.isNotEmpty
        ? original
        : current.original;
    final nextBackTranslation =
        backTranslation != null && backTranslation.isNotEmpty
        ? backTranslation
        : current.backTranslation;
    final nextPronunciation = pronunciation != null && pronunciation.isNotEmpty
        ? pronunciation
        : current.pronunciation;
    if (nextOriginal == current.original &&
        nextBackTranslation == current.backTranslation &&
        nextPronunciation == current.pronunciation) {
      return;
    }

    final keepAtBottom = forceScroll || _shouldKeepChatAtBottom();
    setState(() {
      if (_isPostProcessAnchorCurrent(msgIndex, anchor)) {
        final latest = _messages[msgIndex];
        _messages[msgIndex] = ChatMessage(
          original: nextOriginal,
          translated: latest.translated,
          backTranslation: nextBackTranslation,
          pronunciation: nextPronunciation,
          direction: latest.direction,
          turnId: latest.turnId,
        );
      }
    });
    if (keepAtBottom) _scrollToBottom(settle: forceScroll);
  }

  _TtsAudioCacheKey _ttsAudioCacheKey({
    required String text,
    required String lang,
    required String model,
    required String voice,
    required String responseFormat,
    required int instructionsRevision,
  }) {
    return (
      text: text,
      lang: lang,
      model: model,
      voice: voice,
      responseFormat: responseFormat,
      instructionsRevision: instructionsRevision,
    );
  }

  void _cacheTtsAudio(_TtsAudioCacheKey key, Uint8List bytes) {
    final existing = _ttsAudioCache.remove(key);
    if (existing != null) {
      _ttsAudioCacheBytes -= existing.lengthInBytes;
    }

    if (bytes.lengthInBytes > _ttsAudioCacheMaxBytes) return;

    _ttsAudioCache[key] = bytes;
    _ttsAudioCacheBytes += bytes.lengthInBytes;

    while (_ttsAudioCache.length > _ttsAudioCacheMaxEntries ||
        _ttsAudioCacheBytes > _ttsAudioCacheMaxBytes) {
      final oldestKey = _ttsAudioCache.keys.first;
      final oldest = _ttsAudioCache.remove(oldestKey);
      if (oldest != null) {
        _ttsAudioCacheBytes -= oldest.lengthInBytes;
      }
    }
  }

  void _clearTtsAudioCache() {
    _ttsAudioCache.clear();
    _ttsAudioRequests.clear();
    _ttsAudioCacheBytes = 0;
  }

  static Uint8List _buildTtsPrerollAudio() {
    final sampleCount = (_ttsPrerollSampleRate * _ttsPrerollMs / 1000).round();
    final pcm = Uint8List(sampleCount * 2);
    final data = ByteData.sublistView(pcm);
    var seed = 0x12345678;
    for (var i = 0; i < sampleCount; i++) {
      seed = (1664525 * seed + 1013904223) & 0xffffffff;
      // Near-silent dither wakes browser/Bluetooth output without an audible
      // buzz before the real TTS audio starts.
      final sample = (((seed >> 24) & 0xff) - 128) ~/ 4;
      data.setInt16(i * 2, sample, Endian.little);
    }
    return pcm16ToWav([pcm], sampleRate: _ttsPrerollSampleRate, numChannels: 1);
  }

  Future<Uint8List> _getOpenAITTSBytes({
    required String text,
    required String lang,
    required String model,
    required String voice,
    required String instructions,
    required String responseFormat,
  }) {
    final key = _ttsAudioCacheKey(
      text: text,
      lang: lang,
      model: model,
      voice: voice,
      responseFormat: responseFormat,
      instructionsRevision: _ttsInstructionsRevision,
    );
    final cached = _ttsAudioCache.remove(key);
    if (cached != null) {
      _ttsAudioCache[key] = cached;
      return Future.value(cached);
    }

    final inFlight = _ttsAudioRequests[key];
    if (inFlight != null) return inFlight;

    final request = _openai
        .tts(
          text,
          lang,
          model: model,
          voice: voice,
          instructions: instructions,
          responseFormat: responseFormat,
        )
        .then((bytes) {
          if (key.instructionsRevision == _ttsInstructionsRevision) {
            _cacheTtsAudio(key, bytes);
          }
          return bytes;
        });
    _ttsAudioRequests[key] = request;
    return request.whenComplete(() => _ttsAudioRequests.remove(key));
  }

  bool get _microphoneCaptureActive =>
      _isListening ||
      _isRecording ||
      _isRecordingStarting ||
      _isMirrorListening ||
      _isMirrorStarting ||
      _hasRecordingStopInProgress;

  void _stopPlaybackForRecording() {
    _playbackGeneration++;
    _lastTtsOutputPrimeAt = null;
    unawaited(RealtimeTranslationService.stopBufferedAudio());
    if (_audioPlayerMayBeActive) {
      _audioPlayerMayBeActive = false;
      unawaited(_audioPlayer.stop().catchError((Object _) {}));
    }
    unawaited(_speech.stopSpeaking().catchError((Object _) {}));
  }

  Future<void> _primeTtsOutputIfNeeded(
    double balance,
    int playbackGeneration,
  ) async {
    unawaited(RealtimeTranslationService.warmUpAudioOutput());
    final lastPrime = _lastTtsOutputPrimeAt;
    if (lastPrime != null &&
        DateTime.now().difference(lastPrime) < const Duration(seconds: 3)) {
      return;
    }
    if (!mounted ||
        playbackGeneration != _playbackGeneration ||
        _microphoneCaptureActive) {
      return;
    }
    try {
      if (kIsWeb) {
        _lastTtsOutputPrimeAt = DateTime.now();
        return;
      }
      _audioPlayerMayBeActive = true;
      await _audioPlayer.setSource(
        BytesSource(_ttsPrerollAudio, mimeType: 'audio/wav'),
      );
      await _audioPlayer.setBalance(balance);
      await _audioPlayer.resume();
      await Future<void>.delayed(const Duration(milliseconds: _ttsPrerollMs));
      await _audioPlayer.stop();
      _lastTtsOutputPrimeAt = DateTime.now();
    } catch (_) {}
  }

  int _ttsLeadInMsForModel(String model) {
    final id = model.toLowerCase();
    if (id == 'system-tts') return 0;
    if (id == 'tts-1') return 380;
    if (id == 'tts-1-hd') return 340;
    return 180;
  }

  double _ttsInitialBoostGainForModel(String model) {
    final id = model.toLowerCase();
    if (id == 'system-tts') return 1.0;
    if (id == 'tts-1') return 1.45;
    if (id == 'tts-1-hd') return 1.30;
    return 1.15;
  }

  int _ttsInitialBoostMsForModel(String model) {
    final id = model.toLowerCase();
    if (id == 'system-tts') return 0;
    if (id == 'tts-1' || id == 'tts-1-hd') return 650;
    return 180;
  }

  double _ttsLeadInGainForModel(String model) {
    final id = model.toLowerCase();
    if (id == 'system-tts') return 0.0;
    if (id == 'tts-1') return 0.0024;
    if (id == 'tts-1-hd') return 0.0020;
    return 0.0012;
  }

  bool get _useAndroidOpenAITtsFilePlayback =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _shouldForceAndroidTtsStereoPan(double balance) {
    return _useAndroidOpenAITtsFilePlayback &&
        _ttsAudioRoute != 'mono' &&
        balance.abs() > 0.01;
  }

  String _openAiTtsResponseFormatForBalance(double balance) {
    if (!_useAndroidOpenAITtsFilePlayback) return 'wav';
    return _shouldForceAndroidTtsStereoPan(balance) ? 'wav' : 'mp3';
  }

  String _openAiTtsMimeType(String responseFormat) {
    return switch (responseFormat) {
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      _ => 'audio/$responseFormat',
    };
  }

  Future<DeviceFileSource> _writeOpenAiTtsTempSource(
    Uint8List audioBytes,
    String responseFormat,
  ) async {
    final directoryPath = _tempDirectoryPathFuture == null
        ? (await getTemporaryDirectory()).path
        : await _tempDirectoryPathFuture!;
    final extension = responseFormat == 'mp3' ? 'mp3' : responseFormat;
    final file = java_io.File(
      '$directoryPath/openai_tts_${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsBytes(audioBytes, flush: false);
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () async {
        try {
          await file.delete();
        } catch (_) {}
      }),
    );
    return DeviceFileSource(file.path);
  }

  Future<DeviceFileSource?> _androidSystemTtsPannedSource({
    required String text,
    required String lang,
    required String gender,
    required double balance,
  }) async {
    if (!_shouldForceAndroidTtsStereoPan(balance)) return null;
    final directoryPath = _tempDirectoryPathFuture == null
        ? (await getTemporaryDirectory()).path
        : await _tempDirectoryPathFuture!;
    final sourceFile = java_io.File(
      '$directoryPath/system_tts_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    final sourcePath = await _speech.synthesizeToFile(
      text,
      lang,
      filePath: sourceFile.path,
      rate: _ttsSpeed,
      gender: gender,
    );
    if (sourcePath == null) return null;
    final sourceBytes = await java_io.File(sourcePath).readAsBytes();
    final pannedBytes = panWavPcm16ToStereo(sourceBytes, balance);
    unawaited(
      java_io.File(sourcePath).delete().catchError((Object _) => sourceFile),
    );
    return _writeOpenAiTtsTempSource(pannedBytes, 'wav');
  }

  Future<void> _playOpenAITTS(
    String text,
    String lang,
    String voice, {
    Stopwatch? timing,
  }) async {
    if (_microphoneCaptureActive) return;
    final playbackGeneration = _playbackGeneration;
    final instructions = _ttsPrompt;
    final balance = _ttsPanForOutputLang(lang);
    final leadInMs = _ttsLeadInMsForModel(_ttsModel);
    final initialBoostGain = _ttsInitialBoostGainForModel(_ttsModel);
    final initialBoostMs = _ttsInitialBoostMsForModel(_ttsModel);
    final leadInGain = _ttsLeadInGainForModel(_ttsModel);
    final forceAndroidStereoPan = _shouldForceAndroidTtsStereoPan(balance);
    final responseFormat = _openAiTtsResponseFormatForBalance(balance);
    _logTtsAudio(
      () =>
          'play.begin lang=$lang route=$_ttsAudioRoute pan=$balance '
          'web=$kIsWeb model=$_ttsModel format=$responseFormat lead=${leadInMs}ms '
          'leadGain=$leadInGain boost=${initialBoostGain}x/${initialBoostMs}ms',
    );
    try {
      if (_ttsModel == 'system-tts') {
        final gender = _systemTtsGenderForVoice(voice);
        if (timing != null) _logPingPongTiming('tts_system_start', timing);
        if (forceAndroidStereoPan) {
          final source = await _androidSystemTtsPannedSource(
            text: text,
            lang: lang,
            gender: gender,
            balance: balance,
          );
          if (source != null &&
              mounted &&
              playbackGeneration == _playbackGeneration &&
              !_microphoneCaptureActive) {
            _audioPlayerMayBeActive = true;
            await _audioPlayer.setSource(source);
            await _audioPlayer.setBalance(0);
            if (timing != null) {
              _logPingPongTiming('tts_system_ready_to_speak', timing);
              _logPingPongTiming('tts_system_speak_returned', timing);
            }
            await _audioPlayer.resume();
            if (timing != null) {
              _logPingPongTiming('tts_system_start_event', timing);
            }
            _logTtsAudio(
              () =>
                  'play.system_tts.panned_file_started lang=$lang '
                  'gender=$gender pan=$balance',
            );
            return;
          }
          _logTtsAudio(
            () =>
                'play.system_tts.panned_file_fallback lang=$lang '
                'gender=$gender pan=$balance',
          );
        }
        await _speech.speak(
          text,
          lang,
          gender: gender,
          directWebSpeech: _systemTtsEngine == 'direct_web',
          onReadyToSpeak: timing == null
              ? null
              : () => _logPingPongTiming('tts_system_ready_to_speak', timing),
          onStart: timing == null
              ? null
              : () => _logPingPongTiming('tts_system_start_event', timing),
          onSpeakReturned: timing == null
              ? null
              : () => _logPingPongTiming('tts_system_speak_returned', timing),
        );
        _logTtsAudio(
          () => 'play.system_tts.speak_returned lang=$lang gender=$gender',
        );
        return;
      }
      if (timing != null) _logPingPongTiming('tts_prepare_start', timing);
      final audioRequest = _getOpenAITTSBytes(
        text: text,
        lang: lang,
        model: _ttsModel,
        voice: voice,
        instructions: instructions,
        responseFormat: responseFormat,
      );
      if (!_useAndroidOpenAITtsFilePlayback) {
        await _primeTtsOutputIfNeeded(balance, playbackGeneration);
      }
      final audioBytes = await audioRequest;
      if (timing != null) _logPingPongTiming('tts_audio_ready', timing);
      var playbackBytes = audioBytes;
      var playbackFormat = responseFormat;
      if (forceAndroidStereoPan && responseFormat == 'wav') {
        playbackBytes = panWavPcm16ToStereo(audioBytes, balance);
        playbackFormat = 'wav';
      }
      _logTtsAudio(
        () =>
            'play.audio_ready bytes=${playbackBytes.lengthInBytes} '
            'format=$responseFormat androidFile=$_useAndroidOpenAITtsFilePlayback',
      );
      if (!mounted ||
          playbackGeneration != _playbackGeneration ||
          _microphoneCaptureActive) {
        return;
      }
      _audioPlayerMayBeActive = true;
      if (kIsWeb) {
        if (timing != null) _logPingPongTiming('tts_play_start', timing);
        final played = await RealtimeTranslationService.playBufferedAudio(
          audioBytes,
          pan: balance,
          leadInMs: leadInMs,
          initialBoostGain: initialBoostGain,
          initialBoostDurationMs: initialBoostMs,
          leadInGain: leadInGain,
        );
        if (played) {
          _logTtsAudio(() => 'play.web_audio.done pan=$balance');
          _audioPlayerMayBeActive = false;
          return;
        }
        _logTtsAudio(() => 'play.web_audio.fallback pan=$balance');
      }
      if (_useAndroidOpenAITtsFilePlayback) {
        final source = await _writeOpenAiTtsTempSource(
          playbackBytes,
          playbackFormat,
        );
        await _audioPlayer.setSource(source);
        _logTtsAudio(() => 'play.android_file.source_set pan=$balance');
      } else {
        await _audioPlayer.setSource(
          BytesSource(
            playbackBytes,
            mimeType: _openAiTtsMimeType(playbackFormat),
          ),
        );
      }
      await _audioPlayer.setBalance(forceAndroidStereoPan ? 0 : balance);
      if (timing != null) _logPingPongTiming('tts_play_start', timing);
      await _audioPlayer.resume();
      _logTtsAudio(() => 'play.audio_player.started pan=$balance');
    } catch (e) {
      _logTtsAudio(() => 'play.error $e');
      _audioPlayerMayBeActive = false;
      if (!mounted ||
          playbackGeneration != _playbackGeneration ||
          _microphoneCaptureActive) {
        return;
      }
      // Fallback to system TTS.
      final g =
          (lang == _targetLang ? _voiceTarget : _voiceSource) == 'nova' ||
              (lang == _targetLang ? _voiceTarget : _voiceSource) == 'coral'
          ? 'female'
          : 'male';
      _logTtsAudio(
        () => 'play.fallback.system_tts lang=$lang gender=$g reason=$e',
      );
      if (timing != null) {
        _logPingPongTiming('tts_system_fallback_start', timing);
      }
      await _speech.speak(
        text,
        lang,
        gender: g,
        onReadyToSpeak: timing == null
            ? null
            : () => _logPingPongTiming(
                'tts_system_fallback_ready_to_speak',
                timing,
              ),
        onStart: timing == null
            ? null
            : () =>
                  _logPingPongTiming('tts_system_fallback_start_event', timing),
        onSpeakReturned: timing == null
            ? null
            : () => _logPingPongTiming(
                'tts_system_fallback_speak_returned',
                timing,
              ),
      );
      _logTtsAudio(
        () => 'play.fallback.system_tts.speak_returned lang=$lang gender=$g',
      );
    }
  }

  Future<void> _stopAll({bool processRecordingsInBackground = true}) async {
    final stops = <Future<void>>[];
    if (_isListening) stops.add(_stopListening());
    if (_isMirrorListening) {
      stops.add(
        _stopMirrorListening(
          processInBackground: processRecordingsInBackground,
        ),
      );
    }
    if (_isRecording) {
      stops.add(
        _stopOpenAIRecording(
          processInBackground: processRecordingsInBackground,
        ),
      );
    }
    if (stops.length == 1) {
      await stops.first;
    } else if (stops.isNotEmpty) {
      await Future.wait(stops);
    }
    await _waitForRecordingStops();
  }

  Future<void> _waitForRecordingStops() async {
    final mirrorStop = _mirrorStopFuture;
    final recordingStop = _recordingStopFuture;
    if (mirrorStop != null && recordingStop != null) {
      await Future.wait([mirrorStop, recordingStop]);
    } else if (mirrorStop != null) {
      await mirrorStop;
    } else if (recordingStop != null) {
      await recordingStop;
    }
  }

  bool get _hasRecordingStopInProgress =>
      _mirrorStopFuture != null || _recordingStopFuture != null;

  void _setPrimaryRecordingStartingUi(String lang, String status) {
    if (mounted) {
      setState(() {
        _micLang = lang;
        _isRecordingStarting = true;
        _setInterimTextValue(status);
      });
    } else {
      _micLang = lang;
      _isRecordingStarting = true;
      _setInterimTextValue(status);
    }
  }

  Future<void> _stopListening() async {
    await _stopSystemListening();
  }

  Future<void> _startSystemListening({
    required String lang,
    String? forceDirection,
    bool startingUiAlreadySet = false,
  }) async {
    if (_isListening ||
        (_isRecordingStarting && !startingUiAlreadySet) ||
        _isMirrorStarting ||
        (_aiMode && _isProcessing)) {
      return;
    }
    var ownsStartingUi = startingUiAlreadySet;
    if (!startingUiAlreadySet) {
      _setPrimaryRecordingStartingUi(lang, '음성 인식 준비 중...');
      ownsStartingUi = true;
    }
    _stopPlaybackForRecording();
    await _stopAll(processRecordingsInBackground: true);
    if (_isListening ||
        (_isRecordingStarting && !ownsStartingUi) ||
        _isMirrorStarting ||
        (_aiMode && _isProcessing)) {
      if (ownsStartingUi && mounted) {
        setState(() {
          _isRecordingStarting = false;
          if (!_isListening && _interimText == '음성 인식 준비 중...') {
            _setInterimTextValue('');
          }
        });
      }
      return;
    }

    final generation = _conversationGeneration;
    final serial = ++_recordingSerial;
    _systemSttText = '';
    _systemSttDirection = forceDirection;
    _systemSttSerial = serial;
    _systemSttGeneration = generation;
    _systemSttAskAI = _aiMode;
    _systemSttAcceptingResults = true;
    _systemSttError = null;
    _systemSttLang = lang;
    _systemSttFallbackRecorderStart = null;
    _systemSttCommittedText = '';
    _systemSttStopRequested = false;
    _systemSttRestartFuture = null;
    _cancelPrimarySystemSttAutoStop();
    _systemSttSegmentHadText = false;

    try {
      _prewarmSystemTtsForDirection(forceDirection: forceDirection);
      _prewarmPingPongTextWsIfNeeded(includePostProcess: true);
      final started = await _startPrimarySystemSttSegment(
        lang: lang,
        serial: serial,
        generation: generation,
        forceDirection: forceDirection,
      );
      if (!started) {
        throw Exception('시스템 STT를 시작할 수 없습니다');
      }
      _systemSttFallbackRecorderStart = _startSystemSttFallbackRecorder(
        _primaryRecorderOwner,
        sttLang: lang,
      );
      if (!mounted || !_isConversationCurrent(generation)) {
        _systemSttAcceptingResults = false;
        await _speech.stopListening();
        await _stopSystemSttFallbackRecorder(
          _primaryRecorderOwner,
          startFuture: _systemSttFallbackRecorderStart,
        );
        _systemSttFallbackRecorderStart = null;
        return;
      }
      setState(() {
        _micLang = lang;
        _isRecordingStarting = false;
        _isListening = true;
        _setInterimTextValue('음성 인식 중... (버튼을 눌러 종료)');
      });
    } catch (e) {
      _systemSttText = '';
      _systemSttAcceptingResults = false;
      _systemSttError = e.toString();
      _systemSttFallbackRecorderStart = null;
      _systemSttCommittedText = '';
      _systemSttStopRequested = false;
      _systemSttRestartFuture = null;
      if (!mounted) return;
      setState(() {
        _isRecordingStarting = false;
        _isListening = false;
        _setInterimTextValue('');
      });
      _showError(e.toString());
    } finally {
      if (_isRecordingStarting) {
        if (mounted) {
          setState(() {
            _isRecordingStarting = false;
            if (!_isListening && _interimText == '음성 인식 준비 중...') {
              _setInterimTextValue('');
            }
          });
        } else {
          _isRecordingStarting = false;
        }
      }
    }
  }

  Future<bool> _startPrimarySystemSttSegment({
    required String lang,
    required int serial,
    required int generation,
    String? forceDirection,
  }) {
    _systemSttSegmentHadText = false;
    final locale = _systemSttLocale(lang);
    return _speech.startListening(
      locale: locale,
      pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
      fastInterim: _isAndroidSystemStt && _androidSystemSttFastInterim,
      onResult: (text, isFinal) {
        _handlePrimarySystemSttResult(
          text: text,
          isFinal: isFinal,
          lang: lang,
          serial: serial,
          generation: generation,
          forceDirection: forceDirection,
        );
      },
      onDone: () {
        _handlePrimarySystemSttDone(
          lang: lang,
          serial: serial,
          generation: generation,
          forceDirection: forceDirection,
        );
      },
      onError: (error) {
        if (_systemSttSerial == serial) _systemSttError = error;
      },
    );
  }

  void _handlePrimarySystemSttResult({
    required String text,
    required bool isFinal,
    required String lang,
    required int serial,
    required int generation,
    String? forceDirection,
  }) {
    if (!mounted ||
        !_systemSttAcceptingResults ||
        _systemSttSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }

    final useAndroidOffWorkaround = _isAndroidSystemSttExperimentalOff;
    if (useAndroidOffWorkaround && text.trim().isNotEmpty) {
      _systemSttSegmentHadText = true;
      _cancelPrimarySystemSttAutoStop();
    }
    final displayText = useAndroidOffWorkaround
        ? _mergeSystemSttSegments(_systemSttCommittedText, text)
        : text;
    _systemSttText = displayText;
    _applyPrimarySttInterim(
      serial: serial,
      generation: generation,
      text: displayText,
      forceDirection: forceDirection,
    );

    if (!isFinal || text.trim().isEmpty) return;
    if (useAndroidOffWorkaround) {
      _systemSttCommittedText = displayText;
      _schedulePrimarySystemSttAutoStop(serial: serial, generation: generation);
      _schedulePrimarySystemSttRestart(
        lang: lang,
        serial: serial,
        generation: generation,
        forceDirection: forceDirection,
      );
      return;
    }
    unawaited(_stopSystemListening(requestStop: false));
  }

  void _handlePrimarySystemSttDone({
    required String lang,
    required int serial,
    required int generation,
    String? forceDirection,
  }) {
    if (!_systemSttAcceptingResults || _systemSttSerial != serial) {
      return;
    }
    if (_isAndroidSystemSttExperimentalOff) {
      if (_systemSttSegmentHadText && _systemSttText.trim().isNotEmpty) {
        _systemSttCommittedText = _systemSttText;
        _schedulePrimarySystemSttAutoStop(
          serial: serial,
          generation: generation,
        );
      }
      _schedulePrimarySystemSttRestart(
        lang: lang,
        serial: serial,
        generation: generation,
        forceDirection: forceDirection,
      );
      return;
    }
    unawaited(_stopSystemListening(requestStop: false));
  }

  void _schedulePrimarySystemSttRestart({
    required String lang,
    required int serial,
    required int generation,
    String? forceDirection,
  }) {
    if (!_isAndroidSystemSttExperimentalOff ||
        _systemSttStopRequested ||
        !_systemSttAcceptingResults ||
        _systemSttSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    if (_systemSttRestartFuture != null) return;

    late final Future<void> restart;
    restart =
        _restartPrimarySystemSttSegment(
          lang: lang,
          serial: serial,
          generation: generation,
          forceDirection: forceDirection,
        ).whenComplete(() {
          if (_systemSttRestartFuture == restart) {
            _systemSttRestartFuture = null;
          }
        });
    _systemSttRestartFuture = restart;
  }

  Future<void> _restartPrimarySystemSttSegment({
    required String lang,
    required int serial,
    required int generation,
    String? forceDirection,
  }) async {
    await Future<void>.delayed(_androidSystemSttRestartGap);
    if (!_isAndroidSystemSttExperimentalOff ||
        _systemSttStopRequested ||
        !_systemSttAcceptingResults ||
        _systemSttSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    try {
      final started = await _startPrimarySystemSttSegment(
        lang: lang,
        serial: serial,
        generation: generation,
        forceDirection: forceDirection,
      );
      if (!started && mounted && _systemSttSerial == serial) {
        _systemSttError = '시스템 STT 재시작 실패';
      }
    } catch (e) {
      if (mounted && _systemSttSerial == serial) {
        _systemSttError = e.toString();
      }
    }
  }

  Future<void> _stopSystemListening({
    bool processInBackground = true,
    bool requestStop = true,
  }) {
    final existing = _recordingStopFuture;
    if (existing != null) return existing;
    if (_isRecordingStarting && !_isListening && !_systemSttAcceptingResults) {
      return Future.value();
    }
    if (!_isListening &&
        !_systemSttAcceptingResults &&
        _systemSttText.trim().isEmpty) {
      return Future.value();
    }

    late final Future<void> tracked;
    tracked =
        _stopSystemListeningInternal(
          processInBackground: processInBackground,
          requestStop: requestStop,
        ).whenComplete(() {
          if (_recordingStopFuture == tracked) {
            _recordingStopFuture = null;
          }
        });
    _recordingStopFuture = tracked;
    return tracked;
  }

  Future<void> _stopSystemListeningInternal({
    required bool processInBackground,
    required bool requestStop,
  }) async {
    final timing = Stopwatch()..start();
    if (requestStop) _logPingPongTiming('record_stop_clicked', timing);
    final serial = _systemSttSerial;
    final generation = _systemSttGeneration;
    final forceDirection = _systemSttDirection;
    final shouldAskAI = _systemSttAskAI;
    _systemSttStopRequested = true;
    _cancelPrimarySystemSttAutoStop();

    if (mounted) {
      setState(() {
        _isRecordingStarting = false;
        _setInterimTextValue('음성 인식 중...');
      });
    } else {
      _isRecordingStarting = false;
    }

    if (requestStop || _speech.isListening) {
      await _speech.stopListening();
    }
    await _waitForSystemSttFlush(() => _systemSttText);
    _systemSttAcceptingResults = false;
    if (mounted) {
      setState(() => _isListening = false);
    } else {
      _isListening = false;
    }
    _logPingPongTiming('system_stt_stop_done', timing);

    final text = _systemSttText.replaceAll(_whitespacePattern, ' ').trim();
    final error = _systemSttError;
    final fallbackRecording = await _stopSystemSttFallbackRecorder(
      _primaryRecorderOwner,
      startFuture: _systemSttFallbackRecorderStart,
    );
    _systemSttFallbackRecorderStart = null;
    _systemSttText = '';
    _systemSttError = null;
    _systemSttCommittedText = '';
    _systemSttRestartFuture = null;
    _systemSttSegmentHadText = false;
    if (text.isEmpty) {
      if (fallbackRecording != null) {
        _logPingPongTiming('system_stt_openai_fallback', timing);
        _logPingPongTiming('recorder_stop_done', timing);
        _logPingPongTiming('audio_bytes_ready', timing);
        final processing = _processPrimaryRecording(
          fallbackRecording,
          serial: serial,
          generation: generation,
          sttLang: _systemSttLang,
          forceDirection: forceDirection,
          askAI: shouldAskAI,
          timing: timing,
        );
        if (processInBackground) {
          unawaited(processing);
        } else {
          await processing;
        }
        return;
      }
      _clearPrimaryInterimIfCurrent(serial);
      if (mounted) {
        final suffix = error == null ? '' : ' ($error)';
        _showError('시스템 STT 결과가 비어 있습니다$suffix');
      }
      return;
    }
    _logPingPongTiming('system_stt_text_ready', timing);
    if (!_isConversationCurrent(generation)) return;

    final draftTurnId = _pingPongSttDraftTurnId(_primaryRecorderOwner, serial);
    if (!shouldAskAI) {
      _upsertPingPongSttDraft(
        turnId: draftTurnId,
        text: text,
        direction: _pingPongDirectionForForce(forceDirection),
        generation: generation,
        mirror: false,
      );
    }

    void process() {
      if (shouldAskAI) {
        _handleAIQuestion(text, generation: generation);
      } else {
        _enqueueTranslation(
          text,
          forceDirection: forceDirection,
          generation: generation,
          timing: timing,
          draftTurnId: draftTurnId,
        );
      }
    }

    if (processInBackground) {
      process();
    } else {
      process();
      await _translationQueue;
    }
  }

  Future<void> _switchSystemListening({
    required String nextLang,
    required String nextDirection,
  }) async {
    final stop = _stopSystemListening(
      processInBackground: true,
      requestStop: true,
    );
    _setPrimaryRecordingStartingUi(nextLang, '음성 인식 전환 중...');
    try {
      await stop;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecordingStarting = false;
          if (!_isListening && _interimText == '음성 인식 전환 중...') {
            _setInterimTextValue('');
          }
        });
        _showError(e.toString());
      }
      return;
    }
    if (!mounted) return;
    await _startSystemListening(
      lang: nextLang,
      forceDirection: _aiMode ? null : nextDirection,
      startingUiAlreadySet: true,
    );
  }

  Future<void> _startMirrorListening({
    bool startingUiAlreadySet = false,
  }) async {
    final useOpenAIRecording = _mode == 'openai' && !_usesSystemStt;
    if (_isMirrorListening ||
        (_isMirrorStarting && !startingUiAlreadySet) ||
        _isRecordingStarting ||
        (_aiMode && _isProcessing)) {
      return;
    }
    var ownsStartingUi = startingUiAlreadySet;
    if (!startingUiAlreadySet) {
      if (mounted) {
        setState(() {
          _isMirrorStarting = true;
          _setMirrorInterimTextValue(
            useOpenAIRecording ? '録音準備中...' : '音声認識準備中...',
          );
        });
      } else {
        _isMirrorStarting = true;
      }
      ownsStartingUi = true;
    }
    _stopPlaybackForRecording();
    Future<String>? pathFuture;
    if (useOpenAIRecording && !kIsWeb) {
      pathFuture = _recordingPath();
      _consumePreparedRecordingPathErrors(pathFuture);
    }
    await _stopAll(processRecordingsInBackground: true);
    if (_isMirrorListening ||
        (_isMirrorStarting && !ownsStartingUi) ||
        _isRecordingStarting ||
        (_aiMode && _isProcessing)) {
      if (ownsStartingUi) {
        if (mounted) {
          setState(() {
            _isMirrorStarting = false;
            if (_mirrorInterimText == '録音準備中...' ||
                _mirrorInterimText == '音声認識準備中...') {
              _setMirrorInterimTextValue('');
            }
          });
        } else {
          _isMirrorStarting = false;
        }
      }
      return;
    }
    final generation = _conversationGeneration;

    try {
      if (!mounted) return;
      if (useOpenAIRecording) {
        // OpenAI STT: record + Transcriptions API
        final permissionFuture = _ensureMicPermission();
        final hasPermission = await permissionFuture;
        if (!hasPermission) {
          _showError('마이크 권한이 필요합니다');
          return;
        }

        final path = pathFuture == null ? null : await pathFuture;
        await _startRecorderForOwner(
          _mirrorRecorderOwner,
          path: path,
          sttLang: _targetLang,
        );
        _mirrorUsesOpenAIRecording = true;
        _prewarmPingPongTextWsIfNeeded(includePostProcess: true);
        if (!mounted) {
          await _stopRecorderIfOwner(_mirrorRecorderOwner);
          _mirrorUsesOpenAIRecording = false;
          return;
        }

        _mirrorRecordingSerial++;
        setState(() {
          _isMirrorStarting = false;
          _isMirrorListening = true;
          _setMirrorInterimTextValue('録音中... (ボタンを押して停止)');
        });

        // Silence detection for mirror mic
        final mirrorPause = _aiMode ? _aiPauseSeconds : _pauseSeconds;
        if (mirrorPause < 30) {
          final silenceTimeout = Duration(seconds: mirrorPause);
          _ampSub = _recorder
              .onAmplitudeChanged(const Duration(milliseconds: 200))
              .listen((amp) {
                if (amp.current < _noiseThreshold) {
                  if (_silenceTimer != null) return;
                  _silenceTimer = Timer(silenceTimeout, () {
                    if (_isMirrorListening) {
                      unawaited(_stopMirrorListening());
                    }
                  });
                } else {
                  _silenceTimer?.cancel();
                  _silenceTimer = null;
                }
              });
        }
      } else {
        // System STT
        _mirrorUsesOpenAIRecording = false;
        _prewarmTtsIfNeeded();
        _mirrorSystemSttText = '';
        _mirrorSystemSttAcceptingResults = true;
        _mirrorSystemSttError = null;
        _mirrorSystemSttFallbackRecorderStart = null;
        _mirrorSystemSttCommittedText = '';
        _mirrorSystemSttStopRequested = false;
        _mirrorSystemSttRestartFuture = null;
        _cancelMirrorSystemSttAutoStop();
        _mirrorSystemSttSegmentHadText = false;
        final serial = ++_mirrorRecordingSerial;
        final started = await _startMirrorSystemSttSegment(
          lang: _targetLang,
          serial: serial,
          generation: generation,
        );
        if (!started) {
          throw Exception('시스템 STT를 시작할 수 없습니다');
        }
        _mirrorSystemSttFallbackRecorderStart = _startSystemSttFallbackRecorder(
          _mirrorRecorderOwner,
          sttLang: _targetLang,
        );
        if (!mounted) return;
        setState(() {
          _isMirrorStarting = false;
          _isMirrorListening = true;
          _setMirrorInterimTextValue('音声認識中... (ボタンを押して停止)');
        });
      }
    } catch (e) {
      _mirrorUsesOpenAIRecording = false;
      _mirrorSystemSttText = '';
      _mirrorSystemSttAcceptingResults = false;
      _mirrorSystemSttError = e.toString();
      _mirrorSystemSttFallbackRecorderStart = null;
      _mirrorSystemSttCommittedText = '';
      _mirrorSystemSttStopRequested = false;
      _mirrorSystemSttRestartFuture = null;
      _cancelMirrorSystemSttAutoStop();
      _mirrorSystemSttSegmentHadText = false;
      if (!mounted) return;
      setState(() {
        _isMirrorStarting = false;
        _isMirrorListening = false;
        _setMirrorInterimTextValue('');
      });
      _showError(e.toString());
    } finally {
      if (_isMirrorStarting) {
        if (mounted) {
          setState(() {
            _isMirrorStarting = false;
            if (!_isMirrorListening &&
                (_mirrorInterimText == '録音準備中...' ||
                    _mirrorInterimText == '音声認識準備中...')) {
              _setMirrorInterimTextValue('');
            }
          });
        } else {
          _isMirrorStarting = false;
        }
      }
    }
  }

  Future<bool> _startMirrorSystemSttSegment({
    required String lang,
    required int serial,
    required int generation,
  }) {
    _mirrorSystemSttSegmentHadText = false;
    final locale = _systemSttLocale(lang);
    return _speech.startListening(
      locale: locale,
      pauseSeconds: _aiMode ? _aiPauseSeconds : _pauseSeconds,
      fastInterim: _isAndroidSystemStt && _androidSystemSttFastInterim,
      onResult: (text, isFinal) {
        _handleMirrorSystemSttResult(
          text: text,
          isFinal: isFinal,
          lang: lang,
          serial: serial,
          generation: generation,
        );
      },
      onDone: () {
        _handleMirrorSystemSttDone(
          lang: lang,
          serial: serial,
          generation: generation,
        );
      },
      onError: (error) {
        if (_mirrorRecordingSerial == serial) {
          _mirrorSystemSttError = error;
        }
      },
    );
  }

  void _handleMirrorSystemSttResult({
    required String text,
    required bool isFinal,
    required String lang,
    required int serial,
    required int generation,
  }) {
    if (!mounted ||
        !_mirrorSystemSttAcceptingResults ||
        _mirrorRecordingSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }

    final useAndroidOffWorkaround = _isAndroidSystemSttExperimentalOff;
    if (useAndroidOffWorkaround && text.trim().isNotEmpty) {
      _mirrorSystemSttSegmentHadText = true;
      _cancelMirrorSystemSttAutoStop();
    }
    final displayText = useAndroidOffWorkaround
        ? _mergeSystemSttSegments(_mirrorSystemSttCommittedText, text)
        : text;
    _mirrorSystemSttText = displayText;
    _applyMirrorSttInterim(
      serial: serial,
      generation: generation,
      text: displayText,
    );

    if (!isFinal || text.trim().isEmpty) return;
    if (useAndroidOffWorkaround) {
      _mirrorSystemSttCommittedText = displayText;
      _scheduleMirrorSystemSttAutoStop(serial: serial, generation: generation);
      _scheduleMirrorSystemSttRestart(
        lang: lang,
        serial: serial,
        generation: generation,
      );
      return;
    }
    unawaited(_stopMirrorListening());
  }

  void _handleMirrorSystemSttDone({
    required String lang,
    required int serial,
    required int generation,
  }) {
    if (!_mirrorSystemSttAcceptingResults || _mirrorRecordingSerial != serial) {
      return;
    }
    if (_isAndroidSystemSttExperimentalOff) {
      if (_mirrorSystemSttSegmentHadText &&
          _mirrorSystemSttText.trim().isNotEmpty) {
        _mirrorSystemSttCommittedText = _mirrorSystemSttText;
        _scheduleMirrorSystemSttAutoStop(
          serial: serial,
          generation: generation,
        );
      }
      _scheduleMirrorSystemSttRestart(
        lang: lang,
        serial: serial,
        generation: generation,
      );
      return;
    }
    unawaited(_stopMirrorListening());
  }

  void _scheduleMirrorSystemSttRestart({
    required String lang,
    required int serial,
    required int generation,
  }) {
    if (!_isAndroidSystemSttExperimentalOff ||
        _mirrorSystemSttStopRequested ||
        !_mirrorSystemSttAcceptingResults ||
        _mirrorRecordingSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    if (_mirrorSystemSttRestartFuture != null) return;

    late final Future<void> restart;
    restart =
        _restartMirrorSystemSttSegment(
          lang: lang,
          serial: serial,
          generation: generation,
        ).whenComplete(() {
          if (_mirrorSystemSttRestartFuture == restart) {
            _mirrorSystemSttRestartFuture = null;
          }
        });
    _mirrorSystemSttRestartFuture = restart;
  }

  Future<void> _restartMirrorSystemSttSegment({
    required String lang,
    required int serial,
    required int generation,
  }) async {
    await Future<void>.delayed(_androidSystemSttRestartGap);
    if (!_isAndroidSystemSttExperimentalOff ||
        _mirrorSystemSttStopRequested ||
        !_mirrorSystemSttAcceptingResults ||
        _mirrorRecordingSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    try {
      final started = await _startMirrorSystemSttSegment(
        lang: lang,
        serial: serial,
        generation: generation,
      );
      if (!started && mounted && _mirrorRecordingSerial == serial) {
        _mirrorSystemSttError = '시스템 STT 재시작 실패';
      }
    } catch (e) {
      if (mounted && _mirrorRecordingSerial == serial) {
        _mirrorSystemSttError = e.toString();
      }
    }
  }

  Future<void> _stopMirrorListening({bool processInBackground = true}) {
    final existing = _mirrorStopFuture;
    if (existing != null) return existing;
    if (_isMirrorStarting &&
        !_isMirrorListening &&
        !_mirrorSystemSttAcceptingResults) {
      return Future.value();
    }
    if (!_isMirrorListening && !_mirrorSystemSttAcceptingResults) {
      return Future.value();
    }

    late final Future<void> tracked;
    tracked =
        _stopMirrorListeningInternal(
          processInBackground: processInBackground,
        ).whenComplete(() {
          if (_mirrorStopFuture == tracked) {
            _mirrorStopFuture = null;
          }
        });
    _mirrorStopFuture = tracked;
    return tracked;
  }

  Future<void> _stopMirrorListeningInternal({
    required bool processInBackground,
  }) async {
    if (_mirrorUsesOpenAIRecording && _isMirrorListening) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      _ampSub?.cancel();
      _ampSub = null;
      final serial = _mirrorRecordingSerial;
      final generation = _conversationGeneration;
      try {
        if (mounted) {
          setState(() {
            _isMirrorListening = false;
            _setMirrorInterimTextValue('音声認識中...');
          });
        }
        final recording = await _stopRecorderIfOwner(_mirrorRecorderOwner);
        if (recording == null) {
          _clearMirrorInterimIfCurrent(serial);
          return;
        }

        final processing = _processMirrorRecording(
          recording,
          serial: serial,
          generation: generation,
        );
        if (processInBackground) {
          unawaited(processing);
        } else {
          await processing;
        }
      } finally {
        _mirrorUsesOpenAIRecording = false;
      }
    } else {
      final serial = _mirrorRecordingSerial;
      final generation = _conversationGeneration;
      try {
        _mirrorSystemSttStopRequested = true;
        _cancelMirrorSystemSttAutoStop();
        if (_speech.isListening) {
          await _speech.stopListening();
        }
        await _waitForSystemSttFlush(() => _mirrorSystemSttText);
        _mirrorSystemSttAcceptingResults = false;
        final text = _mirrorSystemSttText
            .replaceAll(_whitespacePattern, ' ')
            .trim();
        final error = _mirrorSystemSttError;
        final fallbackRecording = await _stopSystemSttFallbackRecorder(
          _mirrorRecorderOwner,
          startFuture: _mirrorSystemSttFallbackRecorderStart,
        );
        _mirrorSystemSttFallbackRecorderStart = null;
        _mirrorSystemSttText = '';
        _mirrorSystemSttError = null;
        _mirrorSystemSttCommittedText = '';
        _mirrorSystemSttRestartFuture = null;
        _mirrorSystemSttSegmentHadText = false;
        if (mounted) {
          setState(() {
            _isMirrorListening = false;
          });
        }
        if (text.isNotEmpty && _isConversationCurrent(generation)) {
          final draftTurnId = _pingPongSttDraftTurnId(
            _mirrorRecorderOwner,
            serial,
          );
          _upsertPingPongSttDraft(
            turnId: draftTurnId,
            text: text,
            direction: _targetToSourceDirection,
            generation: generation,
            mirror: true,
          );
          _enqueueTranslation(
            text,
            forceDirection: 'target2source',
            generation: generation,
            draftTurnId: draftTurnId,
          );
        } else {
          if (fallbackRecording != null && _isConversationCurrent(generation)) {
            final processing = _processMirrorRecording(
              fallbackRecording,
              serial: serial,
              generation: generation,
            );
            if (processInBackground) {
              unawaited(processing);
            } else {
              await processing;
            }
          } else {
            _clearMirrorInterimIfCurrent(serial);
            if (mounted && error != null) {
              _showError('시스템 STT 결과가 비어 있습니다 ($error)');
            }
          }
        }
      } finally {
        _mirrorUsesOpenAIRecording = false;
        _mirrorSystemSttAcceptingResults = false;
        _mirrorSystemSttFallbackRecorderStart = null;
        _mirrorSystemSttCommittedText = '';
        _mirrorSystemSttRestartFuture = null;
        _mirrorSystemSttSegmentHadText = false;
      }
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isProcessing) return;
    final generation = _conversationGeneration;
    _prewarmTtsIfNeeded();
    _textController.clear();
    if (_aiMode) {
      _handleAIQuestion(text, generation: generation);
    } else if (_isLiveTranslateMode) {
      _enqueueDetectedTextTranslation(text, generation: generation);
    } else if (_isRt && _realtimeActive) {
      if (_isDirectionalMode) {
        final rt = _activeDirectionalSession == 'a' ? _realtimeA : _realtimeB;
        rt?.sendText(text);
      } else {
        _realtime?.sendText(text);
      }
    } else {
      _enqueueDetectedTextTranslation(text, generation: generation);
    }
  }

  void _enqueueDetectedTextTranslation(String text, {required int generation}) {
    final detected = _detectLang(text);
    String direction;
    if (detected != null && detected == _sourceLang) {
      direction = 'source2target';
    } else if (detected != null && detected == _targetLang) {
      direction = 'target2source';
    } else {
      direction = _textDirection;
    }
    _enqueueTranslation(
      text,
      forceDirection: direction,
      generation: generation,
    );
  }

  Future<void> _resetApiKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API 키 초기화'),
        content: const Text('API 키를 초기화하시겠습니까?\n앱이 처음 화면으로 돌아갑니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
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

  Future<void> _handleAIQuestion(String question, {int? generation}) async {
    final requestGeneration = generation ?? _conversationGeneration;
    if (question.isEmpty ||
        _isProcessing ||
        !_isConversationCurrent(requestGeneration)) {
      return;
    }
    final processingToken = ++_processingToken;
    setState(() => _isProcessing = true);

    try {
      // Build context from recent messages
      final contextText = _recentAssistantContextText(8);
      final hasContext = contextText.isNotEmpty;

      final answer = await _openai.askAssistant(
        question,
        conversationContextText: hasContext ? contextText : null,
        model: _aiModel,
        systemPrompt: _assistantPrompt(hasContext: hasContext),
      );

      if (mounted && _isConversationCurrent(requestGeneration)) {
        setState(() {
          _messages.add(
            ChatMessage(
              original: question,
              translated: answer,
              direction: 'ai',
              isAI: true,
            ),
          );
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted && _isConversationCurrent(requestGeneration)) {
        _showError(e.toString());
      }
    } finally {
      if (mounted && _processingToken == processingToken) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _clearChat() {
    _invalidateConversationWork();
    _cancelPendingInterimUpdate();
    if (_realtimeActive) {
      _realtime?.clearState();
      _realtimeA?.clearState();
      _realtimeB?.clearState();
    }
    _liveTranslateCommitTimer?.cancel();
    _resetLiveTranslateBuffers();
    setState(() {
      _messages.clear();
      _setInterimTextPair('', '');
    });
  }

  bool get _ttsPlaybackEnabled => _ttsSourceEnabled || _ttsTargetEnabled;

  void _prewarmTtsIfNeeded() {
    if (!_ttsPlaybackEnabled) return;
    unawaited(_speech.warmupTts());
    if (_ttsModel == 'system-tts') {
      _prewarmSystemTtsForDirection();
    }
  }

  String _systemTtsGenderForVoice(String voice) {
    return voice == 'nova' || voice == 'coral' ? 'female' : 'male';
  }

  void _primeSystemTtsForOutput(
    String lang,
    String voice, {
    required bool enabled,
  }) {
    if (_ttsModel != 'system-tts' || !enabled) return;
    unawaited(
      _speech
          .primeTtsForNextSpeech(
            lang,
            rate: _ttsSpeed,
            gender: _systemTtsGenderForVoice(voice),
            webSilentUtterance: _systemTtsSilentPrimeEnabled,
            directWebSpeech: _systemTtsEngine == 'direct_web',
          )
          .catchError((Object _) {}),
    );
  }

  void _prewarmSystemTtsForDirection({String? forceDirection}) {
    if (_ttsModel != 'system-tts' || !_ttsPlaybackEnabled) return;
    final isSourceToTarget = forceDirection != 'target2source';
    final enabled = isSourceToTarget ? _ttsTargetEnabled : _ttsSourceEnabled;
    if (!enabled) return;
    final lang = isSourceToTarget ? _targetLang : _sourceLang;
    final voice = isSourceToTarget ? _voiceTarget : _voiceSource;
    unawaited(
      _speech
          .prepareTtsVoice(
            lang,
            rate: _ttsSpeed,
            gender: _systemTtsGenderForVoice(voice),
            directWebSpeech: _systemTtsEngine == 'direct_web',
          )
          .catchError((Object _) {}),
    );
  }

  // ===== OpenAI STT (record + Transcriptions API) =====
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _silenceTimer;

  Future<bool> _ensureMicPermission() {
    final cached = _micPermissionFuture;
    if (cached != null) return cached;

    _micPermissionFuture = _recorder
        .hasPermission()
        .then((allowed) {
          if (!allowed) _micPermissionFuture = null;
          return allowed;
        })
        .catchError((Object error) {
          _micPermissionFuture = null;
          throw error;
        });
    return _micPermissionFuture!;
  }

  Future<String> _recordingPath() async {
    if (kIsWeb) return '';

    _tempDirectoryPathFuture ??= getTemporaryDirectory().then(
      (directory) => directory.path,
    );
    try {
      final directoryPath = await _tempDirectoryPathFuture!;
      return '$directoryPath/rec_${++_recordingFileSerial}.m4a';
    } catch (_) {
      _tempDirectoryPathFuture = null;
      rethrow;
    }
  }

  void _consumePreparedRecordingPathErrors(Future<String> future) {
    unawaited(future.catchError((Object _) => ''));
  }

  Future<void> _deleteRecordingFile(String path) async {
    if (kIsWeb || path.isEmpty) return;
    try {
      await java_io.File(path).delete();
    } catch (_) {}
  }

  bool get _canUseRealtimeStreamingStt {
    return kIsWeb &&
        _mode == 'openai' &&
        _pingPongTransportOptimized &&
        _sttModel == 'gpt-realtime-whisper' &&
        !_disposed;
  }

  RealtimeTranscriptionWsService? _createRealtimeStreamingStt(
    String? language,
  ) {
    if (!_canUseRealtimeStreamingStt) return null;
    final lang = (language == null || language.trim().isEmpty)
        ? _micLang
        : language.trim();
    return RealtimeTranscriptionWsService(
      apiKey: widget.apiKey,
      language: lang,
      delay: _realtimeSttDelay,
      prompt: _sttPrompt,
    );
  }

  bool get _usesSystemStt => _sttModel == 'system-stt';

  bool get _isAndroidSystemStt =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _usesSystemStt;

  bool get _isAndroidSystemSttExperimentalOff =>
      _isAndroidSystemStt && !_aiMode && _pauseSeconds >= 30;

  bool _isAndroidSystemSttSilenceSetting(int value) {
    return value == 3 || value == 30 || (value >= 31 && value <= 35);
  }

  int? get _androidSystemSttAutoStopSeconds {
    if (!_isAndroidSystemSttExperimentalOff) return null;
    final seconds = _pauseSeconds - 30;
    return seconds >= 1 && seconds <= 5 ? seconds : null;
  }

  void _cancelPrimarySystemSttAutoStop() {
    _systemSttAutoStopTimer?.cancel();
    _systemSttAutoStopTimer = null;
  }

  void _cancelMirrorSystemSttAutoStop() {
    _mirrorSystemSttAutoStopTimer?.cancel();
    _mirrorSystemSttAutoStopTimer = null;
  }

  void _schedulePrimarySystemSttAutoStop({
    required int serial,
    required int generation,
  }) {
    final seconds = _androidSystemSttAutoStopSeconds;
    if (seconds == null) return;
    _cancelPrimarySystemSttAutoStop();
    _systemSttAutoStopTimer = Timer(Duration(seconds: seconds), () {
      if (_androidSystemSttAutoStopSeconds != seconds ||
          _systemSttStopRequested ||
          !_systemSttAcceptingResults ||
          _systemSttSerial != serial ||
          !_isConversationCurrent(generation)) {
        return;
      }
      unawaited(_stopSystemListening(requestStop: false));
    });
  }

  void _scheduleMirrorSystemSttAutoStop({
    required int serial,
    required int generation,
  }) {
    final seconds = _androidSystemSttAutoStopSeconds;
    if (seconds == null) return;
    _cancelMirrorSystemSttAutoStop();
    _mirrorSystemSttAutoStopTimer = Timer(Duration(seconds: seconds), () {
      if (_androidSystemSttAutoStopSeconds != seconds ||
          _mirrorSystemSttStopRequested ||
          !_mirrorSystemSttAcceptingResults ||
          _mirrorRecordingSerial != serial ||
          !_isConversationCurrent(generation)) {
        return;
      }
      unawaited(_stopMirrorListening());
    });
  }

  String _systemSttLocale(String lang) {
    final language = getLangByCode(lang);
    return kIsWeb ? language.ttsLocale : language.sttLocale;
  }

  String _mergeSystemSttSegments(String committed, String current) {
    final prefix = committed.replaceAll(_whitespacePattern, ' ').trim();
    final suffix = current.replaceAll(_whitespacePattern, ' ').trim();
    if (prefix.isEmpty) return suffix;
    if (suffix.isEmpty) return prefix;
    if (prefix.endsWith(suffix)) return prefix;
    if (suffix.startsWith(prefix)) return suffix;
    return '$prefix $suffix';
  }

  Future<void> _waitForSystemSttFlush(String Function() currentText) async {
    final timeout = currentText().trim().isEmpty
        ? _systemSttEmptyFlushTimeout
        : _systemSttFinalFlushDelay;
    final clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (currentText().trim().isNotEmpty &&
          clock.elapsed >= _systemSttFinalFlushDelay) {
        return;
      }
    }
  }

  Future<void> _startSystemSttFallbackRecorder(
    String owner, {
    required String sttLang,
  }) async {
    if (!kIsWeb) return;
    try {
      final hasPermission = await _ensureMicPermission();
      if (!hasPermission) {
        return;
      }
      await _startRecorderForOwner(owner, sttLang: sttLang);
    } catch (e) {
      // System STT is experimental; missing fallback recording should not
      // interrupt the system recognizer path.
    }
  }

  Future<_StoppedRecording?> _stopSystemSttFallbackRecorder(
    String owner, {
    required Future<void>? startFuture,
  }) async {
    if (!kIsWeb) return null;
    if (startFuture != null) {
      try {
        await startFuture;
      } catch (_) {}
    }
    return _stopRecorderIfOwner(owner);
  }

  String get _restSttModel {
    return (_sttModel == 'gpt-realtime-whisper' || _usesSystemStt)
        ? 'gpt-4o-mini-transcribe'
        : _sttModel;
  }

  bool get _canRun4oSttBenchmark {
    return _sttBenchmarkEnabled &&
        (_restSttModel == 'gpt-4o-mini-transcribe' ||
            _restSttModel == 'gpt-4o-transcribe');
  }

  Future<void> _startRecorderForOwner(
    String owner, {
    String? path,
    String? sttLang,
  }) async {
    if (kIsWeb) {
      final chunks = <Uint8List>[];
      final done = Completer<void>();
      final realtimeStt = _createRealtimeStreamingStt(sttLang);
      _recordStreamChunks = chunks;
      _recordStreamDone = done;
      _streamRecorderOwner = owner;
      _recordStreamRealtimeStt = realtimeStt;
      _recordStreamRealtimeSttOwner = realtimeStt == null ? null : owner;
      if (realtimeStt != null) {
        unawaited(realtimeStt.start().catchError((Object _) {}));
      }
      try {
        final stream = await _recorder.startStream(_openAIStreamRecordConfig);
        _recordStreamSub = stream.listen(
          (chunk) {
            chunks.add(chunk);
            realtimeStt?.appendPcm16(chunk);
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
        _activeRecorderOwner = owner;
      } catch (_) {
        _streamRecorderOwner = null;
        _recordStreamChunks = null;
        _recordStreamDone = null;
        _recordStreamRealtimeStt = null;
        _recordStreamRealtimeSttOwner = null;
        unawaited(realtimeStt?.stop());
        await _recordStreamSub?.cancel();
        _recordStreamSub = null;
        rethrow;
      }
      return;
    }

    await _recorder.start(_openAIRecordConfig, path: path ?? '');
    _activeRecorderOwner = owner;
  }

  Future<_StoppedRecording?> _stopRecorderIfOwner(String owner) async {
    if (_activeRecorderOwner != owner) return null;
    final streamOwner = kIsWeb && _streamRecorderOwner == owner;
    final realtimeStt = _recordStreamRealtimeSttOwner == owner
        ? _recordStreamRealtimeStt
        : null;
    try {
      final path = await _recorder.stop();
      if (!streamOwner) {
        return (
          path: path ?? '',
          bytes: null,
          filename: 'audio.m4a',
          realtimeStt: null,
        );
      }

      try {
        await _recordStreamDone?.future.timeout(
          const Duration(milliseconds: 160),
          onTimeout: () {},
        );
      } finally {
        await _recordStreamSub?.cancel();
      }

      final chunks = _recordStreamChunks ?? const <Uint8List>[];
      final bytes = chunks.isEmpty
          ? Uint8List(0)
          : pcm16ToWav(
              chunks,
              sampleRate: _webStreamSampleRate,
              numChannels: _webStreamChannels,
            );
      return (
        path: '',
        bytes: bytes,
        filename: 'audio.wav',
        realtimeStt: realtimeStt,
      );
    } finally {
      if (_activeRecorderOwner == owner) {
        _activeRecorderOwner = null;
      }
      if (_streamRecorderOwner == owner) {
        _streamRecorderOwner = null;
        _recordStreamSub = null;
        _recordStreamDone = null;
        _recordStreamChunks = null;
        _recordStreamRealtimeStt = null;
        _recordStreamRealtimeSttOwner = null;
      }
    }
  }

  Future<void> _startOpenAIRecording({
    String? forceDirection,
    bool startingUiAlreadySet = false,
  }) async {
    if (_isRecording ||
        (_isRecordingStarting && !startingUiAlreadySet) ||
        _isMirrorStarting ||
        (_aiMode && _isProcessing)) {
      return;
    }
    var ownsStartingUi = startingUiAlreadySet;
    if (!startingUiAlreadySet) {
      _setPrimaryRecordingStartingUi(_micLang, '녹음 준비 중...');
      ownsStartingUi = true;
    }
    _stopPlaybackForRecording();
    final pathFuture = kIsWeb ? null : _recordingPath();
    if (pathFuture != null) _consumePreparedRecordingPathErrors(pathFuture);
    await _stopAll(processRecordingsInBackground: true);
    if (_isRecording ||
        (_isRecordingStarting && !ownsStartingUi) ||
        _isMirrorStarting ||
        (_aiMode && _isProcessing)) {
      if (ownsStartingUi) {
        if (mounted) {
          setState(() {
            _isRecordingStarting = false;
            if (!_isRecording &&
                (_interimText == '녹음 준비 중...' ||
                    _interimText == '녹음 전환 중...')) {
              _setInterimTextValue('');
            }
          });
        } else {
          _isRecordingStarting = false;
        }
      }
      return;
    }
    try {
      if (!mounted) return;

      final permissionFuture = _ensureMicPermission();
      final hasPermission = await permissionFuture;
      if (!hasPermission) {
        _showError('마이크 권한이 필요합니다');
        return;
      }

      final path = pathFuture == null ? null : await pathFuture;
      final startSttLang = forceDirection == 'target2source'
          ? _targetLang
          : _micLang;
      _prewarmSystemTtsForDirection(forceDirection: forceDirection);
      await _startRecorderForOwner(
        _primaryRecorderOwner,
        path: path,
        sttLang: startSttLang,
      );
      _prewarmPingPongTextWsIfNeeded(includePostProcess: true);
      if (!mounted) {
        await _stopRecorderIfOwner(_primaryRecorderOwner);
        return;
      }

      _recordingSerial++;
      setState(() {
        _isRecordingStarting = false;
        _isRecording = true;
        _setInterimTextValue('녹음 중...');
      });

      // Silence detection
      final effectivePause = _aiMode ? _aiPauseSeconds : _pauseSeconds;
      if (effectivePause < 30) {
        // 30 = OFF
        final silenceTimeout = Duration(seconds: effectivePause);
        _ampSub = _recorder
            .onAmplitudeChanged(const Duration(milliseconds: 200))
            .listen((amp) {
              if (amp.current < _noiseThreshold) {
                if (_silenceTimer != null) return;
                _silenceTimer = Timer(silenceTimeout, () {
                  if (_isRecording) {
                    unawaited(
                      _stopOpenAIRecording(forceDirection: forceDirection),
                    );
                  }
                });
              } else {
                // Sound detected — reset timer
                _silenceTimer?.cancel();
                _silenceTimer = null;
              }
            });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRecordingStarting = false;
        _isRecording = false;
        _setInterimTextValue('');
      });
      _showError(e.toString());
    } finally {
      if (_isRecordingStarting) {
        if (mounted) {
          setState(() {
            _isRecordingStarting = false;
            if (!_isRecording &&
                (_interimText == '녹음 준비 중...' ||
                    _interimText == '녹음 전환 중...')) {
              _setInterimTextValue('');
            }
          });
        } else {
          _isRecordingStarting = false;
        }
      }
    }
  }

  Future<void> _stopOpenAIRecording({
    String? forceDirection,
    bool processInBackground = true,
  }) {
    final existing = _recordingStopFuture;
    if (existing != null) return existing;
    if (_isRecordingStarting && !_isRecording) return Future.value();
    if (!_isRecording) return Future.value();

    late final Future<void> tracked;
    tracked =
        _stopOpenAIRecordingInternal(
          forceDirection: forceDirection,
          processInBackground: processInBackground,
        ).whenComplete(() {
          if (_recordingStopFuture == tracked) {
            _recordingStopFuture = null;
          }
        });
    _recordingStopFuture = tracked;
    return tracked;
  }

  Future<void> _stopOpenAIRecordingInternal({
    required String? forceDirection,
    required bool processInBackground,
  }) async {
    final timing = Stopwatch()..start();
    _logPingPongTiming('record_stop_clicked', timing);
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _ampSub?.cancel();
    _ampSub = null;

    final serial = _recordingSerial;
    final generation = _conversationGeneration;
    final sttLang = forceDirection == 'target2source' ? _targetLang : _micLang;
    final shouldAskAI = _aiMode;
    _prewarmSystemTtsForDirection(forceDirection: forceDirection);
    if (mounted) {
      setState(() {
        _isRecording = false;
        _setInterimTextValue('음성 인식 중...');
      });
    }
    final recording = await _stopRecorderIfOwner(_primaryRecorderOwner);
    _logPingPongTiming('recorder_stop_done', timing);
    if (recording == null) {
      _clearPrimaryInterimIfCurrent(serial);
      return;
    }
    _logPingPongTiming('audio_bytes_ready', timing);

    final processing = _processPrimaryRecording(
      recording,
      serial: serial,
      generation: generation,
      sttLang: sttLang,
      forceDirection: forceDirection,
      askAI: shouldAskAI,
      timing: timing,
    );
    if (processInBackground) {
      unawaited(processing);
    } else {
      await processing;
    }
  }

  void _clearPrimaryInterimIfCurrent(int serial) {
    if (!mounted ||
        _recordingSerial != serial ||
        _isRecording ||
        _isRecordingStarting) {
      return;
    }
    if (_interimText.isEmpty) return;
    _setInterimTextValue('');
  }

  void _clearMirrorInterimIfCurrent(int serial) {
    if (!mounted ||
        _mirrorRecordingSerial != serial ||
        _isMirrorListening ||
        _isMirrorStarting) {
      return;
    }
    if (_mirrorInterimText.isEmpty) return;
    _setMirrorInterimTextValue('');
  }

  String _pingPongSttDraftTurnId(String owner, int serial) {
    return 'pp-stt-$owner-$serial';
  }

  String? _pingPongSttDraftOwner(String? turnId) {
    if (turnId == null) return null;
    if (turnId.startsWith('pp-stt-$_primaryRecorderOwner-')) {
      return _primaryRecorderOwner;
    }
    if (turnId.startsWith('pp-stt-$_mirrorRecorderOwner-')) {
      return _mirrorRecorderOwner;
    }
    return null;
  }

  bool _canRetryPingPongMessage(ChatMessage message) {
    final turnId = message.turnId;
    return _mode == 'openai' &&
        !_aiMode &&
        _usesSystemStt &&
        turnId != null &&
        _retryablePingPongTurnIds.contains(turnId) &&
        _pingPongSttDraftOwner(turnId) != null;
  }

  Future<void> _retryPingPongMessage(ChatMessage message) async {
    final turnId = message.turnId;
    final owner = _pingPongSttDraftOwner(turnId);
    if (turnId == null || owner == null || !_canRetryPingPongMessage(message)) {
      return;
    }

    final retryTargetToSource = message.direction == _targetToSourceDirection;
    final retryLang = retryTargetToSource ? _targetLang : _sourceLang;
    final retryDirection = retryTargetToSource
        ? 'target2source'
        : 'source2target';

    _stopPlaybackForRecording();
    _invalidateConversationWork();
    final keepAtBottom = _shouldKeepChatAtBottom();
    if (mounted) {
      setState(() {
        _retryablePingPongTurnIds.remove(turnId);
        _messages.removeWhere((candidate) => candidate.turnId == turnId);
        _setInterimTextPair('', '');
      });
      if (keepAtBottom) _scrollToBottom();
    } else {
      _retryablePingPongTurnIds.remove(turnId);
      _messages.removeWhere((candidate) => candidate.turnId == turnId);
    }

    await _cancelPingPongSystemCapture(owner);
    if (!mounted || _mode != 'openai' || !_usesSystemStt || _aiMode) return;

    if (owner == _mirrorRecorderOwner) {
      await _startMirrorListening();
    } else {
      await _startSystemListening(
        lang: retryLang,
        forceDirection: retryDirection,
      );
    }
  }

  Future<void> _cancelPingPongSystemCapture(String owner) async {
    if (owner == _mirrorRecorderOwner) {
      final fallbackStart = _mirrorSystemSttFallbackRecorderStart;
      _mirrorSystemSttFallbackRecorderStart = null;
      _mirrorSystemSttAcceptingResults = false;
      _mirrorSystemSttText = '';
      _mirrorSystemSttError = null;
      _mirrorSystemSttCommittedText = '';
      _mirrorSystemSttRestartFuture = null;
      _mirrorSystemSttSegmentHadText = false;
      _cancelMirrorSystemSttAutoStop();
      _mirrorRecordingSerial++;
      if (_speech.isListening) {
        await _speech.stopListening().catchError((Object _) {});
      }
      await _stopSystemSttFallbackRecorder(
        _mirrorRecorderOwner,
        startFuture: fallbackStart,
      );
      if (mounted) {
        setState(() {
          _isMirrorListening = false;
          _isMirrorStarting = false;
          _mirrorUsesOpenAIRecording = false;
          _setMirrorInterimTextValue('');
        });
      } else {
        _isMirrorListening = false;
        _isMirrorStarting = false;
        _mirrorUsesOpenAIRecording = false;
      }
      return;
    }

    final fallbackStart = _systemSttFallbackRecorderStart;
    _systemSttFallbackRecorderStart = null;
    _systemSttAcceptingResults = false;
    _systemSttText = '';
    _systemSttError = null;
    _systemSttCommittedText = '';
    _systemSttRestartFuture = null;
    _systemSttSegmentHadText = false;
    _cancelPrimarySystemSttAutoStop();
    _recordingSerial++;
    if (_speech.isListening) {
      await _speech.stopListening().catchError((Object _) {});
    }
    await _stopSystemSttFallbackRecorder(
      _primaryRecorderOwner,
      startFuture: fallbackStart,
    );
    if (mounted) {
      setState(() {
        _isListening = false;
        _isRecordingStarting = false;
        _setInterimTextValue('');
      });
    } else {
      _isListening = false;
      _isRecordingStarting = false;
    }
  }

  String _pingPongDirectionForForce(String? forceDirection) {
    return forceDirection == 'target2source'
        ? _targetToSourceDirection
        : _sourceToTargetDirection;
  }

  void _upsertPingPongSttDraft({
    required String turnId,
    required String text,
    required String direction,
    required int generation,
    required bool mirror,
  }) {
    if (!mounted || !_isConversationCurrent(generation)) return;
    final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
    if (normalized.isEmpty) return;

    final keepAtBottom = _shouldKeepChatAtBottom();
    setState(() {
      final existingIndex = _messages.lastIndexWhere(
        (message) => message.turnId == turnId,
      );
      _retryablePingPongTurnIds.add(turnId);
      final draft = ChatMessage(
        original: normalized,
        translated: normalized,
        direction: direction,
        turnId: turnId,
      );
      if (existingIndex >= 0) {
        final current = _messages[existingIndex];
        if (current.original == normalized &&
            current.translated == normalized) {
          return;
        }
        _messages[existingIndex] = draft;
      } else {
        _messages.add(draft);
      }
      if (mirror) {
        _setMirrorInterimTextValue('');
      } else {
        _setInterimTextValue('');
      }
    });
    if (keepAtBottom) _scrollToBottom();
  }

  void _applyPrimarySttInterim({
    required int serial,
    required int generation,
    required String text,
    required String? forceDirection,
  }) {
    if (!mounted ||
        _recordingSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
    if (normalized.isEmpty) return;
    _upsertPingPongSttDraft(
      turnId: _pingPongSttDraftTurnId(_primaryRecorderOwner, serial),
      text: normalized,
      direction: _pingPongDirectionForForce(forceDirection),
      generation: generation,
      mirror: false,
    );
  }

  void _applyMirrorSttInterim({
    required int serial,
    required int generation,
    required String text,
  }) {
    if (!mounted ||
        _mirrorRecordingSerial != serial ||
        !_isConversationCurrent(generation)) {
      return;
    }
    final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
    if (normalized.isEmpty) return;
    _upsertPingPongSttDraft(
      turnId: _pingPongSttDraftTurnId(_mirrorRecorderOwner, serial),
      text: normalized,
      direction: _targetToSourceDirection,
      generation: generation,
      mirror: true,
    );
  }

  Future<void> _processPrimaryRecording(
    _StoppedRecording recording, {
    required int serial,
    required int generation,
    required String sttLang,
    required String? forceDirection,
    required bool askAI,
    Stopwatch? timing,
  }) async {
    try {
      final partialText = StringBuffer();
      final text = await _transcribeRecording(
        recording,
        sttLang,
        timing: timing,
        onDelta: (delta) {
          partialText.write(delta);
          _applyPrimarySttInterim(
            serial: serial,
            generation: generation,
            text: partialText.toString(),
            forceDirection: forceDirection,
          );
        },
      );
      _clearPrimaryInterimIfCurrent(serial);
      if (!_isConversationCurrent(generation)) return;

      if (text.isNotEmpty) {
        final draftTurnId = _pingPongSttDraftTurnId(
          _primaryRecorderOwner,
          serial,
        );
        final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
        if (!askAI) {
          _upsertPingPongSttDraft(
            turnId: draftTurnId,
            text: normalized,
            direction: _pingPongDirectionForForce(forceDirection),
            generation: generation,
            mirror: false,
          );
        }
        if (askAI) {
          _handleAIQuestion(text, generation: generation);
        } else {
          _enqueueTranslation(
            text,
            forceDirection: forceDirection,
            generation: generation,
            timing: timing,
            draftTurnId: draftTurnId,
          );
        }
      }
    } catch (e) {
      _clearPrimaryInterimIfCurrent(serial);
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _processMirrorRecording(
    _StoppedRecording recording, {
    required int serial,
    required int generation,
  }) async {
    try {
      final partialText = StringBuffer();
      final text = await _transcribeRecording(
        recording,
        _targetLang,
        onDelta: (delta) {
          partialText.write(delta);
          _applyMirrorSttInterim(
            serial: serial,
            generation: generation,
            text: partialText.toString(),
          );
        },
      );
      _clearMirrorInterimIfCurrent(serial);
      if (!_isConversationCurrent(generation)) return;
      if (text.isNotEmpty) {
        final draftTurnId = _pingPongSttDraftTurnId(
          _mirrorRecorderOwner,
          serial,
        );
        final normalized = text.replaceAll(_whitespacePattern, ' ').trim();
        _upsertPingPongSttDraft(
          turnId: draftTurnId,
          text: normalized,
          direction: _targetToSourceDirection,
          generation: generation,
          mirror: true,
        );
        _enqueueTranslation(
          text,
          forceDirection: 'target2source',
          generation: generation,
          draftTurnId: draftTurnId,
        );
      }
    } catch (e) {
      _clearMirrorInterimIfCurrent(serial);
      if (mounted) _showError(e.toString());
    }
  }

  Future<String> _transcribeRecording(
    _StoppedRecording recording,
    String lang, {
    Stopwatch? timing,
    ValueChanged<String>? onDelta,
  }) async {
    final realtimeStt = recording.realtimeStt;
    if (realtimeStt != null) {
      try {
        realtimeStt.onDelta = (delta) {
          if (delta.isNotEmpty) onDelta?.call(delta);
        };
        if (timing != null) _logPingPongTiming('stt_ws_commit', timing);
        var firstDeltaSeen = false;
        final originalOnDelta = realtimeStt.onDelta;
        realtimeStt.onDelta = (delta) {
          originalOnDelta?.call(delta);
          if (firstDeltaSeen || timing == null) return;
          firstDeltaSeen = true;
          _logPingPongTiming('stt_ws_first_delta', timing);
        };
        final text = await realtimeStt.commitAndWait();
        if (timing != null) _logPingPongTiming('stt_ws_done', timing);
        if (text.trim().isNotEmpty) {
          return text.trim();
        }
      } catch (e) {
        debugPrint('[PP-STT] realtime transcription fallback: $e');
      } finally {
        unawaited(realtimeStt.stop());
      }
    }

    final bytes = recording.bytes;
    if (bytes != null) {
      if (bytes.isEmpty || bytes.length < 1000) return '';
      final benchmarkText = await _tryRun4oSttBenchmark(
        bytes,
        lang,
        filename: recording.filename,
        onDelta: onDelta,
        timing: timing,
      );
      if (benchmarkText != null) return benchmarkText;
      if (timing != null) _logPingPongTiming('stt_request_sent', timing);
      var firstDeltaSeen = false;
      final text = await _openai.stt(
        bytes,
        lang,
        model: _restSttModel,
        prompt: _sttPrompt,
        filename: recording.filename,
        stream: _pingPongTransportOptimized,
        onTiming: timing == null
            ? null
            : (event) => _logPingPongTiming(event, timing),
        onDelta: (delta) {
          if (delta.isNotEmpty) onDelta?.call(delta);
          if (firstDeltaSeen || timing == null) return;
          firstDeltaSeen = true;
          _logPingPongTiming('stt_first_delta', timing);
        },
      );
      if (timing != null) _logPingPongTiming('stt_done', timing);
      return text;
    }

    final path = recording.path;
    if (kIsWeb) {
      try {
        final bytes = await _readFileBytes(path);
        if (bytes.isEmpty || bytes.length < 1000) return '';
        final benchmarkText = await _tryRun4oSttBenchmark(
          bytes,
          lang,
          filename: recording.filename,
          onDelta: onDelta,
          timing: timing,
        );
        if (benchmarkText != null) return benchmarkText;
        if (timing != null) _logPingPongTiming('stt_request_sent', timing);
        var firstDeltaSeen = false;
        final text = await _openai.stt(
          bytes,
          lang,
          model: _restSttModel,
          prompt: _sttPrompt,
          filename: recording.filename,
          stream: _pingPongTransportOptimized,
          onTiming: timing == null
              ? null
              : (event) => _logPingPongTiming(event, timing),
          onDelta: (delta) {
            if (delta.isNotEmpty) onDelta?.call(delta);
            if (firstDeltaSeen || timing == null) return;
            firstDeltaSeen = true;
            _logPingPongTiming('stt_first_delta', timing);
          },
        );
        if (timing != null) _logPingPongTiming('stt_done', timing);
        return text;
      } finally {
        revokeBlobUrl(path);
      }
    }

    try {
      final file = java_io.File(path);
      final length = await file.length();
      if (length < 1000) return '';
      if (timing != null) _logPingPongTiming('stt_request_sent', timing);
      var firstDeltaSeen = false;
      final text = await _openai.sttFile(
        path,
        lang,
        model: _restSttModel,
        prompt: _sttPrompt,
        filename: recording.filename,
        stream: _pingPongTransportOptimized,
        onTiming: timing == null
            ? null
            : (event) => _logPingPongTiming(event, timing),
        onDelta: (delta) {
          if (delta.isNotEmpty) onDelta?.call(delta);
          if (firstDeltaSeen || timing == null) return;
          firstDeltaSeen = true;
          _logPingPongTiming('stt_first_delta', timing);
        },
      );
      if (timing != null) _logPingPongTiming('stt_done', timing);
      return text;
    } finally {
      unawaited(_deleteRecordingFile(path));
    }
  }

  Future<String?> _tryRun4oSttBenchmark(
    Uint8List audioBytes,
    String lang, {
    required String filename,
    Stopwatch? timing,
    ValueChanged<String>? onDelta,
  }) async {
    if (!_canRun4oSttBenchmark) return null;
    const models = ['gpt-4o-mini-transcribe', 'gpt-4o-transcribe'];
    final selectedModel = _restSttModel;
    if (!models.contains(selectedModel)) return null;

    _logSttBenchmark(
      () =>
          'start selected=$selectedModel lang=$lang bytes=${audioBytes.length}',
    );
    final requestClock = Stopwatch()..start();
    final futures = <String, Future<_SttBenchmarkResult>>{
      for (final model in models)
        model: _runSttBenchmarkModel(
          audioBytes,
          lang,
          model: model,
          filename: filename,
          onDelta: model == selectedModel ? onDelta : null,
          timing: model == selectedModel ? timing : null,
        ),
    };

    Future<({_SttBenchmarkResult? result, Object? error})> settle(
      Future<_SttBenchmarkResult> future,
    ) {
      return future.then<({_SttBenchmarkResult? result, Object? error})>(
        (result) => (result: result, error: null),
        onError: (Object error) => (result: null, error: error),
      );
    }

    unawaited(
      Future.wait([for (final model in models) settle(futures[model]!)]).then((
        settled,
      ) {
        final results = <String, _SttBenchmarkResult>{};
        for (var i = 0; i < models.length; i++) {
          final model = models[i];
          final settledItem = settled[i];
          final result = settledItem.result;
          if (result == null) {
            _logSttBenchmark(() => '$model error=${settledItem.error}');
            continue;
          }
          results[model] = result;
          _logSttBenchmark(
            () =>
                '$model first=${result.firstDeltaMs ?? -1}ms '
                'done=${result.doneMs}ms chars=${result.text.length}',
          );
        }

        final mini = results['gpt-4o-mini-transcribe'];
        final full = results['gpt-4o-transcribe'];
        if (mini != null && full != null) {
          final faster = mini.doneMs <= full.doneMs
              ? 'gpt-4o-mini-transcribe'
              : 'gpt-4o-transcribe';
          _logSttBenchmark(
            () =>
                'winner=$faster total=${requestClock.elapsedMilliseconds}ms '
                'deltaDone=${(full.doneMs - mini.doneMs).abs()}ms '
                'sameText=${mini.text.trim() == full.text.trim()}',
          );
        }
      }),
    );

    try {
      final result = await futures[selectedModel]!;
      _logSttBenchmark(
        () =>
            'selected=$selectedModel returned=${result.doneMs}ms '
            'chars=${result.text.length}',
      );
      if (result.text.trim().isNotEmpty) return result.text;
      for (final model in models) {
        if (model == selectedModel) continue;
        try {
          final fallback = await futures[model]!;
          if (fallback.text.trim().isEmpty) continue;
          _logSttBenchmark(
            () =>
                'selectedEmptyFallback=$model returned=${fallback.doneMs}ms '
                'chars=${fallback.text.length}',
          );
          return fallback.text;
        } catch (_) {}
      }
      return result.text;
    } catch (error) {
      _logSttBenchmark(() => '$selectedModel selectedError=$error');
      for (final model in models) {
        if (model == selectedModel) continue;
        try {
          final fallback = await futures[model]!;
          if (fallback.text.trim().isEmpty) continue;
          _logSttBenchmark(
            () =>
                'selectedErrorFallback=$model returned=${fallback.doneMs}ms '
                'chars=${fallback.text.length}',
          );
          return fallback.text;
        } catch (_) {}
      }
      return null;
    }
  }

  Future<_SttBenchmarkResult> _runSttBenchmarkModel(
    Uint8List audioBytes,
    String lang, {
    required String model,
    required String filename,
    Stopwatch? timing,
    ValueChanged<String>? onDelta,
  }) async {
    final clock = Stopwatch()..start();
    if (timing != null) _logPingPongTiming('stt_bench_request_sent', timing);
    int? firstDeltaMs;
    final text = await _openai.stt(
      audioBytes,
      lang,
      model: model,
      prompt: _sttPrompt,
      filename: filename,
      stream: _pingPongTransportOptimized,
      onDelta: (delta) {
        if (delta.isNotEmpty) onDelta?.call(delta);
        if (firstDeltaMs != null) return;
        firstDeltaMs = clock.elapsedMilliseconds;
        if (timing != null) _logPingPongTiming('stt_bench_first_delta', timing);
      },
    );
    if (timing != null) _logPingPongTiming('stt_bench_done', timing);
    return (
      model: model,
      text: text,
      firstDeltaMs: firstDeltaMs,
      doneMs: clock.elapsedMilliseconds,
    );
  }

  Future<Uint8List> _readFileBytes(String path) async {
    try {
      if (kIsWeb) {
        // Web: path is a blob URL
        final response = await _blobHttpClient.get(Uri.parse(path));
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

  // Push VAD / turn-detection changes to live realtime sessions via
  // session.update so tuning applies without restarting the session.
  void _applyTurnDetectionLive() {
    if (!_realtimeActive) return;
    for (final rt in [_realtime, _realtimeA, _realtimeB]) {
      rt?.updateTurnDetection(
        turnDetectionType: _turnDetectionType,
        vadThreshold: _vadThreshold,
        silenceDurationMs: _silenceDurationMs,
        vadEagerness: _vadEagerness,
      );
    }
  }

  void _updateRealtimeAudioMute() {
    if (_realtimeActive) {
      _realtime?.muteAudio(!_ttsTargetEnabled);
      if (_isLiveTranslateMode) {
        _configureLiveTranslateAudioRoutes();
        _logLiveTranslate(
          () =>
              'audioMuteUpdate enabled=$_liveTranslateAudioEnabled '
              'paused=$_directionalPaused active=$_activeDirectionalSession '
              'route=$_liveTranslateAudioRoute',
        );
        _applyLiveTranslateAudioMute();
      } else {
        _realtimeTranslate?.muteAudio(true);
        _realtimeTranslateB?.muteAudio(true);
        _applyNativeLiveTranslateAudioPan(null);
      }
      if (_isDirectionalMode) {
        _realtimeA?.muteAudio(!_ttsTargetEnabled); // A outputs target lang
        _realtimeB?.muteAudio(!_ttsSourceEnabled); // B outputs source lang
      }
    } else {
      _applyNativeLiveTranslateAudioPan(null);
    }
  }

  void _clearRealtimeTurn(RealtimeService? service, String? responseId) {
    if (service == null || responseId == null) return;
    service.removeTurn(responseId);
  }

  void _discardRealtimePostProcessor() {
    _rtPostProcessorStartFuture = null;
    _rtPostProcessorStartKey = null;
    _rtPostProcessor?.stop();
    _rtPostProcessor = null;
    _rtPostProcessorKey = null;
    _rtPostProcessQueue = Future.value();
  }

  ResponsesTextWsService _ensurePingPongTextWs(String purpose) {
    final current = _pingPongTextWsServices[purpose];
    if (current != null) return current;
    final proxyUri = _pingPongWebWsProxyUri;
    return _pingPongTextWsServices[purpose] = ResponsesTextWsService(
      apiKey: widget.apiKey,
      uri: proxyUri,
      sendApiKey: proxyUri == null,
    );
  }

  void _discardPingPongTextWs([String? purpose]) {
    if (purpose != null) {
      final service = _pingPongTextWsServices.remove(purpose);
      unawaited(service?.stop());
      return;
    }
    for (final service in _pingPongTextWsServices.values) {
      unawaited(service.stop());
    }
    _pingPongTextWsServices.clear();
  }

  bool get _canUsePingPongWs {
    if (_mode != 'openai' || !_pingPongTransportOptimized || _disposed) {
      return false;
    }
    // Browser WebSocket APIs cannot set the Authorization header required by
    // /v1/responses, so web needs a backend proxy that injects the API key.
    if (kIsWeb) return _pingPongWebWsProxyUri != null;
    return true;
  }

  Uri? get _pingPongWebWsProxyUri {
    if (!kIsWeb) return null;
    final value = _pingPongWebWsProxyUrl.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      return null;
    }
    return uri;
  }

  void _prewarmPingPongTextWsIfNeeded({bool includePostProcess = false}) {
    if (!_canUsePingPongWs) return;
    unawaited(
      _ensurePingPongTextWs('translation').start().catchError((Object _) {}),
    );
    if (!includePostProcess) return;
    if (_backTranslateSource || _backTranslateTarget) {
      unawaited(
        _ensurePingPongTextWs(
          'backTranslation',
        ).start().catchError((Object _) {}),
      );
    }
    if (_showPronunciation) {
      unawaited(
        _ensurePingPongTextWs(
          'pronunciation',
        ).start().catchError((Object _) {}),
      );
    }
  }

  Future<String?> _tryPingPongWsText({
    required String purpose,
    required String model,
    required String instructions,
    required String text,
    List<Map<String, String>> context = const [],
    bool jsonObject = false,
    double? temperature,
    String? reasoningEffort,
    int maxOutputTokens = 512,
    Stopwatch? timing,
    String? timingPrefix,
    Duration timeout = const Duration(seconds: 20),
    ValueChanged<String>? onTextDelta,
  }) async {
    if (!_canUsePingPongWs) return null;
    var firstDeltaSeen = false;
    try {
      final service = _ensurePingPongTextWs(purpose);
      await service.start();
      if (timing != null && timingPrefix != null) {
        _logPingPongTiming('${timingPrefix}_ws_ready', timing);
      }
      if (timing != null && timingPrefix != null) {
        _logPingPongTiming('${timingPrefix}_ws_request_sent', timing);
      }
      final result = await service.sendTextForResult(
        model: model,
        instructions: instructions,
        text: text,
        context: context,
        jsonObject: jsonObject,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        maxOutputTokens: maxOutputTokens,
        timeout: timeout,
        onDelta: (delta) {
          if (delta.isNotEmpty) onTextDelta?.call(delta);
          if (firstDeltaSeen || timing == null || timingPrefix == null) return;
          firstDeltaSeen = true;
          _logPingPongTiming('${timingPrefix}_first_delta', timing);
        },
      );
      if (timing != null && timingPrefix != null) {
        _logPingPongTiming('${timingPrefix}_done', timing);
      }
      return result;
    } catch (error) {
      _logPingPongWs(() => 'error purpose=$purpose error=$error');
      _discardPingPongTextWs(purpose);
      return null;
    }
  }

  void _cancelPendingInterimUpdate() {
    _interimUpdateTimer?.cancel();
    _interimUpdateTimer = null;
    _pendingInterimTurn = null;
  }

  void _applyInterimText(String text, {String? mirrorText}) {
    if (!mounted) return;
    final nextMirrorText = mirrorText ?? text;
    if (_interimText == text && _mirrorInterimText == nextMirrorText) return;
    _lastInterimUpdateMs = _interimClock.elapsedMilliseconds;
    _setInterimTextPair(text, nextMirrorText);
  }

  String _realtimeTurnInterimText(RealtimeTurn turn) {
    final input = turn.input.replaceAll(_whitespacePattern, ' ').trim();
    final output = turn.output.replaceAll(_whitespacePattern, ' ').trim();
    if (input.isNotEmpty && output.isNotEmpty) {
      return '$input\n→ $output';
    }
    if (input.isNotEmpty) return '$input · 번역 중...';
    return output;
  }

  void _setRealtimeInputTranscriptInterim(
    RealtimeService service,
    String? itemId,
  ) {
    if (itemId == null) return;
    final responseId = service.getResponseIdForItem(itemId);
    final turn = responseId != null ? service.turns[responseId] : null;
    if (turn != null) {
      _setRealtimeTurnInterimThrottled(turn);
      return;
    }
    final transcript = service
        .inputTranscriptForItem(itemId)
        .replaceAll(_whitespacePattern, ' ')
        .trim();
    if (transcript.isEmpty) return;
    _applyInterimText(
      '$transcript · 번역 중...',
      mirrorText: '$transcript · 翻訳中...',
    );
  }

  void _rememberRealtimeInputMessage({
    required String? itemId,
    required int index,
    required int generation,
  }) {
    if (itemId == null) return;
    _realtimeInputItemMessageIndex[itemId] = (
      index: index,
      generation: generation,
    );
  }

  void _applyRealtimeInputTranscriptToMessage(
    String? itemId,
    Object? transcript,
  ) {
    if (itemId == null || transcript == null) return;
    final text = transcript
        .toString()
        .replaceAll(_whitespacePattern, ' ')
        .trim();
    if (text.isEmpty) return;
    final target = _realtimeInputItemMessageIndex[itemId];
    if (target == null) return;
    if (!_isConversationCurrent(target.generation) ||
        target.index < 0 ||
        target.index >= _messages.length) {
      _realtimeInputItemMessageIndex.remove(itemId);
      return;
    }
    final cur = _messages[target.index];
    if (cur.original == text) return;
    final keepAtBottom = _shouldKeepChatAtBottom();
    setState(() {
      _messages[target.index] = ChatMessage(
        original: text,
        translated: cur.translated,
        backTranslation: cur.backTranslation,
        pronunciation: cur.pronunciation,
        direction: cur.direction,
        isAI: cur.isAI,
        turnId: cur.turnId,
      );
    });
    if (keepAtBottom) _scrollToBottom();
  }

  void _setRealtimeTurnInterimThrottled(RealtimeTurn turn) {
    _pendingInterimTurn = turn;

    final lastUpdateMs = _lastInterimUpdateMs;
    final nowMs = _interimClock.elapsedMilliseconds;
    final elapsedMs = lastUpdateMs == null ? 100 : nowMs - lastUpdateMs;
    const minIntervalMs = 80;

    if (elapsedMs >= minIntervalMs) {
      _interimUpdateTimer?.cancel();
      _interimUpdateTimer = null;
      final pendingTurn = _pendingInterimTurn;
      _pendingInterimTurn = null;
      if (pendingTurn != null) {
        _applyInterimText(_realtimeTurnInterimText(pendingTurn));
      }
      return;
    }

    if (_interimUpdateTimer?.isActive ?? false) return;
    _interimUpdateTimer = Timer(
      Duration(milliseconds: minIntervalMs - elapsedMs),
      () {
        _interimUpdateTimer = null;
        final pendingTurn = _pendingInterimTurn;
        _pendingInterimTurn = null;
        if (pendingTurn != null) {
          _applyInterimText(_realtimeTurnInterimText(pendingTurn));
        }
      },
    );
  }

  void _flashInterimText(
    String text, {
    String? mirrorText,
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    final peerText = mirrorText ?? text;
    _cancelPendingInterimUpdate();
    _interimFlashTimer?.cancel();
    if (!mounted) return;
    _setInterimTextPair(text, peerText);
    _interimFlashTimer = Timer(duration, () {
      if (!mounted) return;
      if (_interimText == text) _setInterimTextValue('');
      if (_mirrorInterimText == peerText) _setMirrorInterimTextValue('');
    });
  }

  void _resetLiveTranslateBuffers() {
    _liveTranslateCommitTimer?.cancel();
    _liveTranslateCommitTimer = null;
    _liveTranslateBufferSession = null;
    _liveTranslateOutputBuffer = StringBuffer();
    _liveTranslateLastOutputLogAt = null;
    _liveTranslateOutputEventCount = 0;
  }

  void _resetLiveTranslateWatchdog() {
    _liveTranslateLastServerEventAt = null;
    _liveTranslateLastNoServerLogAt = null;
  }

  String _liveTranslateOutputText() => _liveTranslateOutputBuffer
      .toString()
      .replaceAll(_whitespacePattern, ' ')
      .trim();

  StringBuffer _mergeLiveTranslateFinalTranscript(
    StringBuffer buffer,
    Object? transcript,
  ) {
    if (transcript == null) return buffer;
    final incoming = transcript.toString().replaceAll(_whitespacePattern, ' ');
    final normalizedIncoming = incoming.trim();
    if (normalizedIncoming.isEmpty) return buffer;
    final current = buffer
        .toString()
        .replaceAll(_whitespacePattern, ' ')
        .trim();
    if (current.isEmpty ||
        normalizedIncoming == current ||
        normalizedIncoming.contains(current) ||
        normalizedIncoming.length > current.length) {
      return StringBuffer(normalizedIncoming);
    }
    if (current.contains(normalizedIncoming) ||
        current.endsWith(normalizedIncoming)) {
      return buffer;
    }
    buffer.write(incoming);
    return buffer;
  }

  RealtimeTranslationService? _liveTranslateService(String session) {
    return session == 'a' ? _realtimeTranslate : _realtimeTranslateB;
  }

  void _setLiveTranslateService(
    String session,
    RealtimeTranslationService? service,
  ) {
    if (session == 'a') {
      _realtimeTranslate = service;
    } else {
      _realtimeTranslateB = service;
    }
  }

  Future<void>? _liveTranslateStartFuture(String session) {
    return session == 'a'
        ? _realtimeTranslateAStartFuture
        : _realtimeTranslateBStartFuture;
  }

  void _setLiveTranslateStartFuture(String session, Future<void>? future) {
    if (session == 'a') {
      _realtimeTranslateAStartFuture = future;
    } else {
      _realtimeTranslateBStartFuture = future;
    }
  }

  RealtimeTranslationService _createLiveTranslateService(String session) {
    late final RealtimeTranslationService service;
    final isA = session == 'a';
    service = RealtimeTranslationService(
      apiKey: widget.apiKey,
      targetLangCode: isA ? _targetLang : _sourceLang,
      playTranslatedAudio: _liveTranslateAudioEnabled,
      audioPan: _liveTranslatePanForSession(session),
      audioBoostGain: _liveTranslateAudioBoostGain,
      audioBoostDurationMs: _liveTranslateAudioBoostMs,
      inputNoiseReduction: _liveTranslateInputNoiseReduction,
      debugLabel: isA
          ? 'A:$_sourceLang->$_targetLang'
          : 'B:$_targetLang->$_sourceLang',
      onEvent: (type, event) =>
          _handleRealtimeTranslateEvent(service, type, event),
    );
    return service;
  }

  double _liveTranslatePanForSession(String session) {
    if (_liveTranslateAudioRoute == 'mono') return 0;
    final myEarPan = _liveTranslateAudioRoute == 'mine_left' ? -1.0 : 1.0;
    final otherEarPan = -myEarPan;
    // A outputs source -> target for the other speaker. B outputs target ->
    // source for the local user.
    return session == 'a' ? otherEarPan : myEarPan;
  }

  double _ttsPanForOutputLang(String lang) {
    if (_ttsAudioRoute == 'mono') return 0;
    final myEarPan = _ttsAudioRoute == 'mine_left' ? -1.0 : 1.0;
    final otherEarPan = -myEarPan;
    if (lang == _sourceLang) return myEarPan;
    if (lang == _targetLang) return otherEarPan;
    return 0;
  }

  void _configureLiveTranslateAudioRoutes() {
    _realtimeTranslate?.setAudioPan(_liveTranslatePanForSession('a'));
    _realtimeTranslateB?.setAudioPan(_liveTranslatePanForSession('b'));
  }

  bool _shouldMuteLiveTranslateAudio(String session) {
    return !_liveTranslateAudioEnabled || session != _activeDirectionalSession;
  }

  void _applyLiveTranslateAudioMute() {
    _realtimeTranslate?.muteAudio(_shouldMuteLiveTranslateAudio('a'));
    _realtimeTranslateB?.muteAudio(_shouldMuteLiveTranslateAudio('b'));
    _applyNativeLiveTranslateAudioPan(
      _directionalPaused ? null : _activeDirectionalSession,
    );
  }

  void _configureLiveTranslateAudioBoost() {
    _realtimeTranslate?.setAudioBoost(
      gain: _liveTranslateAudioBoostGain,
      durationMs: _liveTranslateAudioBoostMs,
    );
    _realtimeTranslateB?.setAudioBoost(
      gain: _liveTranslateAudioBoostGain,
      durationMs: _liveTranslateAudioBoostMs,
    );
  }

  void _warmUpLiveTranslateAudioIfNeeded() {
    if (_liveTranslateAudioEnabled) {
      unawaited(RealtimeTranslationService.warmUpAudioOutput());
    }
  }

  Future<RealtimeTranslationService?> _ensureLiveTranslateService(
    String session, {
    required bool muted,
    bool fresh = false,
  }) async {
    if (fresh) {
      _discardLiveTranslateService(session, reason: 'fresh_start');
    }
    var service = _liveTranslateService(session);
    if (service?.isActive == true) return service;

    final existingStart = _liveTranslateStartFuture(session);
    if (existingStart != null) {
      await existingStart;
      service = _liveTranslateService(session);
      return service?.isActive == true ? service : null;
    }

    service ??= _createLiveTranslateService(session);
    _setLiveTranslateService(session, service);
    final startService = service;
    late final Future<void> tracked;
    tracked =
        (() async {
          _logLiveTranslate(
            () => 'ensure.startService session=$session muted=$muted',
          );
          await startService.start(muted: muted);
          if (_liveTranslateService(session) != startService) {
            await startService.stop();
            return;
          }
          _configureLiveTranslateAudioRoutes();
          _configureLiveTranslateAudioBoost();
          _applyLiveTranslateAudioMute();
        })().whenComplete(() {
          if (_liveTranslateStartFuture(session) == tracked) {
            _setLiveTranslateStartFuture(session, null);
          }
        });
    _setLiveTranslateStartFuture(session, tracked);

    try {
      await tracked;
    } catch (_) {
      if (_liveTranslateService(session) == startService) {
        _setLiveTranslateService(session, null);
      }
      await startService.stop();
      rethrow;
    }
    service = _liveTranslateService(session);
    return service?.isActive == true ? service : null;
  }

  bool _isLiveTranslateSessionListening(String session) {
    return _realtimeActive &&
        !_directionalPaused &&
        _activeDirectionalSession == session &&
        _liveTranslateService(session)?.isActive == true;
  }

  void _discardLiveTranslateService(String session, {required String reason}) {
    final service = _liveTranslateService(session);
    final startFuture = _liveTranslateStartFuture(session);
    if (service == null && startFuture == null) return;
    _logLiveTranslate(
      () =>
          'service.discard session=$session reason=$reason '
          'active=${service?.isActive} starting=${startFuture != null}',
    );
    _setLiveTranslateService(session, null);
    _setLiveTranslateStartFuture(session, null);
    service?.muteMic(true);
    if (service != null) {
      _drainingRealtimeTranslate = service;
      _drainingRealtimeTranslateSession = session;
      unawaited(
        service.stop().catchError((Object _) {}).whenComplete(() {
          if (_drainingRealtimeTranslate == service) {
            _commitLiveTranslateSegment(session: session);
            _drainingRealtimeTranslate = null;
            _drainingRealtimeTranslateSession = null;
          }
        }),
      );
    }
  }

  Future<void> _openLiveTranslateMic(String session) async {
    final rtA = _realtimeTranslate;
    final rtB = _realtimeTranslateB;
    final lifecycleId = _realtimeLifecycleId;
    _logLiveTranslate(
      () =>
          'openMic.begin requested=$session lifecycle=$lifecycleId '
          'active=$_realtimeActive paused=$_directionalPaused current=$_activeDirectionalSession '
          'aActive=${rtA?.isActive} bActive=${rtB?.isActive}',
    );
    if (!mounted ||
        !_realtimeActive ||
        lifecycleId != _realtimeLifecycleId ||
        _realtimeTranslate != rtA ||
        _realtimeTranslateB != rtB ||
        _activeDirectionalSession != session ||
        _directionalPaused) {
      _logLiveTranslate(
        () =>
            'openMic.abort requested=$session mounted=$mounted active=$_realtimeActive '
            'lifecycleNow=$_realtimeLifecycleId lifecycleWas=$lifecycleId '
            'sameA=${_realtimeTranslate == rtA} sameB=${_realtimeTranslateB == rtB} '
            'current=$_activeDirectionalSession paused=$_directionalPaused',
      );
      return;
    }
    _applyNativeLiveTranslateAudioPan(session);
    rtA?.muteMic(session != 'a');
    rtB?.muteMic(session != 'b');
    _applyLiveTranslateAudioMute();
    _liveTranslateLastServerEventAt = DateTime.now();
    if (_liveTranslateOutputText().isEmpty) {
      _setRealtimeStatus('청취 중...', '聴取中...');
    }
    _logLiveTranslate(
      () =>
          'openMic.done activeSession=$session '
          'aMuted=${session != 'a'} bMuted=${session != 'b'}',
    );
  }

  void _applyNativeLiveTranslateAudioPan(String? session) {
    if (!_liveTranslateAudioEnabled || session == null) {
      unawaited(RealtimeTranslationService.setNativeOutputPan(0));
      return;
    }
    unawaited(
      RealtimeTranslationService.setNativeOutputPan(
        _liveTranslatePanForSession(session),
      ),
    );
  }

  String? _liveTranslateSessionForService(RealtimeTranslationService service) {
    if (identical(service, _realtimeTranslate)) return 'a';
    if (identical(service, _realtimeTranslateB)) return 'b';
    if (identical(service, _drainingRealtimeTranslate)) {
      return _drainingRealtimeTranslateSession ??
          _liveTranslateBufferSession ??
          _activeDirectionalSession;
    }
    return null;
  }

  void _handleLiveTranslateLocalAudioActivity(String session) {
    if (!_realtimeActive ||
        _directionalPaused ||
        session != _activeDirectionalSession ||
        _liveTranslateService(session)?.isActive != true) {
      return;
    }
    final now = DateTime.now();
    final lastEvent = _liveTranslateLastServerEventAt ?? now;
    final silentFor = now.difference(lastEvent);
    if (silentFor >= const Duration(seconds: 3)) {
      final lastLog = _liveTranslateLastNoServerLogAt;
      if (lastLog == null ||
          now.difference(lastLog) >= const Duration(seconds: 2)) {
        _liveTranslateLastNoServerLogAt = now;
        if (_liveTranslateOutputText().isEmpty) {
          _setRealtimeStatus('마이크 입력 감지 · 서버 대기', 'マイク入力検知 · サーバー待機');
        }
        _logLiveTranslate(
          () =>
              'input.active_waiting_server session=$session '
              'silentFor=${silentFor.inMilliseconds}ms',
        );
      }
    }
    // Do not auto-restart translation sessions here. gpt-realtime-translate can
    // intentionally wait for enough context before producing output, and forced
    // reconnects interrupt that stream. Keep this log as a diagnostic only.
  }

  bool _isAcceptingLiveTranslateSession(
    String session, {
    bool draining = false,
  }) {
    if (draining) return true;
    return _realtimeActive && session == _activeDirectionalSession;
  }

  void _prepareLiveTranslateBuffer(String session) {
    if (_liveTranslateBufferSession != null &&
        _liveTranslateBufferSession != session) {
      _resetLiveTranslateBuffers();
    }
    _liveTranslateBufferSession ??= session;
  }

  void _appendLiveTranslateOutput(
    Object? delta, {
    required String session,
    bool finalTranscript = false,
  }) {
    if (delta == null) return;
    _applyNativeLiveTranslateAudioPan(session);
    _prepareLiveTranslateBuffer(session);
    if (finalTranscript) {
      _liveTranslateOutputBuffer = _mergeLiveTranslateFinalTranscript(
        _liveTranslateOutputBuffer,
        delta,
      );
    } else {
      _liveTranslateOutputBuffer.write(delta);
    }
    _logLiveTranslateOutput(session: session, finalTranscript: finalTranscript);
    if (mounted) {
      setState(() {
        _setInterimTextPair('', '');
      });
    }
  }

  void _logLiveTranslateOutput({
    required String session,
    required bool finalTranscript,
  }) {
    _liveTranslateOutputEventCount++;
    final now = DateTime.now();
    final lastLog = _liveTranslateLastOutputLogAt;
    if (!finalTranscript &&
        lastLog != null &&
        now.difference(lastLog) < const Duration(milliseconds: 900)) {
      return;
    }
    _liveTranslateLastOutputLogAt = now;
    _logLiveTranslate(
      () =>
          'output.${finalTranscript ? 'final' : 'delta'} session=$session '
          'chars=${_liveTranslateOutputText().length} '
          'events=$_liveTranslateOutputEventCount',
    );
  }

  void _scheduleLiveTranslateCommit({String? session}) {
    _liveTranslateCommitTimer?.cancel();
    final commitSession = session ?? _liveTranslateBufferSession;
    _liveTranslateCommitTimer = Timer(
      _liveTranslateCommitDelay,
      () => _commitLiveTranslateSegment(session: commitSession),
    );
  }

  void _commitLiveTranslateSegment({String? session}) {
    _liveTranslateCommitTimer?.cancel();
    _liveTranslateCommitTimer = null;
    final bufferSession =
        _liveTranslateBufferSession ?? session ?? _activeDirectionalSession;
    if (session != null &&
        _liveTranslateBufferSession != null &&
        _liveTranslateBufferSession != session) {
      return;
    }
    final translated = _liveTranslateOutputText();
    if (translated.isEmpty) {
      _resetLiveTranslateBuffers();
      return;
    }

    final isSourceToTarget = bufferSession == 'a';
    if (!mounted) return;
    if (_isRealtimeJunkOutput(translated)) {
      _resetLiveTranslateBuffers();
      return;
    }

    final direction = isSourceToTarget
        ? _sourceToTargetDirection
        : _targetToSourceDirection;
    final msg = ChatMessage(
      original: '',
      translated: translated,
      direction: direction,
      turnId: 'lt-${DateTime.now().microsecondsSinceEpoch}',
    );
    late final int msgIndex;
    setState(() {
      msgIndex = _messages.length;
      _messages.add(msg);
      _setInterimTextPair(
        _realtimeActive && !_directionalPaused ? '청취 중...' : '',
        _realtimeActive && !_directionalPaused ? '聴取中...' : '',
      );
    });
    _resetLiveTranslateBuffers();
    _scrollToBottom(settle: true);
    _maybePostProcessLiveSegment(
      msg: msg,
      msgIndex: msgIndex,
      isSourceToTarget: isSourceToTarget,
      translated: translated,
    );
  }

  // Restore back-translation / pronunciation for live realtime interpretation
  // committed segments, reusing the ping-pong post-process. Async, additive:
  // never delays the primary bubble.
  void _maybePostProcessLiveSegment({
    required ChatMessage msg,
    required int msgIndex,
    required bool isSourceToTarget,
    required String translated,
  }) {
    final wantBT = isSourceToTarget
        ? _backTranslateTarget
        : _backTranslateSource;
    if ((!wantBT && !_showPronunciation) || translated.isEmpty) return;
    final outputLangCode = isSourceToTarget ? _targetLang : _sourceLang;
    final backTranslationLangCode = isSourceToTarget
        ? _sourceLang
        : _targetLang;
    unawaited(
      _postProcessPingPongMessage(
        msgIndex: msgIndex,
        msg: msg,
        translated: translated,
        outputLangCode: outputLangCode,
        backTranslationLangCode: backTranslationLangCode,
        needBackTranslation: wantBT,
        requestGeneration: _conversationGeneration,
        placeBackTranslationInOriginal: true,
        forceScrollOnUpdate: true,
      ).catchError((_) {}),
    );
  }

  void _commitPendingLiveTranslateSegment() {
    _commitLiveTranslateSegment(
      session: _liveTranslateBufferSession ?? _activeDirectionalSession,
    );
  }

  // ===== Realtime =====
  Future<void> _startRealtimeTranslation({
    String initialSession = 'a',
    bool listen = false,
  }) {
    if (_realtimeActive) {
      if (listen) return _switchLiveTranslateSessionAsync(initialSession);
      return Future.value();
    }
    final existing = _realtimeStartFuture;
    if (existing != null) {
      return existing.then((_) async {
        if (listen && _realtimeActive && _isRealtimeTranslateMode) {
          await _switchLiveTranslateSessionAsync(initialSession);
        }
      });
    }

    late final Future<void> tracked;
    tracked =
        _startRealtimeTranslationInternal(
          initialSession: initialSession,
          listen: listen,
        ).whenComplete(() {
          if (_realtimeStartFuture == tracked) {
            _realtimeStartFuture = null;
          }
        });
    _realtimeStartFuture = tracked;
    return tracked;
  }

  Future<void> _startRealtimeTranslationInternal({
    required String initialSession,
    required bool listen,
  }) async {
    _logLiveTranslate(
      () =>
          'start.begin initial=$initialSession listen=$listen '
          'active=$_realtimeActive lifecycle=${_realtimeLifecycleId + 1}',
    );
    final stopFuture = _realtimeStopFuture;
    if (stopFuture != null) await stopFuture;
    if (_realtimeActive) return;
    final lifecycleId = ++_realtimeLifecycleId;
    _cancelPendingInterimUpdate();
    _resetLiveTranslateBuffers();
    _resetLiveTranslateWatchdog();
    if (mounted) {
      _setInterimTextPair('실시간 통역 연결 중...', 'リアルタイム通訳 接続中...');
    }

    final service = _createLiveTranslateService(initialSession);
    _realtimeTranslate = null;
    _realtimeTranslateB = null;
    _setLiveTranslateService(initialSession, service);

    try {
      final startMuted = !listen;
      _logLiveTranslate(
        () =>
            'start.service session=$initialSession startMuted=$startMuted '
            'listenAfterReady=$listen',
      );
      await service.start(muted: startMuted);
      if (!mounted ||
          lifecycleId != _realtimeLifecycleId ||
          _liveTranslateService(initialSession) != service) {
        await service.stop();
        return;
      }
      _configureLiveTranslateAudioRoutes();
      _configureLiveTranslateAudioBoost();
      _activeDirectionalSession = initialSession;
      setState(() {
        _realtimeActive = true;
        _realtimeMicPaused = !listen;
        _directionalPaused = !listen;
        _setInterimTextPair('', '');
      });
      _flashInterimText(
        listen ? '실시간 통역 활성' : '실시간 통역 준비',
        mirrorText: listen ? 'リアルタイム通訳 有効' : 'リアルタイム通訳 準備完了',
      );
      _updateRealtimeAudioMute();
      _logLiveTranslate(
        () =>
            'start.ready activeSession=$_activeDirectionalSession '
            'paused=$_directionalPaused listen=$listen',
      );
      if (listen) {
        await _openLiveTranslateMic(initialSession);
      }
    } catch (e) {
      _logLiveTranslate(() => 'start.error $e');
      if (_liveTranslateService(initialSession) == service) {
        _setLiveTranslateService(initialSession, null);
      }
      await service.stop();
      final stillCurrent = lifecycleId == _realtimeLifecycleId;
      if (mounted && stillCurrent) _showError(e.toString());
      if (mounted) {
        setState(() {
          _realtimeActive = false;
          if (stillCurrent) _setInterimTextPair('', '');
        });
      }
    }
  }

  Future<void> _startRealtime() {
    if (_realtimeActive) return Future.value();
    final existing = _realtimeStartFuture;
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _startRealtimeInternal().whenComplete(() {
      if (_realtimeStartFuture == tracked) {
        _realtimeStartFuture = null;
      }
    });
    _realtimeStartFuture = tracked;
    return tracked;
  }

  Future<void> _startRealtimeInternal() async {
    final stopFuture = _realtimeStopFuture;
    if (stopFuture != null) await stopFuture;
    if (_realtimeActive) return;
    final lifecycleId = ++_realtimeLifecycleId;
    _cancelPendingInterimUpdate();
    if (mounted) _setInterimTextValue('Realtime 연결 중...');

    final rt = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _realtimeVoice,
      sourceLangCode: _sourceLang,
      targetLangCode: _targetLang,
      vadThreshold: _vadThreshold,
      turnDetectionType: _turnDetectionType,
      vadEagerness: _vadEagerness,
      silenceDurationMs: _silenceDurationMs,
      tone: _tone,
      instructions: _realtimePrompt(),
      deleteConversationItems: _deleteConversationItems,
      injectFewShot: _injectFewShot,
      textOnly: !_ttsTargetEnabled,
      reasoningEffort: 'minimal',
      inputTranscriptionEnabled: true,
      onEvent: _handleRealtimeEvent,
    );
    _realtime = rt;

    try {
      await rt.start();
      if (!mounted || lifecycleId != _realtimeLifecycleId || _realtime != rt) {
        await rt.stop();
        return;
      }
      setState(() {
        _realtimeActive = true;
        _realtimeMicPaused = false;
        _directionalPaused = false;
      });
      _flashInterimText('Realtime 활성', mirrorText: 'Realtime 有効');
      _updateRealtimeAudioMute();
      _prewarmRealtimePostProcessorIfNeeded();
      // If AI mode is active, enter hold immediately
      if (_aiMode) {
        rt.enterAIHold();
      }
    } catch (e) {
      if (_realtime == rt) _realtime = null;
      await rt.stop();
      final stillCurrent = lifecycleId == _realtimeLifecycleId;
      if (mounted && stillCurrent) _showError(e.toString());
      if (mounted) {
        setState(() {
          _realtimeActive = false;
          if (stillCurrent) _setInterimTextValue('');
        });
      }
    }
  }

  Future<void> _stopRealtime({
    bool notify = true,
    bool commitPendingRealtimeTranslate = true,
  }) {
    _realtimeLifecycleId++;
    _cancelPendingInterimUpdate();
    _realtimeGraceTimer?.cancel();
    _realtimeGraceTimer = null;
    _realtimePausedByBackground = false;
    _realtimeWasPausedBeforeBackground = false;
    _directionalWasPausedBeforeBackground = false;
    _realtimeBackgroundedAt = null;
    final realtime = _realtime;
    final realtimeTranslate = _realtimeTranslate;
    final realtimeTranslateB = _realtimeTranslateB;
    final activeRealtimeTranslate = _liveTranslateService(
      _activeDirectionalSession,
    );
    final drainRealtimeTranslate =
        activeRealtimeTranslate != null && commitPendingRealtimeTranslate;
    if (activeRealtimeTranslate == null || !commitPendingRealtimeTranslate) {
      _liveTranslateCommitTimer?.cancel();
      _liveTranslateCommitTimer = null;
      _resetLiveTranslateBuffers();
    }
    final realtimeA = _realtimeA;
    final realtimeB = _realtimeB;
    final services = <RealtimeService>[?realtime, ?realtimeA, ?realtimeB];
    _realtime = null;
    _realtimeTranslate = null;
    _realtimeTranslateB = null;
    realtimeTranslate?.muteMic(true);
    realtimeTranslateB?.muteMic(true);
    _applyNativeLiveTranslateAudioPan(null);
    if (drainRealtimeTranslate) {
      _drainingRealtimeTranslate = activeRealtimeTranslate;
      _drainingRealtimeTranslateSession = _activeDirectionalSession;
    }
    _realtimeA = null;
    _realtimeB = null;
    _realtimeStartFuture = null;
    _realtimeAStartFuture = null;
    _realtimeBStartFuture = null;
    _realtimeTranslateAStartFuture = null;
    _realtimeTranslateBStartFuture = null;
    _resetLiveTranslateWatchdog();
    _realtimeMicPaused = false;
    _directionalPaused = false;
    if (mounted && notify) {
      setState(() {
        _realtimeActive = false;
        _setInterimTextPair('', '');
      });
    }

    final previousStop = _realtimeStopFuture;
    if (services.isEmpty &&
        realtimeTranslate == null &&
        realtimeTranslateB == null) {
      return previousStop ?? Future.value();
    }

    late final Future<void> tracked;
    tracked =
        (() async {
          if (previousStop != null) await previousStop;
          await Future.wait([
            for (final service in services) service.stop(),
            if (realtimeTranslate != null) realtimeTranslate.stop(),
            if (realtimeTranslateB != null) realtimeTranslateB.stop(),
          ]);
          if (drainRealtimeTranslate) {
            _commitPendingLiveTranslateSegment();
          }
        })().whenComplete(() {
          if (_drainingRealtimeTranslate == activeRealtimeTranslate) {
            _drainingRealtimeTranslate = null;
            _drainingRealtimeTranslateSession = null;
          }
          if (_realtimeStopFuture == tracked) {
            _realtimeStopFuture = null;
          }
        });
    _realtimeStopFuture = tracked;
    return tracked;
  }

  RealtimeService? _directionalService(String session) {
    return session == 'a' ? _realtimeA : _realtimeB;
  }

  Future<void>? _directionalStartFuture(String session) {
    return session == 'a' ? _realtimeAStartFuture : _realtimeBStartFuture;
  }

  void _setDirectionalStartFuture(String session, Future<void>? future) {
    if (session == 'a') {
      _realtimeAStartFuture = future;
    } else {
      _realtimeBStartFuture = future;
    }
  }

  Future<void> _ensureDirectionalSessionStarted(String session) {
    final rt = _directionalService(session);
    if (rt == null) {
      throw StateError('Realtime directional session is not initialized');
    }
    if (rt.isActive) return Future.value();

    final existing = _directionalStartFuture(session);
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = rt
        .start(muted: true)
        .then((_) async {
          if (_directionalService(session) != rt) {
            await rt.stop();
            return;
          }
          rt.muteMic(true);
          _updateRealtimeAudioMute();
        })
        .whenComplete(() {
          if (_directionalStartFuture(session) == tracked) {
            _setDirectionalStartFuture(session, null);
          }
        });
    _setDirectionalStartFuture(session, tracked);
    return tracked;
  }

  // ===== Realtime (방향) — dual sessions =====
  Future<void> _startRealtimeDirectional({String initialSession = 'a'}) {
    if (_realtimeActive) return Future.value();
    final existing = _realtimeStartFuture;
    if (existing != null) {
      return existing.then((_) async {
        if (_realtimeActive &&
            _isDirectionalMode &&
            _realtimeA != null &&
            _activeDirectionalSession != initialSession) {
          await _switchDirectionalSessionAsync(initialSession);
        }
      });
    }

    late final Future<void> tracked;
    tracked = _startRealtimeDirectionalInternal(initialSession: initialSession)
        .whenComplete(() {
          if (_realtimeStartFuture == tracked) {
            _realtimeStartFuture = null;
          }
        });
    _realtimeStartFuture = tracked;
    return tracked;
  }

  Future<void> _startRealtimeDirectionalInternal({
    required String initialSession,
  }) async {
    final stopFuture = _realtimeStopFuture;
    if (stopFuture != null) await stopFuture;
    if (_realtimeActive) return;
    final lifecycleId = ++_realtimeLifecycleId;
    _cancelPendingInterimUpdate();
    if (mounted) _setInterimTextValue('Realtime (방향) 연결 중...');

    final srcName = _sourceLangName;
    final tgtName = _targetLangName;

    final realtimeA = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _realtimeVoice,
      sourceLangCode: _sourceLang,
      targetLangCode: _targetLang,
      vadThreshold: _vadThreshold,
      turnDetectionType: _turnDetectionType,
      vadEagerness: _vadEagerness,
      silenceDurationMs: _silenceDurationMs,
      tone: _tone,
      instructions: _directionalPrompt(inputLang: srcName, outputLang: tgtName),
      deleteConversationItems: _deleteConversationItems,
      injectFewShot: false,
      textOnly: !_ttsTargetEnabled,
      reasoningEffort: 'minimal',
      inputTranscriptionEnabled: true,
      inputTranscriptionLanguage: _sourceLang,
      onEvent: (type, event) => _handleDirectionalEvent('a', type, event),
    );

    final realtimeB = RealtimeService(
      apiKey: widget.apiKey,
      model: _realtimeModel,
      voice: _realtimeVoice,
      sourceLangCode: _targetLang,
      targetLangCode: _sourceLang,
      vadThreshold: _vadThreshold,
      turnDetectionType: _turnDetectionType,
      vadEagerness: _vadEagerness,
      silenceDurationMs: _silenceDurationMs,
      tone: _tone,
      instructions: _directionalPrompt(inputLang: tgtName, outputLang: srcName),
      deleteConversationItems: _deleteConversationItems,
      injectFewShot: false,
      textOnly: !_ttsSourceEnabled,
      reasoningEffort: 'minimal',
      inputTranscriptionEnabled: true,
      inputTranscriptionLanguage: _targetLang,
      onEvent: (type, event) => _handleDirectionalEvent('b', type, event),
    );
    _realtimeA = realtimeA;
    _realtimeB = realtimeB;

    try {
      final warmupSession = initialSession == 'a' ? 'b' : 'a';
      await _ensureDirectionalSessionStarted(initialSession);
      if (!mounted ||
          lifecycleId != _realtimeLifecycleId ||
          _realtimeA != realtimeA ||
          _realtimeB != realtimeB ||
          _directionalService(initialSession) == null) {
        await realtimeA.stop();
        await realtimeB.stop();
        return;
      }
      // Mute both first, then unmute only the initial session
      _realtimeA?.muteMic(true);
      _realtimeB?.muteMic(true);
      _directionalService(initialSession)?.muteMic(false);
      _activeDirectionalSession = initialSession;
      setState(() {
        _realtimeActive = true;
        _realtimeMicPaused = false;
        _directionalPaused = false;
      });
      _flashInterimText('Realtime 활성', mirrorText: 'Realtime 有効');
      _updateRealtimeAudioMute();
      _prewarmRealtimePostProcessorIfNeeded();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), () async {
          if (!mounted ||
              lifecycleId != _realtimeLifecycleId ||
              !_realtimeActive ||
              !_isDirectionalMode) {
            return;
          }
          await _ensureDirectionalSessionStarted(warmupSession);
        }).catchError((Object _) {}),
      );
    } catch (e) {
      await realtimeA.stop();
      await realtimeB.stop();
      if (_realtimeA == realtimeA) _realtimeA = null;
      if (_realtimeB == realtimeB) _realtimeB = null;
      _realtimeAStartFuture = null;
      _realtimeBStartFuture = null;
      final stillCurrent = lifecycleId == _realtimeLifecycleId;
      if (mounted && stillCurrent) _showError(e.toString());
      if (mounted) {
        setState(() {
          _realtimeActive = false;
          if (stillCurrent) _setInterimTextValue('');
        });
      }
    }
  }

  void _switchDirectionalSession(String session) {
    unawaited(_switchDirectionalSessionAsync(session));
  }

  Future<void> _switchDirectionalSessionAsync(String session) async {
    if (!_realtimeActive) {
      await _startRealtimeDirectional(initialSession: session);
      return;
    }
    if (session == _activeDirectionalSession && !_directionalPaused) {
      _realtimeA?.muteMic(true);
      _realtimeB?.muteMic(true);
      setState(() {
        _realtimeMicPaused = true;
        _directionalPaused = true;
      });
      return;
    }
    final previousSession = _activeDirectionalSession;
    // Mute both + clear buffers to prevent cross-contamination
    _realtimeA?.muteMic(true);
    _realtimeB?.muteMic(true);
    _realtimeA?.clearInputBuffer();
    _realtimeB?.clearInputBuffer();

    setState(() {
      _activeDirectionalSession = session;
      _realtimeMicPaused = true;
      _directionalPaused = true;
      _setInterimTextPair('Realtime 연결 중...', 'Realtime 接続中...');
    });

    try {
      await _ensureDirectionalSessionStarted(session);
    } catch (e) {
      final previous = _directionalService(previousSession);
      if (previous?.isActive == true) {
        previous?.muteMic(false);
      }
      if (mounted) {
        setState(() {
          _activeDirectionalSession = previousSession;
          _realtimeMicPaused = previous?.isActive != true;
          _directionalPaused = previous?.isActive != true;
          _setInterimTextPair('', '');
        });
      }
      _showError(e.toString());
      return;
    }

    if (!mounted || !_realtimeActive) return;
    _realtimeA?.muteMic(true);
    _realtimeB?.muteMic(true);
    _directionalService(session)?.muteMic(false);
    setState(() {
      _activeDirectionalSession = session;
      _realtimeMicPaused = false;
      _directionalPaused = false;
      _setInterimTextPair('', '');
    });
  }

  void _resumeRealtimeMic() {
    if (!_realtimeActive) return;
    if (_isRealtimeTranslateMode) {
      unawaited(_resumeLiveTranslateMic());
      return;
    }
    _cancelPendingInterimUpdate();
    _realtime?.muteMic(false);
    _realtimeTranslate?.muteMic(false);
    _realtimeTranslateB?.muteMic(false);
    setState(() {
      _realtimeMicPaused = false;
      _setInterimTextPair('', '');
    });
  }

  Future<void> _resumeLiveTranslateMic() async {
    if (!_realtimeActive) return;
    _cancelPendingInterimUpdate();
    final session = _activeDirectionalSession;
    setState(() {
      _realtimeMicPaused = true;
      _directionalPaused = true;
      _setInterimTextPair('실시간 통역 연결 중...', 'リアルタイム通訳 接続中...');
    });
    final service = await _ensureLiveTranslateService(
      session,
      muted: false,
      fresh: true,
    );
    if (!mounted ||
        _activeDirectionalSession != session ||
        service?.isActive != true) {
      return;
    }
    setState(() {
      _realtimeMicPaused = false;
      _directionalPaused = false;
      _setInterimTextPair('', '');
    });
    await _openLiveTranslateMic(session);
  }

  void _resumeDirectionalMic() {
    if (!_realtimeActive) return;
    _cancelPendingInterimUpdate();
    final active = _directionalService(_activeDirectionalSession);
    if (active?.isActive != true) {
      _switchDirectionalSession(_activeDirectionalSession);
      return;
    }
    _realtimeA?.muteMic(true);
    _realtimeB?.muteMic(true);
    active?.muteMic(false);
    setState(() {
      _realtimeMicPaused = false;
      _directionalPaused = false;
      _setInterimTextPair('', '');
    });
  }

  void _handleDirectionalEvent(
    String session,
    String type,
    Map<String, dynamic> event,
  ) {
    if (!mounted || !_realtimeActive) return;
    final rt = session == 'a' ? _realtimeA : _realtimeB;
    if (rt == null) return;

    switch (type) {
      case 'response.created':
        // Per-direction audio: sessionA output = target lang, sessionB output = source lang
        final wantAudio = session == 'a'
            ? _ttsTargetEnabled
            : _ttsSourceEnabled;
        rt.muteAudio(!wantAudio);
        break;

      case 'input_audio_buffer.speech_started':
        _setRealtimeStatus('듣고 있습니다...', '聞いています...');
        break;

      case 'input_audio_buffer.speech_stopped':
        _setRealtimeStatus('번역 중...', '翻訳中...');
        break;

      case 'conversation.item.input_audio_transcription.delta':
        _setRealtimeInputTranscriptInterim(rt, event['item_id'] as String?);
        break;

      case 'conversation.item.input_audio_transcription.completed':
        _setRealtimeInputTranscriptInterim(rt, event['item_id'] as String?);
        _applyRealtimeInputTranscriptToMessage(
          event['item_id'] as String?,
          event['transcript'],
        );
        break;

      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
        final rid = event['response_id'] as String?;
        final turn = rid != null ? rt.turns[rid] : null;
        if (turn != null) {
          _setRealtimeTurnInterimThrottled(turn);
        }
        break;

      case 'response.done':
        _cancelPendingInterimUpdate();
        final rid = event['response']?['id'] as String?;
        final turn = rid != null ? rt.turns[rid] : null;
        _clearRealtimeTurn(rt, rid);
        final outputText = turn?.output.trim() ?? '';
        if (turn != null &&
            !_isRealtimeJunkOutput(outputText) &&
            !_isDuplicateRealtimeOutput(outputText)) {
          final inputText = turn.input.trim();
          final direction = session == 'a'
              ? _sourceToTargetDirection
              : _targetToSourceDirection;
          final msg = ChatMessage(
            original: inputText.isEmpty ? outputText : inputText,
            translated: outputText,
            direction: direction,
            turnId: rid,
          );
          setState(() {
            _messages.add(msg);
            _setInterimTextPair('', '');
          });
          _scrollToBottom();
          final msgIndex = _messages.length - 1;
          final generation = _conversationGeneration;
          _rememberRealtimeInputMessage(
            itemId: turn.userItemId,
            index: msgIndex,
            generation: generation,
          );
          final outputLang = session == 'a' ? _targetLang : _sourceLang;
          _asyncRealtimePostProcess(
            msgIndex,
            outputText,
            outputLang,
            turnId: rid,
            generation: generation,
          );
        } else {
          _clearRealtimeStatus();
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? '';
        if (!_isBenignRealtimeError(errMsg)) {
          _showError('Realtime: $errMsg');
        } else {
          _clearRealtimeStatus();
        }
        break;

      case 'connection_lost':
        _stopRealtime();
        _showError('Realtime (방향) 연결이 끊어졌습니다');
        break;

      case 'remote_stream':
        _updateRealtimeAudioMute();
        break;
    }
  }

  void _startRealtimeAny() {
    if (_isRealtimeTranslateMode) {
      _startRealtimeTranslation(listen: true);
    }
  }

  void _handleRealtimeTranslateEvent(
    RealtimeTranslationService service,
    String type,
    Map<String, dynamic> event,
  ) {
    final isDraining = identical(service, _drainingRealtimeTranslate);
    final session = _liveTranslateSessionForService(service);
    if (!mounted || session == null) {
      _logLiveTranslate(
        () =>
            'event.drop type=$type reason=unmounted_or_unknown_session mounted=$mounted '
            'session=$session draining=$isDraining',
      );
      return;
    }
    if (!isDraining && !_realtimeActive) {
      _logLiveTranslate(
        () => 'event.drop type=$type session=$session reason=inactive',
      );
      return;
    }
    final accepting = _isAcceptingLiveTranslateSession(
      session,
      draining: isDraining,
    );
    if (!accepting) {
      if (type != 'local_audio_activity') {
        _logLiveTranslate(
          () =>
              'event.drop type=$type session=$session reason=session_mismatch '
              'active=$_activeDirectionalSession paused=$_directionalPaused draining=$isDraining',
        );
      }
      return;
    }
    if (_shouldLogLiveTranslateEvent(type)) {
      _logLiveTranslate(
        () =>
            'event.accept type=$type session=$session draining=$isDraining '
            'active=$_activeDirectionalSession paused=$_directionalPaused '
            'deltaLen=${event['delta']?.toString().length ?? 0} '
            'transcriptLen=${event['transcript']?.toString().length ?? 0}',
      );
    }
    if (type == 'local_audio_activity') {
      _handleLiveTranslateLocalAudioActivity(session);
      return;
    }
    if (!isDraining) {
      _liveTranslateLastServerEventAt = DateTime.now();
    }
    switch (type) {
      case 'session.input_audio_buffer.speech_started':
      case 'input_audio_buffer.speech_started':
        if (!isDraining) {
          _setRealtimeStatus('서버 발화 감지', 'サーバー発話検知');
        }
        break;

      case 'session.input_audio_buffer.speech_stopped':
      case 'input_audio_buffer.speech_stopped':
        service.primeAudioOutput();
        if (!isDraining) {
          _setRealtimeStatus('번역 중...', '翻訳中...');
        }
        break;

      case 'session.output_audio.started':
      case 'output_audio_buffer.started':
        service.primeAudioOutput();
        break;

      case 'session.input_transcript.delta':
        break;

      case 'session.input_transcript.done':
        break;

      case 'session.output_transcript.delta':
        if (_liveTranslateOutputText().isEmpty) {
          service.primeAudioOutput();
        }
        _appendLiveTranslateOutput(event['delta'], session: session);
        if (!isDraining) {
          _scheduleLiveTranslateCommit(session: session);
        }
        break;

      case 'session.output_transcript.done':
        _appendLiveTranslateOutput(
          event['transcript'],
          session: session,
          finalTranscript: true,
        );
        _commitLiveTranslateSegment(session: session);
        break;

      case 'session.closed':
        _commitLiveTranslateSegment(session: session);
        if (!isDraining) _stopRealtime();
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? 'Unknown error';
        if (!isDraining) _showError('Realtime 통역: $errMsg');
        break;

      case 'connection_lost':
        if (!isDraining) {
          _stopRealtime();
          _showError('Realtime 통역 연결이 끊어졌습니다');
        }
        break;

      case 'remote_stream':
        if (!isDraining) _updateRealtimeAudioMute();
        break;
    }
  }

  bool _shouldLogLiveTranslateEvent(String type) {
    return switch (type) {
      'local_audio_activity' ||
      'session.output_transcript.delta' ||
      'session.input_transcript.delta' => false,
      _ => true,
    };
  }

  void _handleRealtimeEvent(String type, Map<String, dynamic> event) {
    if (!mounted || !_realtimeActive || _realtime == null) return;
    switch (type) {
      case 'input_audio_buffer.speech_started':
        _setRealtimeStatus('듣고 있습니다...', '聞いています...');
        break;

      case 'input_audio_buffer.speech_stopped':
        _setRealtimeStatus('번역 중...', '翻訳中...');
        break;

      case 'conversation.item.input_audio_transcription.delta':
        _setRealtimeInputTranscriptInterim(
          _realtime!,
          event['item_id'] as String?,
        );
        break;

      case 'conversation.item.input_audio_transcription.completed':
        _setRealtimeInputTranscriptInterim(
          _realtime!,
          event['item_id'] as String?,
        );
        _applyRealtimeInputTranscriptToMessage(
          event['item_id'] as String?,
          event['transcript'],
        );
        break;

      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
        final rid = event['response_id'] as String?;
        final turn = rid != null ? _realtime!.turns[rid] : null;
        if (turn != null) {
          _setRealtimeTurnInterimThrottled(turn);
        }
        break;

      case 'response.done':
        _cancelPendingInterimUpdate();
        final rid = event['response']?['id'] as String?;
        final realtime = _realtime;
        final turn = rid != null ? realtime?.turns[rid] : null;
        _clearRealtimeTurn(realtime, rid);
        // Filter out non-translation responses (model outputting meta-text)
        final outputText = turn?.output.trim() ?? '';
        if (turn != null &&
            !_isRealtimeJunkOutput(outputText) &&
            !_isDuplicateRealtimeOutput(outputText)) {
          final inputText = turn.input.trim();
          // Try unicode detection first, fallback to nano model
          final outputLang = _detectLang(outputText);
          final direction = (outputLang != null)
              ? (outputLang != _sourceLang
                    ? _sourceToTargetDirection
                    : _targetToSourceDirection)
              : _sourceToTargetDirection; // default for Latin pairs

          final msg = ChatMessage(
            original: inputText.isEmpty ? outputText : inputText,
            translated: outputText,
            direction: direction,
            turnId: rid,
          );
          setState(() {
            _messages.add(msg);
            _setInterimTextPair('', '');
          });
          _scrollToBottom();

          // Async: detect language via nano + back-translate
          final msgIndex = _messages.length - 1;
          final generation = _conversationGeneration;
          _rememberRealtimeInputMessage(
            itemId: turn.userItemId,
            index: msgIndex,
            generation: generation,
          );
          _asyncRealtimePostProcess(
            msgIndex,
            outputText,
            outputLang,
            turnId: rid,
            generation: generation,
          );
        } else {
          _clearRealtimeStatus();
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? 'Unknown error';
        // Show error in UI for debugging (benign errors already filtered in service)
        if (!_isBenignRealtimeError(errMsg)) {
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
    final now = DateTime.now();
    final lastShownAt = _lastErrorShownAt;
    if (_lastErrorMessage == msg &&
        lastShownAt != null &&
        now.difference(lastShownAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastErrorMessage = msg;
    _lastErrorShownAt = now;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  bool _backTranslationLooksCompatible(String text, String expectedLangCode) {
    if (text.trim().isEmpty) return false;
    const scriptCheckedLangs = {'ko', 'ja', 'zh', 'ru'};
    if (!scriptCheckedLangs.contains(expectedLangCode)) return true;

    final detected = _detectLang(text);
    if (detected == expectedLangCode) return true;
    if (expectedLangCode == 'zh' && detected == 'ja') return true;
    return false;
  }

  Future<String?> _realtimeBackTranslate({
    required String output,
    required String outputLangCode,
    required String targetLangCode,
  }) async {
    final outputLangName = _langNameForCode(outputLangCode);
    final targetLangName = _langNameForCode(targetLangCode);
    final clock = Stopwatch()..start();
    _logPingPongPostProcess(
      () =>
          'bt.request source=$outputLangCode target=$targetLangCode '
          'model=$_postProcessBackTranslationModel',
    );
    try {
      final systemPrompt = _translationPrompt(
        sourceLang: outputLangName,
        targetLang: targetLangName,
      );
      final wsText = await _tryPingPongWsText(
        purpose: 'backTranslation',
        model: _postProcessBackTranslationModel,
        instructions: systemPrompt,
        text: output,
        jsonObject: true,
        temperature: _classifyTemp,
        reasoningEffort: _postProcessBackTranslationReasoningEffort,
        maxOutputTokens: 256,
        timeout: const Duration(seconds: 16),
      );
      if (wsText != null) {
        try {
          final decoded = jsonDecode(wsText) as Map<String, dynamic>;
          final translated = decoded['translated']?.toString().trim();
          if (translated != null &&
              _backTranslationLooksCompatible(translated, targetLangCode)) {
            _logPingPongPostProcess(
              () =>
                  'bt.result source=ws chars=${translated.length} '
                  'elapsed=${clock.elapsedMilliseconds}ms',
            );
            return translated;
          }
          _logPingPongPostProcess(
            () =>
                'bt.ws_rejected target=$targetLangCode '
                'chars=${translated?.length ?? 0} '
                'elapsed=${clock.elapsedMilliseconds}ms',
          );
        } catch (_) {
          _logPingPongPostProcess(
            () => 'bt.ws_parse_error elapsed=${clock.elapsedMilliseconds}ms',
          );
          _discardPingPongTextWs('backTranslation');
        }
      }

      final result = await _openai.translate(
        output,
        sourceLang: outputLangName,
        targetLang: targetLangName,
        model: _postProcessBackTranslationModel,
        systemPrompt: systemPrompt,
        temperature: _classifyTemp,
        reasoningEffort: _postProcessBackTranslationReasoningEffort,
      );
      final translated = result['translated']?.trim();
      if (translated != null &&
          _backTranslationLooksCompatible(translated, targetLangCode)) {
        _logPingPongPostProcess(
          () =>
              'bt.result source=rest chars=${translated.length} '
              'elapsed=${clock.elapsedMilliseconds}ms',
        );
        return translated;
      }
      _logPingPongPostProcess(
        () =>
            'bt.rest_rejected target=$targetLangCode '
            'chars=${translated?.length ?? 0} '
            'elapsed=${clock.elapsedMilliseconds}ms',
      );
    } catch (e) {
      _logPingPongPostProcess(
        () => 'bt.exception elapsed=${clock.elapsedMilliseconds}ms error=$e',
      );
    }
    return null;
  }

  Future<String?> _hangulPronunciation(String text) async {
    final clock = Stopwatch()..start();
    _logPingPongPostProcess(
      () =>
          'pron.request model=$_postProcessPronunciationModel '
          'sourceChars=${text.length}',
    );
    try {
      final wsText = await _tryPingPongWsText(
        purpose: 'pronunciation',
        model: _postProcessPronunciationModel,
        instructions:
            'Write how the user text sounds using Korean Hangul. Reply with only the Hangul pronunciation. If a pronunciation is not useful, reply with null.',
        text: text,
        temperature: _pronunciationTemp,
        reasoningEffort: _postProcessPronunciationReasoningEffort,
        maxOutputTokens: 384,
        timeout: const Duration(seconds: 12),
      );
      final wsPronunciation = _cleanPostProcessString(wsText);
      if (wsPronunciation != null) {
        _logPingPongPostProcess(
          () =>
              'pron.result source=ws chars=${wsPronunciation.length} '
              'elapsed=${clock.elapsedMilliseconds}ms',
        );
        return wsPronunciation;
      }
      if (wsText != null) {
        _logPingPongPostProcess(
          () => 'pron.ws_empty elapsed=${clock.elapsedMilliseconds}ms',
        );
        return null;
      }

      final pronunciation = await _openai
          .hangulPronunciation(
            text,
            model: _postProcessPronunciationModel,
            temperature: _pronunciationTemp,
            reasoningEffort: _postProcessPronunciationReasoningEffort,
          )
          .timeout(const Duration(seconds: 3));
      if (pronunciation != null && pronunciation.isNotEmpty) {
        _logPingPongPostProcess(
          () =>
              'pron.result source=rest chars=${pronunciation.length} '
              'elapsed=${clock.elapsedMilliseconds}ms',
        );
      } else {
        _logPingPongPostProcess(
          () => 'pron.rest_empty elapsed=${clock.elapsedMilliseconds}ms',
        );
      }
      return pronunciation;
    } catch (e) {
      _logPingPongPostProcess(
        () => 'pron.exception elapsed=${clock.elapsedMilliseconds}ms error=$e',
      );
      return null;
    }
  }

  String? _realtimePronunciationSource({
    required String output,
    required String outputLangCode,
    required String? backTranslation,
    required String backTranslationLangCode,
  }) {
    if (outputLangCode != 'ko' && outputLangCode != 'en') return output;
    if (backTranslation != null &&
        backTranslationLangCode != 'ko' &&
        backTranslationLangCode != 'en') {
      return backTranslation;
    }
    return null;
  }

  String _rtPostProcessorInstructions() {
    return '''
You are a text-only post-processor for a realtime translation app.

The language pair is:
- source: $_sourceLang ($_sourceLangName)
- target: $_targetLang ($_targetLangName)

Return valid JSON only. Do not add markdown.

Rules:
- detected_lang_code must be exactly "$_sourceLang" or "$_targetLang".
- If known_output_lang_code is provided, use it unless the text is clearly the other language.
- If need_back_translation is true, translate input_text into the opposite language.
- If detected_lang_code is "$_sourceLang", back_translation must be in "$_targetLang".
- If detected_lang_code is "$_targetLang", back_translation must be in "$_sourceLang".
- Never translate back_translation into English unless the requested opposite language is English.
- If need_pronunciation is true, provide Korean Hangul pronunciation for Japanese/Chinese/Russian/Vietnamese/French/German text when useful.
- If pronunciation is not useful, Korean, or English, use null.

Schema:
{"detected_lang_code":"$_sourceLang|$_targetLang","back_translation":"<text or null>","pronunciation":"<hangul or null>"}
''';
  }

  bool get _wantsRealtime2PostProcess {
    return !_isLiveTranslateMode &&
        _rtPostProcessMode == 'realtime2' &&
        (_backTranslateSource || _backTranslateTarget || _showPronunciation);
  }

  void _prewarmRealtimePostProcessorIfNeeded() {
    if (!_wantsRealtime2PostProcess) return;
    unawaited(() async {
      // Keep realtime translation usable; post-processing can fall back later.
      try {
        await _ensureRealtimePostProcessor();
      } catch (_) {}
    }());
  }

  void _refreshRealtimePostProcessorForSettings() {
    if (!_wantsRealtime2PostProcess) {
      _discardRealtimePostProcessor();
      return;
    }
    if (_realtimeActive) {
      _prewarmRealtimePostProcessorIfNeeded();
    }
  }

  Future<RealtimePostProcessWsService> _ensureRealtimePostProcessor() async {
    final key = '$_sourceLang|$_targetLang|$_showPronunciation';
    final current = _rtPostProcessor;
    if (current != null && current.isActive && _rtPostProcessorKey == key) {
      _logRealtimePostProcess(
        () =>
            '[RT-PP] realtime2 websocket reuse pair=$_sourceLang-$_targetLang',
      );
      return current;
    }

    final starting = _rtPostProcessorStartFuture;
    if (starting != null) {
      if (_rtPostProcessorStartKey == key) return starting;
      _rtPostProcessorStartFuture = null;
      _rtPostProcessorStartKey = null;
    }

    late final Future<RealtimePostProcessWsService> startFuture;
    startFuture = (() async {
      await current?.stop();
      if (_rtPostProcessor == current) {
        _rtPostProcessor = null;
        _rtPostProcessorKey = null;
      }
      _logRealtimePostProcess(
        () =>
            '[RT-PP] realtime2 websocket start pair=$_sourceLang-$_targetLang',
      );
      final service = RealtimePostProcessWsService(
        apiKey: widget.apiKey,
        instructions: _rtPostProcessorInstructions(),
        reasoningEffort: _detectReasoningEffort,
      );
      await service.start();
      if (_rtPostProcessorStartFuture != startFuture) {
        await service.stop();
        throw StateError('Realtime post-process start superseded');
      }
      _rtPostProcessor = service;
      _rtPostProcessorKey = key;
      _logRealtimePostProcess(() => '[RT-PP] realtime2 websocket ready');
      return service;
    })();

    _rtPostProcessorStartFuture = startFuture;
    _rtPostProcessorStartKey = key;
    try {
      return await startFuture;
    } finally {
      if (_rtPostProcessorStartFuture == startFuture) {
        _rtPostProcessorStartFuture = null;
        _rtPostProcessorStartKey = null;
      }
    }
  }

  String? _cleanPostProcessString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    return text;
  }

  static final RegExp _jsonFenceStartPattern = RegExp(r'^```(?:json)?\s*');
  static final RegExp _jsonFenceEndPattern = RegExp(r'\s*```$');

  Map<String, String?> _decodeRealtimePostProcessJson(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(_jsonFenceStartPattern, '')
          .replaceFirst(_jsonFenceEndPattern, '')
          .trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return {
      'detected_lang_code': _cleanPostProcessString(
        decoded['detected_lang_code'],
      ),
      'back_translation': _cleanPostProcessString(decoded['back_translation']),
      'pronunciation': _cleanPostProcessString(decoded['pronunciation']),
    };
  }

  String _realtime2PostProcessPayload(
    String output, {
    required String? knownOutputLangCode,
    required bool needBackTranslation,
    required bool needPronunciation,
  }) {
    return '{"input_text":${jsonEncode(output)},'
        '$_rtPostProcessPairPayloadSegment,'
        '"known_output_lang_code":${knownOutputLangCode == null ? 'null' : jsonEncode(knownOutputLangCode)},'
        '"need_back_translation":$needBackTranslation,'
        '"need_pronunciation":$needPronunciation}';
  }

  static String _buildRtPostProcessPairPayloadSegment({
    required String sourceLang,
    required String sourceLangName,
    required String targetLang,
    required String targetLangName,
  }) {
    return '"source":{"code":${jsonEncode(sourceLang)},"name":${jsonEncode(sourceLangName)}},'
        '"target":{"code":${jsonEncode(targetLang)},"name":${jsonEncode(targetLangName)}}';
  }

  Future<Map<String, String?>> _queuedRealtime2PostProcess(
    String output, {
    String? knownOutputLangCode,
    required bool needBackTranslation,
    required bool needPronunciation,
    required bool Function() isCurrent,
  }) {
    final task = _rtPostProcessQueue.then((_) async {
      if (!isCurrent()) return <String, String?>{};
      final service = await _ensureRealtimePostProcessor();
      if (!isCurrent()) return <String, String?>{};
      _logRealtimePostProcess(
        () =>
            '[RT-PP] realtime2 request known=$knownOutputLangCode '
            'back=$needBackTranslation pron=$needPronunciation',
      );
      final payload = _realtime2PostProcessPayload(
        output,
        knownOutputLangCode: knownOutputLangCode,
        needBackTranslation: needBackTranslation,
        needPronunciation: needPronunciation,
      );
      final raw = await service.sendTextForResult(
        payload,
        timeout: const Duration(seconds: 10),
      );
      if (!isCurrent()) return <String, String?>{};
      final parsed = _decodeRealtimePostProcessJson(raw);
      _logRealtimePostProcess(
        () =>
            '[RT-PP] realtime2 result detected=${parsed['detected_lang_code']} '
            'back=${parsed['back_translation'] != null} '
            'pron=${parsed['pronunciation'] != null}',
      );
      return parsed;
    });
    _rtPostProcessQueue = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  /// Async post-process for Realtime: detect language, back-translate,
  /// and pronunciation in a single fast JSON call.
  bool _isRealtimePostProcessTargetCurrent(
    int msgIndex,
    String output,
    String? turnId,
  ) {
    if (!mounted || msgIndex < 0 || msgIndex >= _messages.length) {
      return false;
    }
    final msg = _messages[msgIndex];
    if (turnId != null) return msg.turnId == turnId;
    return msg.translated == output;
  }

  bool _needsRealtimeBackTranslationForLang(String? detectedLang) {
    if (detectedLang == null) {
      return _backTranslateSource || _backTranslateTarget;
    }
    final outputIsTarget = detectedLang != _sourceLang;
    return outputIsTarget ? _backTranslateTarget : _backTranslateSource;
  }

  bool _mayNeedRealtimePronunciation({
    required String? detectedLang,
    required bool needsBackTranslation,
  }) {
    if (!_showPronunciation) return false;
    if (detectedLang == null) return true;
    if (detectedLang != 'ko' && detectedLang != 'en') return true;
    if (!needsBackTranslation) return false;

    final outputIsTarget = detectedLang != _sourceLang;
    final backTranslationLang = outputIsTarget ? _sourceLang : _targetLang;
    return backTranslationLang != 'ko' && backTranslationLang != 'en';
  }

  Future<void> _asyncRealtimePostProcess(
    int msgIndex,
    String output,
    String? detectedLang, {
    String? turnId,
    int? generation,
  }) async {
    final requestGeneration = generation ?? _conversationGeneration;
    if (output.isEmpty ||
        !_isConversationCurrent(requestGeneration) ||
        !_isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
      return;
    }

    final needsBackTranslation = _needsRealtimeBackTranslationForLang(
      detectedLang,
    );
    final needsPronunciation = _mayNeedRealtimePronunciation(
      detectedLang: detectedLang,
      needsBackTranslation: needsBackTranslation,
    );
    if (!needsBackTranslation && !needsPronunciation && detectedLang != null) {
      return;
    }

    var result = <String, String?>{};
    var usedRealtime2PostProcess = false;
    final needsPostProcess = detectedLang == null || needsPronunciation;
    final shouldTryRealtime2PostProcess =
        _rtPostProcessMode == 'realtime2' &&
        (needsPostProcess || needsBackTranslation);
    if (shouldTryRealtime2PostProcess) {
      try {
        result = await _queuedRealtime2PostProcess(
          output,
          knownOutputLangCode: detectedLang,
          needBackTranslation: needsBackTranslation,
          needPronunciation: needsPronunciation,
          isCurrent: () =>
              _isConversationCurrent(requestGeneration) &&
              _isRealtimePostProcessTargetCurrent(msgIndex, output, turnId),
        );
        usedRealtime2PostProcess = true;
      } catch (e) {
        _logRealtimePostProcess(
          () =>
              '[RT-PP] realtime2 failed fallback=chat reason=${e.runtimeType}',
        );
        _discardRealtimePostProcessor();
      }
    }

    if (!_isConversationCurrent(requestGeneration) ||
        !_isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
      return;
    }

    if (!usedRealtime2PostProcess && detectedLang == null) {
      try {
        _logRealtimePostProcess(() => '[RT-PP] detect model=$_detectModel');
        final normalized = await _openai.detectLanguageCode(
          output,
          sourceLang: _sourceLangName,
          sourceLangCode: _sourceLang,
          targetLang: _targetLangName,
          targetLangCode: _targetLang,
          model: _detectModel,
          temperature: _classifyTemp,
          reasoningEffort: _detectReasoningEffort,
        );
        if (normalized != null) {
          result = {'detected_lang_code': normalized};
        }
      } catch (_) {
        return;
      }
    }

    if (!_isConversationCurrent(requestGeneration) ||
        !_isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
      return;
    }

    final normalizedLang = result['detected_lang_code'];
    if (normalizedLang == _sourceLang || normalizedLang == _targetLang) {
      detectedLang = normalizedLang;
    }
    if (detectedLang == null) return;

    final outputIsTarget = detectedLang != _sourceLang;
    final direction = outputIsTarget
        ? _sourceToTargetDirection
        : _targetToSourceDirection;
    final wantBackTranslation = outputIsTarget
        ? _backTranslateTarget
        : _backTranslateSource;
    final expectedBackTranslationLangCode = outputIsTarget
        ? _sourceLang
        : _targetLang;
    String? backTranslation;
    if (wantBackTranslation) {
      final candidate = result['back_translation']?.trim();
      if (candidate != null &&
          _backTranslationLooksCompatible(
            candidate,
            expectedBackTranslationLangCode,
          )) {
        backTranslation = candidate;
        _logRealtimePostProcess(
          () =>
              '[RT-PP] back_translation source=${usedRealtime2PostProcess ? 'realtime2' : 'chat_postprocess'} expected=$expectedBackTranslationLangCode',
        );
      } else if (candidate != null) {
        _logRealtimePostProcess(
          () =>
              '[RT-PP] back_translation postprocess_rejected '
              'expected=$expectedBackTranslationLangCode fallback=translate',
        );
      }
      if (backTranslation == null &&
          _isConversationCurrent(requestGeneration) &&
          _isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
        backTranslation = await _realtimeBackTranslate(
          output: output,
          outputLangCode: detectedLang,
          targetLangCode: expectedBackTranslationLangCode,
        );
      }
      if (backTranslation != null && backTranslation != candidate) {
        _logRealtimePostProcess(
          () =>
              '[RT-PP] back_translation source=chat model=$_postProcessBackTranslationModel '
              'expected=$expectedBackTranslationLangCode',
        );
      }
    }
    var pronunciation = needsPronunciation ? result['pronunciation'] : null;
    if (needsPronunciation &&
        pronunciation != null &&
        usedRealtime2PostProcess) {
      _logRealtimePostProcess(() => '[RT-PP] pronunciation source=realtime2');
    }
    if (needsPronunciation && pronunciation == null) {
      final pronunciationSource = _realtimePronunciationSource(
        output: output,
        outputLangCode: detectedLang,
        backTranslation: backTranslation,
        backTranslationLangCode: expectedBackTranslationLangCode,
      );
      if (pronunciationSource != null &&
          _isConversationCurrent(requestGeneration) &&
          _isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
        pronunciation = await _hangulPronunciation(pronunciationSource);
        if (!_isConversationCurrent(requestGeneration) ||
            !_isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
          return;
        }
        if (pronunciation != null) {
          _logRealtimePostProcess(
            () =>
                '[RT-PP] pronunciation source=chat model=$_postProcessPronunciationModel',
          );
        }
      }
    }

    if (!_isConversationCurrent(requestGeneration) ||
        !_isRealtimePostProcessTargetCurrent(msgIndex, output, turnId)) {
      return;
    }
    final cur = _messages[msgIndex];
    _logRealtimePostProcess(
      () =>
          '[RT-PP] done idx=$msgIndex path=${usedRealtime2PostProcess ? 'realtime2' : 'chat'} '
          'dir=$direction bt=${backTranslation != null} pron=${pronunciation != null}',
    );
    if (direction != cur.direction ||
        backTranslation != null ||
        pronunciation != null) {
      final keepAtBottom = _shouldKeepChatAtBottom();
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
      if (keepAtBottom) _scrollToBottom();
    }
  }

  Future<void> _replayMessage(ChatMessage msg) async {
    if (msg.isAI) return; // AI messages don't have audio
    final lang = msg.toLang.isEmpty ? _targetLang : msg.toLang;
    final voice = lang == _targetLang ? _voiceTarget : _voiceSource;
    await _playOpenAITTS(msg.translated, lang, voice);
  }

  Widget _buildChatList(
    ScrollController controller, {
    bool showEmptyHint = true,
    double bottomPadding = 8,
    String? selfLang,
    String? readerLang,
    bool useRoleLabels = false,
  }) {
    if (_messages.isEmpty) {
      if (!showEmptyHint || _displayMode != 'one') {
        return const SizedBox.expand();
      }
      return Center(
        child: Text(
          '$_sourceLangName 또는 $_targetLangName로 입력하세요',
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = viewportWidth * 0.8;
    final aiQuestionMaxWidth = viewportWidth * 0.7;
    final aiAnswerMaxWidth = viewportWidth * 0.85;
    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding),
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return RepaintBoundary(
          key: ValueKey(msg.turnId ?? index),
          child: ChatBubble(
            message: msg,
            fontSize: _fontSize,
            secondaryFontSize: _secondaryFontSize,
            sourceLang: _sourceLang,
            selfLang: selfLang ?? _sourceLang,
            readerLang: readerLang ?? _sourceLang,
            useRoleLabels: useRoleLabels,
            maxBubbleWidth: maxBubbleWidth,
            aiQuestionMaxWidth: aiQuestionMaxWidth,
            aiAnswerMaxWidth: aiAnswerMaxWidth,
            onReplay: _replayMessage,
            onRetry: _canRetryPingPongMessage(msg)
                ? (message) => unawaited(_retryPingPongMessage(message))
                : null,
          ),
        );
      },
    );
  }

  Widget _buildInputRow() {
    final showDirectionalDock =
        _mode == 'realtime_dir' && !_aiMode && _displayMode == 'one';
    final showTranslateDock =
        _isLiveTranslateMode && !_aiMode && _displayMode == 'one';
    final showPingPongDock =
        _mode == 'openai' && !_aiMode && _displayMode == 'one';
    final showFaceDirectionalInlineMic =
        _mode == 'realtime_dir' && !_aiMode && _displayMode == 'face';
    final showFaceTranslateInlineMic =
        _isLiveTranslateMode && !_aiMode && _displayMode == 'face';
    final showFacePingPongInlineMic =
        _mode == 'openai' && !_aiMode && _displayMode == 'face';
    if ((showDirectionalDock || showTranslateDock || showPingPongDock) &&
        !_inputExpanded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showDirectionalDock || showTranslateDock) ...[
                  _buildRealtimePowerButton(),
                  const SizedBox(height: 8),
                ],
                _buildCircleButton(
                  key: const ValueKey('input-toggle'),
                  icon: Icons.menu,
                  size: 32,
                  color: Colors.grey,
                  onTap: _toggleInputExpanded,
                  outlined: true,
                ),
              ],
            ),
            Expanded(
              child: showDirectionalDock
                  ? _buildDirectionalMicDock()
                  : showTranslateDock
                  ? _buildTranslateMicDock()
                  : _buildPingPongMicDock(),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDirectionalDock || showTranslateDock || showPingPongDock) ...[
            showDirectionalDock
                ? _buildDirectionalMicDock()
                : showTranslateDock
                ? _buildTranslateMicDock()
                : _buildPingPongMicDock(),
            if (_inputExpanded) const SizedBox(height: 6),
          ],
          Row(
            children: [
              if (_inputExpanded) ...[
                _buildUtilityCluster(),
                const SizedBox(width: 6),
                if (!_aiMode && !(_isRt && _realtimeActive)) ...[
                  _buildTextDirectionToggle(),
                  const SizedBox(width: 4),
                ],
                if (!(_mode == 'realtime_dir' && !_aiMode) &&
                    !_isLiveTranslateMode) ...[
                  _buildAiToggle(),
                  const SizedBox(width: 4),
                ],
                Expanded(child: _buildTextInputField()),
                const SizedBox(width: 4),
                _buildCircleButton(
                  icon: Icons.send,
                  size: 36,
                  color: const Color(0xFF4A90D9),
                  onTap: _sendText,
                ),
                const SizedBox(width: 4),
              ] else
                _buildCircleButton(
                  key: const ValueKey('input-toggle'),
                  icon: Icons.menu,
                  size: 32,
                  color: Colors.grey,
                  onTap: _toggleInputExpanded,
                  outlined: true,
                ),
              if (!_inputExpanded) const Spacer(),
              if (showFaceDirectionalInlineMic ||
                  showFaceTranslateInlineMic ||
                  showFacePingPongInlineMic) ...[
                showFaceDirectionalInlineMic
                    ? _buildCompactFaceDirectionalMic(session: 'a')
                    : showFaceTranslateInlineMic
                    ? _buildCompactFaceTranslateMics()
                    : _buildCompactFacePingPongMic(),
                const SizedBox(width: 6),
              ],
              ..._buildModeControls(),
            ],
          ),
        ],
      ),
    );
  }

  void _toggleInputExpanded() {
    setState(() => _inputExpanded = !_inputExpanded);
    _saveSettings();
  }

  Widget _buildUtilityCluster() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade400),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildUtilityIcon(icon: Icons.delete_outline, onTap: _clearChat),
          _buildUtilityDivider(),
          _buildUtilityIcon(
            key: const ValueKey('input-toggle'),
            icon: Icons.keyboard_hide,
            onTap: _toggleInputExpanded,
          ),
          _buildUtilityDivider(),
          _buildUtilityIcon(
            key: const ValueKey('settings-button'),
            icon: Icons.settings,
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildUtilityIcon({
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: SizedBox(
        width: 34,
        height: 36,
        child: Icon(icon, size: 18, color: Colors.grey.shade700),
      ),
    );
  }

  Widget _buildUtilityDivider() {
    return Container(width: 1, height: 18, color: Colors.grey.shade300);
  }

  Widget _buildTextDirectionToggle() {
    return GestureDetector(
      onTap: () => setState(() {
        _textDirection = _textDirection == 'source2target'
            ? 'target2source'
            : 'source2target';
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
          style: const TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildAiToggle() {
    return GestureDetector(
      onTap: () async {
        if (_isListening || _isRecording) {
          await _stopAll(processRecordingsInBackground: true);
        }
        setState(() => _aiMode = !_aiMode);
        if (_realtimeActive) {
          if (_aiMode) {
            _realtime?.enterAIHold();
            _realtimeA?.enterAIHold();
            _realtimeB?.enterAIHold();
          } else {
            _realtime?.exitAIHold();
            _realtimeA?.exitAIHold();
            _realtimeB?.exitAIHold();
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
            Text(
              'AI',
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextInputField() {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _textController,
        decoration: InputDecoration(
          hintText: _textInputHint,
          hintStyle: const TextStyle(fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        ),
        style: const TextStyle(fontSize: 14),
        onSubmitted: (_) => _sendText(),
      ),
    );
  }

  List<Widget> _buildModeControls() {
    if (_mode == 'realtime_dir' && !_aiMode) {
      return [_buildRealtimePowerButton()];
    }
    if (_isLiveTranslateMode && !_aiMode) {
      return [_buildRealtimePowerButton()];
    }
    if (_mode == 'openai' && !_aiMode) {
      return [];
    }
    if (_mode == 'realtime' && !_aiMode) {
      final isPaused = _realtimeActive && _realtimeMicPaused;
      return [
        _buildLangMicButton(
          langCode: 'RT',
          color: isPaused ? Colors.orange : const Color(0xFF4A90D9),
          isActive: _realtimeActive && !isPaused,
          onTap: () {
            if (!_realtimeActive) {
              _startRealtime();
            } else if (isPaused) {
              _resumeRealtimeMic();
            } else {
              _stopRealtime();
            }
          },
        ),
      ];
    }
    if (_isRt && _aiMode) {
      return [
        _buildLangMicButton(
          langCode: 'AI',
          color: const Color(0xFF8B5CF6),
          isActive: _isRecording || _isRecordingStarting,
          onTap: () {
            if (_isRecording) {
              unawaited(_stopOpenAIRecording());
            } else {
              setState(() => _micLang = _sourceLang);
              unawaited(_startOpenAIRecording());
            }
          },
        ),
        const SizedBox(width: 3),
        _buildCircleButton(
          icon: Icons.translate,
          size: 28,
          color: _realtimeActive ? Colors.green : Colors.grey,
          onTap: () => _realtimeActive ? _stopRealtime() : _startRealtimeAny(),
          outlined: !_realtimeActive,
        ),
      ];
    }
    return [
      _buildLangMicButton(
        langCode: _aiMode ? 'AI' : _sourceLang,
        color: _aiMode ? const Color(0xFF8B5CF6) : const Color(0xFF4A90D9),
        isActive: _isPrimaryMicActive(_sourceLang),
        onTap: () => _handleMicTap(_sourceLang, 'source2target'),
      ),
      const SizedBox(width: 3),
      _buildLangMicButton(
        langCode: _targetLang,
        color: const Color(0xFFE85D75),
        isActive: _isPrimaryMicActive(_targetLang),
        onTap: () => _handleMicTap(_targetLang, 'target2source'),
      ),
    ];
  }

  Widget _buildRealtimePowerButton() {
    return _buildCircleButton(
      key: const ValueKey('rt-power-button'),
      icon: Icons.power_settings_new,
      size: 32,
      color: _realtimeActive ? Colors.red : Colors.green,
      onTap: () {
        if (_realtimeActive) {
          _stopRealtime();
        } else {
          _warmUpLiveTranslateAudioIfNeeded();
          _startRealtimeTranslation(listen: true);
        }
      },
      outlined: !_realtimeActive,
    );
  }

  Widget _buildDirectionalMicDock() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(top: 4, bottom: _inputExpanded ? 6 : 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LargeDirectionalMicButton(
            key: const ValueKey('directional-mic-a'),
            langCode: _sourceLang,
            color: const Color(0xFF4A90D9),
            isActive:
                _realtimeActive &&
                !_directionalPaused &&
                _activeDirectionalSession == 'a',
            isPaused:
                _realtimeActive &&
                _directionalPaused &&
                _activeDirectionalSession == 'a',
            onTap: () => _switchDirectionalSession('a'),
          ),
          _LargeDirectionalMicButton(
            key: const ValueKey('directional-mic-b'),
            langCode: _targetLang,
            color: const Color(0xFFE85D75),
            isActive:
                _realtimeActive &&
                !_directionalPaused &&
                _activeDirectionalSession == 'b',
            isPaused:
                _realtimeActive &&
                _directionalPaused &&
                _activeDirectionalSession == 'b',
            onTap: () => _switchDirectionalSession('b'),
          ),
        ],
      ),
    );
  }

  void _switchLiveTranslateSession(String session) {
    unawaited(_switchLiveTranslateSessionAsync(session));
  }

  Future<void> _switchLiveTranslateSessionAsync(String session) async {
    final switchSerial = ++_liveTranslateSwitchSerial;
    _logLiveTranslate(
      () =>
          'switch.begin requested=$session active=$_realtimeActive '
          'current=$_activeDirectionalSession paused=$_directionalPaused '
          'aActive=${_realtimeTranslate?.isActive} bActive=${_realtimeTranslateB?.isActive} '
          'bufferSession=$_liveTranslateBufferSession outLen=${_liveTranslateOutputText().length}',
    );
    _warmUpLiveTranslateAudioIfNeeded();
    if (!_realtimeActive) {
      _logLiveTranslate(() => 'switch.startRealtime requested=$session');
      await _startRealtimeTranslation(initialSession: session, listen: true);
      return;
    }

    if (session == _activeDirectionalSession && !_directionalPaused) {
      final activeReady = _liveTranslateService(session)?.isActive == true;
      if (!activeReady) {
        _logLiveTranslate(
          () => 'switch.same_waiting session=$session activeReady=$activeReady',
        );
        return;
      }
      _logLiveTranslate(() => 'switch.pauseSame session=$session');
      if (_liveTranslateOutputText().isNotEmpty) {
        _commitLiveTranslateSegment(session: session);
      }
      _liveTranslateService(session)?.muteMic(true);
      if (!mounted) return;
      setState(() {
        _realtimeMicPaused = true;
        _directionalPaused = true;
        _setInterimTextPair('일시정지 · 연결 유지', '一時停止 · 接続維持');
      });
      _applyLiveTranslateAudioMute();
      _logLiveTranslate(() => 'switch.paused_kept session=$session');
      return;
    }

    if (session == _activeDirectionalSession && _directionalPaused) {
      _logLiveTranslate(() => 'switch.resumeSame session=$session');
      final service = await _ensureLiveTranslateService(
        session,
        muted: false,
        fresh: false,
      );
      if (!mounted ||
          switchSerial != _liveTranslateSwitchSerial ||
          _activeDirectionalSession != session ||
          service?.isActive != true) {
        _logLiveTranslate(
          () =>
              'switch.resumeSame.stale requested=$session serial=$switchSerial '
              'current=$_activeDirectionalSession latest=$_liveTranslateSwitchSerial',
        );
        return;
      }
      setState(() {
        _realtimeMicPaused = false;
        _directionalPaused = false;
        _setInterimTextPair('청취 중...', '聴取中...');
      });
      await _openLiveTranslateMic(session);
      _logLiveTranslate(() => 'switch.resumed session=$session');
      return;
    }

    final previousSession = _activeDirectionalSession;
    final wasPaused = _directionalPaused;
    _logLiveTranslate(
      () =>
          'switch.change previous=$previousSession next=$session wasPaused=$wasPaused',
    );
    if (previousSession != session) {
      if (_liveTranslateOutputText().isNotEmpty) {
        _commitLiveTranslateSegment(session: previousSession);
      } else {
        _resetLiveTranslateBuffers();
      }
    }

    if (!mounted) return;
    if (previousSession != session) {
      _liveTranslateService(previousSession)?.muteMic(true);
    }
    setState(() {
      _activeDirectionalSession = session;
      _realtimeMicPaused = true;
      _directionalPaused = true;
      _setInterimTextPair('실시간 통역 연결 중...', 'リアルタイム通訳 接続中...');
    });
    _applyLiveTranslateAudioMute();

    RealtimeTranslationService? next;
    try {
      next = await _ensureLiveTranslateService(
        session,
        muted: false,
        fresh: false,
      );
    } catch (e) {
      _logLiveTranslate(() => 'switch.start.error session=$session error=$e');
      if (mounted && switchSerial == _liveTranslateSwitchSerial) {
        _showError('실시간 통역 세션 시작 실패: $e');
      }
      return;
    }
    if (!mounted ||
        switchSerial != _liveTranslateSwitchSerial ||
        _activeDirectionalSession != session ||
        _liveTranslateService(session) != next ||
        next?.isActive != true) {
      _logLiveTranslate(
        () =>
            'switch.stale requested=$session serial=$switchSerial '
            'current=$_activeDirectionalSession latest=$_liveTranslateSwitchSerial',
      );
      return;
    }
    setState(() {
      _realtimeMicPaused = false;
      _directionalPaused = false;
      _setInterimTextPair('', '');
    });
    await _openLiveTranslateMic(session);
    _logLiveTranslate(
      () =>
          'switch.done activeSession=$_activeDirectionalSession paused=$_directionalPaused',
    );
  }

  Widget _buildTranslateMicDock() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(top: 4, bottom: _inputExpanded ? 6 : 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LargeDirectionalMicButton(
            key: const ValueKey('translate-mic-source'),
            langCode: _sourceLang,
            color: const Color(0xFF4A90D9),
            isActive: _isLiveTranslateSessionListening('a'),
            isPaused:
                _realtimeActive &&
                _directionalPaused &&
                _activeDirectionalSession == 'a',
            onTap: () => _switchLiveTranslateSession('a'),
          ),
          _LargeDirectionalMicButton(
            key: const ValueKey('translate-mic-target'),
            langCode: _targetLang,
            color: const Color(0xFFE85D75),
            isActive: _isLiveTranslateSessionListening('b'),
            isPaused:
                _realtimeActive &&
                _directionalPaused &&
                _activeDirectionalSession == 'b',
            onTap: () => _switchLiveTranslateSession('b'),
          ),
        ],
      ),
    );
  }

  Widget _buildPingPongMicDock() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(top: 4, bottom: _inputExpanded ? 6 : 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LargeDirectionalMicButton(
            key: const ValueKey('pingpong-mic-source'),
            langCode: _sourceLang,
            color: const Color(0xFF4A90D9),
            isActive: _isPrimaryMicActive(_sourceLang),
            isPaused: false,
            onTap: () => _handleMicTap(_sourceLang, 'source2target'),
          ),
          _LargeDirectionalMicButton(
            key: const ValueKey('pingpong-mic-target'),
            langCode: _targetLang,
            color: const Color(0xFFE85D75),
            isActive: _isPrimaryMicActive(_targetLang),
            isPaused: false,
            onTap: () => _handleMicTap(_targetLang, 'target2source'),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceDirectionalMic({
    required String session,
    required bool mirror,
  }) {
    final isSource = session == 'a';
    return Align(
      alignment: mirror ? Alignment.centerRight : Alignment.centerRight,
      child: _LargeDirectionalMicButton(
        key: ValueKey('face-directional-mic-$session'),
        langCode: isSource ? _sourceLang : _targetLang,
        color: isSource ? const Color(0xFF4A90D9) : const Color(0xFFE85D75),
        isActive:
            _realtimeActive &&
            !_directionalPaused &&
            _activeDirectionalSession == session,
        isPaused:
            _realtimeActive &&
            _directionalPaused &&
            _activeDirectionalSession == session,
        onTap: () => _switchDirectionalSession(session),
      ),
    );
  }

  Widget _buildCompactFaceDirectionalMic({required String session}) {
    final isSource = session == 'a';
    return SizedBox(
      width: 110,
      height: 92,
      child: FittedBox(
        fit: BoxFit.contain,
        child: _LargeDirectionalMicButton(
          key: ValueKey('bottom-face-directional-mic-$session'),
          langCode: isSource ? _sourceLang : _targetLang,
          color: isSource ? const Color(0xFF4A90D9) : const Color(0xFFE85D75),
          isActive:
              _realtimeActive &&
              !_directionalPaused &&
              _activeDirectionalSession == session,
          isPaused:
              _realtimeActive &&
              _directionalPaused &&
              _activeDirectionalSession == session,
          onTap: () => _switchDirectionalSession(session),
        ),
      ),
    );
  }

  Widget _buildCompactFaceTranslateButton({required String session}) {
    final isSource = session == 'a';
    return SizedBox(
      width: 88,
      height: 92,
      child: FittedBox(
        fit: BoxFit.contain,
        child: _LargeDirectionalMicButton(
          key: ValueKey(
            isSource
                ? 'bottom-face-translate-mic-source'
                : 'bottom-face-translate-mic-target',
          ),
          langCode: isSource ? _sourceLang : _targetLang,
          color: isSource ? const Color(0xFF4A90D9) : const Color(0xFFE85D75),
          isActive: _isLiveTranslateSessionListening(session),
          isPaused:
              _realtimeActive &&
              _directionalPaused &&
              _activeDirectionalSession == session,
          onTap: () => _switchLiveTranslateSession(session),
        ),
      ),
    );
  }

  Widget _buildCompactFaceTranslateMics() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCompactFaceTranslateButton(session: 'a'),
        _buildCompactFaceTranslateButton(session: 'b'),
      ],
    );
  }

  Widget _buildCompactFacePingPongMic() {
    return SizedBox(
      width: 110,
      height: 92,
      child: FittedBox(
        fit: BoxFit.contain,
        child: _LargeDirectionalMicButton(
          key: const ValueKey('bottom-face-pingpong-mic-source'),
          langCode: _sourceLang,
          color: const Color(0xFF4A90D9),
          isActive: _isPrimaryMicActive(_sourceLang),
          isPaused: false,
          onTap: () => _handleMicTap(_sourceLang, 'source2target'),
        ),
      ),
    );
  }

  Widget _buildFacePingPongMirrorMic() {
    return Align(
      alignment: Alignment.centerRight,
      child: _LargeDirectionalMicButton(
        key: const ValueKey('face-pingpong-mic-target'),
        langCode: _targetLang,
        color: const Color(0xFFE85D75),
        isActive: _isMirrorListening || _isMirrorStarting,
        isPaused: false,
        onTap: () {
          if (_isMirrorListening) {
            unawaited(_stopMirrorListening());
          } else {
            unawaited(_startMirrorListening());
          }
        },
      ),
    );
  }

  bool _isPrimaryMicActive(String langCode) {
    return (_isListening || _isRecording || _isRecordingStarting) &&
        _micLang == langCode;
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

  String _directionForMicLang(String lang) {
    return lang == _targetLang ? 'target2source' : 'source2target';
  }

  void _handleMicTap(String lang, String direction) {
    if (_isRecording) {
      final currentLang = _micLang;
      final currentDirection = _directionForMicLang(currentLang);
      if (currentLang == lang) {
        unawaited(_stopOpenAIRecording(forceDirection: currentDirection));
      } else {
        unawaited(
          _switchOpenAIRecording(
            nextLang: lang,
            nextDirection: direction,
            currentDirection: currentDirection,
          ),
        );
      }
      return;
    }

    if (_isListening) {
      if (_micLang == lang) {
        unawaited(_stopSystemListening());
      } else if (_usesSystemStt) {
        unawaited(
          _switchSystemListening(nextLang: lang, nextDirection: direction),
        );
      }
      return;
    }

    final waitingForStop = _hasRecordingStopInProgress;
    if (waitingForStop) {
      _setPrimaryRecordingStartingUi(lang, '녹음 전환 중...');
    } else {
      setState(() => _micLang = lang);
    }

    if (_usesSystemStt) {
      unawaited(
        _startSystemListening(
          lang: lang,
          forceDirection: _aiMode ? null : direction,
          startingUiAlreadySet: waitingForStop,
        ),
      );
    } else {
      unawaited(
        _startOpenAIRecording(
          forceDirection: _aiMode ? null : direction,
          startingUiAlreadySet: waitingForStop,
        ),
      );
    }
  }

  Future<void> _switchOpenAIRecording({
    required String nextLang,
    required String nextDirection,
    required String currentDirection,
  }) async {
    final stop = _stopOpenAIRecording(
      forceDirection: currentDirection,
      processInBackground: true,
    );
    _setPrimaryRecordingStartingUi(nextLang, '녹음 전환 중...');
    try {
      await stop;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecordingStarting = false;
          if (!_isRecording && _interimText == '녹음 전환 중...') {
            _setInterimTextValue('');
          }
        });
        _showError(e.toString());
      }
      return;
    }
    if (!mounted) return;
    await _startOpenAIRecording(
      forceDirection: _aiMode ? null : nextDirection,
      startingUiAlreadySet: true,
    );
  }

  Widget _buildCircleButton({
    Key? key,
    required IconData icon,
    required double size,
    required Color color,
    required VoidCallback onTap,
    bool outlined = false,
  }) {
    return GestureDetector(
      key: key,
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

  Widget _buildInterimTextLine(
    ValueListenable<String> listenable, {
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 12),
  }) {
    return ValueListenableBuilder<String>(
      valueListenable: listenable,
      builder: (context, text, _) {
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _buildLiveTranslateCaptionPanel({bool mirror = false}) {
    if (!_isLiveTranslateMode) return const SizedBox.shrink();
    final translated = _liveTranslateOutputText();
    final status = mirror ? _mirrorInterimText : _interimText;
    final hasCaption = translated.isNotEmpty;
    final text = hasCaption
        ? translated
        : status.isNotEmpty
        ? status
        : _realtimeActive
        ? (_directionalPaused ? '일시정지 · 연결 유지' : '청취 중...')
        : '통역 대기';
    final session = _liveTranslateBufferSession ?? _activeDirectionalSession;
    final directionLabel = session == 'a'
        ? '$_sourceLangName → $_targetLangName'
        : '$_targetLangName → $_sourceLangName';
    final activeColor = session == 'a'
        ? const Color(0xFF4A90D9)
        : const Color(0xFFE85D75);
    final textColor = hasCaption
        ? const Color(0xFF111827)
        : const Color(0xFF6B7280);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hasCaption ? const Color(0xFFF8FAFC) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasCaption
                ? activeColor.withValues(alpha: 0.38)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _realtimeActive && !_directionalPaused
                          ? activeColor
                          : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    directionLabel,
                    style: TextStyle(
                      fontSize: (_secondaryFontSize * 0.86)
                          .clamp(8.0, 14.0)
                          .toDouble(),
                      fontWeight: FontWeight.w800,
                      color: activeColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: hasCaption
                      ? _liveTranslateCaptionFontSize
                      : (_secondaryFontSize * 1.05)
                            .clamp(11.0, 18.0)
                            .toDouble(),
                  height: 1.25,
                  fontWeight: hasCaption ? FontWeight.w700 : FontWeight.w600,
                  color: textColor,
                ),
                maxLines: hasCaption ? 4 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
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
                      // Chat
                      Expanded(
                        child: _buildChatList(
                          _mirrorScrollController,
                          selfLang: _targetLang,
                          readerLang: _targetLang,
                          useRoleLabels: true,
                        ),
                      ),
                      // Mirror mic
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Colors.grey.shade300),
                          ),
                        ),
                        child: Column(
                          children: [
                            if (_isLiveTranslateMode)
                              _buildLiveTranslateCaptionPanel(mirror: true)
                            else
                              _buildInterimTextLine(
                                _mirrorInterimTextNotifier,
                                padding: const EdgeInsets.only(bottom: 4),
                              ),
                            if (_mode == 'realtime_dir')
                              _buildFaceDirectionalMic(
                                session: 'b',
                                mirror: true,
                              )
                            else if (_mode == 'realtime')
                              Text(
                                _realtimeHints[_targetLang] ?? 'Just speak',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              )
                            else if (_isLiveTranslateMode)
                              Text(
                                _realtimeActive
                                    ? (_realtimeMicPaused ? '일시정지' : '통역 중')
                                    : '통역 대기',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              )
                            else if (_mode == 'openai' && !_aiMode)
                              _buildFacePingPongMirrorMic()
                            else
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _buildCircleButton(
                                    icon: Icons.mic,
                                    size: 36,
                                    color:
                                        (_isMirrorListening ||
                                            _isMirrorStarting)
                                        ? Colors.red
                                        : const Color(0xFFE85D75),
                                    onTap: () => _isMirrorListening
                                        ? unawaited(_stopMirrorListening())
                                        : unawaited(_startMirrorListening()),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _micHints[_targetLang] ?? '말하기',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey,
                                    ),
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
                  // Chat
                  Expanded(
                    child: _buildChatList(
                      _myScrollController,
                      selfLang: _sourceLang,
                      readerLang: _sourceLang,
                      useRoleLabels: _displayMode == 'face',
                    ),
                  ),
                  // Interim text / live caption
                  if (_isLiveTranslateMode)
                    _buildLiveTranslateCaptionPanel()
                  else
                    _buildInterimTextLine(_interimTextNotifier),
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

class _LargeDirectionalMicButton extends StatefulWidget {
  final String langCode;
  final Color color;
  final bool isActive;
  final bool isPaused;
  final VoidCallback onTap;

  const _LargeDirectionalMicButton({
    super.key,
    required this.langCode,
    required this.color,
    required this.isActive,
    required this.isPaused,
    required this.onTap,
  });

  @override
  State<_LargeDirectionalMicButton> createState() =>
      _LargeDirectionalMicButtonState();
}

class _LargeDirectionalMicButtonState extends State<_LargeDirectionalMicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _beat;
  late String _label;

  @override
  void initState() {
    super.initState();
    _label = getLangByCode(widget.langCode).name;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _beat = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 24,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0.25,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 22,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.25,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 54,
      ),
    ]).animate(_controller);
    _syncPulse();
  }

  @override
  void didUpdateWidget(_LargeDirectionalMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.langCode != widget.langCode) {
      _label = getLangByCode(widget.langCode).name;
    }
    if (oldWidget.isActive != widget.isActive ||
        (widget.isActive && !_controller.isAnimating)) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (widget.isActive) {
      _controller.repeat();
    } else {
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
    final effectiveColor = widget.isPaused
        ? widget.color.withValues(alpha: 0.72)
        : widget.isActive
        ? widget.color
        : widget.color.withValues(alpha: 0.88);
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _beat,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isPaused)
              const Positioned(
                top: 10,
                right: 12,
                child: Icon(Icons.pause, color: Colors.white70, size: 18),
              ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.mic, color: Colors.white, size: 32),
                const SizedBox(height: 8),
                Text(
                  _label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ],
        ),
        builder: (context, child) {
          final beat = widget.isActive ? _beat.value : 0.0;
          return SizedBox(
            width: 146,
            height: 124,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (widget.isActive)
                  Transform.scale(
                    scale: 1.0 + beat * 0.18,
                    child: Container(
                      width: 132,
                      height: 110,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        color: widget.color.withValues(
                          alpha: 0.18 * (1 - beat) + 0.04,
                        ),
                      ),
                    ),
                  ),
                if (widget.isActive)
                  Transform.scale(
                    scale: 1.0 + beat * 0.28,
                    child: Container(
                      width: 126,
                      height: 104,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: widget.color.withValues(
                            alpha: 0.38 * (1 - beat) + 0.08,
                          ),
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: 1.0 + beat * 0.055,
                  child: Container(
                    width: 128,
                    height: 106,
                    decoration: BoxDecoration(
                      color: effectiveColor,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: widget.isActive
                            ? Colors.white
                            : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: widget.color.withValues(
                            alpha: widget.isActive ? 0.36 : 0.18,
                          ),
                          blurRadius: widget.isActive ? 24 : 12,
                          spreadRadius: widget.isActive ? 2 : 0,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ],
            ),
          );
        },
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

class _PulsatingMicState extends State<_PulsatingMic>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(
      begin: 1.0,
      end: 1.25,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _syncPulse();
  }

  @override
  void didUpdateWidget(_PulsatingMic old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mic, size: 16, color: Colors.white),
          Text(
            widget.langCode.toUpperCase(),
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
      builder: (context, child) {
        return Transform.scale(
          scale: widget.isActive ? _scaleAnim.value : 1.0,
          child: Container(
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: widget.isActive ? Colors.red : widget.color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: widget.isActive
                  ? [
                      BoxShadow(
                        color: Colors.red.withValues(
                          alpha: 0.4 * (1.25 - _scaleAnim.value),
                        ),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: child,
          ),
        );
      },
    );
  }
}
