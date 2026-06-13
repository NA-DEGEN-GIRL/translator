import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_audio_output.dart';
import 'wav_audio.dart';

/// Gemini Live Translate (gemini-3.5-live-translate-preview) 실시간 통역 세션.
///
/// 한 세션은 [targetLangCode] 한 방향만 담당한다. `echoTargetLanguage=false`라
/// 입력이 이미 타겟 언어면 모델이 침묵하므로, translator_screen에서 타겟이
/// 서로 다른 두 세션을 동시에 열어 같은 마이크 PCM을 [appendPcm16]으로 양쪽에
/// 흘리면 발화 버튼 없이 양방향 통역이 된다.
///
/// 캡처는 이 서비스가 하지 않는다(OpenAI WebRTC 경로와 다른 점). 호출자가
/// 16kHz mono PCM16 청크를 [appendPcm16]으로 공급한다.
///
/// 주의: 모델이 프리뷰라 wire 프로토콜 세부(델타 vs 누적 transcript, 활동
/// 이벤트 형태)는 온디바이스 확인이 필요하다. 파싱은 방어적으로 작성했다.
class GeminiLiveTranslateService {
  static const String defaultModel = 'gemini-3.5-live-translate-preview';
  static const int inputSampleRateHz = 16000;
  static const int outputSampleRateHz = 24000; // 기본값 — 실제는 mimeType에서 감지.
  static const String _endpoint =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
  static const int _maxReconnectAttempts = 5;

  final String apiKey;
  final String targetLangCode;
  final String model;
  final bool playTranslatedAudio;
  double audioPan;
  double audioBoostGain;
  int audioBoostDurationMs;
  final String debugLabel;
  final void Function(String type, Map<String, dynamic> event) onEvent;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _active = false;
  bool _ready = false;
  bool _micMuted = false;
  bool _audioMuted = false;
  int _reconnectAttempts = 0;
  bool _reconnecting = false;

  // 현재 turn 누적 버퍼 (세션별 = 인스턴스별).
  final StringBuffer _inputTurn = StringBuffer();
  final StringBuffer _outputTurn = StringBuffer();
  final List<Uint8List> _audioTurn = [];
  // 연속 모델은 turnComplete를 신뢰할 수 없으므로 오디오는 활동이 멈추면 flush.
  static const Duration _audioFlushGap = Duration(milliseconds: 900);
  Timer? _audioFlushTimer;
  bool _androidStreamUnsupported = false; // 네이티브 스트리밍 미지원 시 폴백 플래그
  Timer? _audioActivityTimer; // 출력 음성이 실제로 날 때만 active(에코 가드용)
  bool _audioActiveState = false;
  double _audioPanLogged = -999; // 진단: pan 변경 시 1회 로그
  int _outputRate = outputSampleRateHz; // mimeType의 rate=로 실제값 감지(늘어짐 방지)
  // 세그먼트(발화 구간) 추적: echo 침묵 세션도 오디오를 보내므로, 이번 구간에
  // 실제 번역 출력(자막)을 낸 세션의 오디오만 재생한다. 활동이 멈추면 리셋.
  static const Duration _segmentResetGap = Duration(milliseconds: 1200);
  Timer? _segmentTimer;
  bool _segmentHasOutput = false;
  String _lastInputLang = '';
  int _segmentAudioBytes = 0; // 진단: 발화 구간당 모델이 보낸 출력 오디오 총량
  // 화면의 "구간당 방향 잠금"이 제어 — 이번 구간 승자가 아니면 오디오 음소거.
  bool _audioAllowed = true;

  AudioPlayer? _player;

  GeminiLiveTranslateService({
    required this.apiKey,
    required this.targetLangCode,
    required this.onEvent,
    this.model = defaultModel,
    this.playTranslatedAudio = false,
    this.audioPan = 0,
    this.audioBoostGain = 1.65,
    this.audioBoostDurationMs = 1100,
    this.debugLabel = '',
  });

  bool get isActive => _active;
  bool get isReady => _ready;

  Future<void> start({bool muted = false}) async {
    if (_active) return;
    _micMuted = muted;
    _active = true;
    _reconnectAttempts = 0;
    await _connect();
  }

  Future<void> _connect() async {
    final uri = Uri.parse('$_endpoint?key=$apiKey');
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uri);
    } catch (e) {
      _emitError('connect failed: $e');
      return;
    }
    _channel = channel;
    _ready = false;
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) {
        _emitError(error.toString());
        _scheduleReconnect();
      },
      onDone: () {
        _ready = false;
        if (_active) {
          // 사용자 중지가 아니면 재연결 시도 (Gemini 연결 ~10-15분 상한).
          _scheduleReconnect();
        } else {
          onEvent('session.closed', {'type': 'session.closed'});
        }
      },
    );
    channel.sink.add(jsonEncode(_buildSetupMessage()));
  }

  Map<String, dynamic> _buildSetupMessage() {
    return {
      'setup': {
        'model': 'models/$model',
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'translationConfig': {
            'targetLanguageCode': targetLangCode,
            'echoTargetLanguage': false,
          },
        },
        'inputAudioTranscription': <String, dynamic>{},
        'outputAudioTranscription': <String, dynamic>{},
      },
    };
  }

  /// 16kHz mono PCM16 청크를 세션에 전송. mic가 muted거나 미연결이면 버린다.
  void appendPcm16(Uint8List bytes) {
    if (!_active || !_ready || _micMuted || bytes.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(
        jsonEncode({
          'realtimeInput': {
            'audio': {
              'data': base64Encode(bytes),
              'mimeType': 'audio/pcm;rate=$inputSampleRateHz',
            },
          },
        }),
      );
    } catch (_) {
      // 전송 실패는 재연결 경로에서 처리.
    }
  }

  void muteMic(bool mute) {
    _micMuted = mute;
  }

  void muteAudio(bool mute) {
    _audioMuted = mute;
    if (mute) {
      unawaited(_player?.stop());
    }
  }

  // 화면의 구간 방향 잠금이 호출. false면 이번 구간 echo 세션 → 오디오 음소거.
  void setAudioAllowed(bool allowed) {
    _audioAllowed = allowed;
    if (!allowed) {
      _audioTurn.clear();
      unawaited(_player?.stop());
    }
  }

  void setAudioPan(double pan) {
    audioPan = pan;
  }

  // [실험] 통신모드(이어폰 마이크) 출력은 USAGE_VOICE_COMMUNICATION(mono)이라야
  // 버즈 통화 채널로 나간다. 기본(미디어)은 false.
  bool voiceCommOutput = false;
  void setVoiceCommOutput(bool v) {
    voiceCommOutput = v;
  }

  void setAudioBoost({required double gain, required int durationMs}) {
    audioBoostGain = gain;
    audioBoostDurationMs = durationMs;
  }

  void primeAudioOutput() {
    if (playTranslatedAudio && !_audioMuted) {
      unawaited(RealtimeAudioOutputController.warmUp());
    }
  }

  // 번역 세션은 자동 VAD라 입력 버퍼 수동 제어가 없다 — 인터페이스 호환용 no-op.
  void clearInputBuffer() {}
  void commitInputBuffer() {}

  void _handleMessage(dynamic message) {
    _reconnectAttempts = 0;
    final decoded = _decode(message);
    if (decoded == null) return;

    if (decoded.containsKey('setupComplete')) {
      _ready = true;
      onEvent('session.created', {'type': 'session.created'});
      return;
    }

    if (decoded.containsKey('goAway')) {
      // 서버가 곧 연결을 닫음 → 선제적 재연결.
      _scheduleReconnect();
      return;
    }

    final serverContent = _asMap(decoded['serverContent']);
    if (serverContent != null) {
      _handleServerContent(serverContent);
      return;
    }
    // sessionResumptionUpdate/usageMetadata 등 정상 메시지는 조용히 무시.
    // 그 외 예상치 못한 메시지만 로그로 노출(설정 거부 진단용).
    if (decoded.containsKey('sessionResumptionUpdate') ||
        decoded.containsKey('usageMetadata') ||
        decoded.containsKey('toolCall')) {
      return;
    }
    final keys = decoded.keys.join(',');
    if (keys.isNotEmpty) {
      _emitDebug('server.msg keys=$keys');
    }
  }

  void _handleServerContent(Map<String, dynamic> sc) {
    // 진단(축소): 턴/완료/중단 플래그나 미지 키가 올 때만 로그.
    final shape = <String>[];
    if (sc['turnComplete'] == true) shape.add('TURN_COMPLETE');
    if (sc['generationComplete'] == true) shape.add('GEN_COMPLETE');
    if (sc['interrupted'] == true) shape.add('INTERRUPTED');
    final otherKeys = sc.keys
        .where(
          (k) => ![
            'inputTranscription',
            'outputTranscription',
            'modelTurn',
            'turnComplete',
            'generationComplete',
            'interrupted',
          ].contains(k),
        )
        .toList();
    if (otherKeys.isNotEmpty) shape.add('?${otherKeys.join('/')}');
    if (shape.isNotEmpty) _emitDebug('sc[${shape.join(',')}]');

    final input = _asMap(sc['inputTranscription']);
    if (input != null) {
      final text = input['text']?.toString() ?? '';
      final lang =
          (input['languageCode'] ?? input['language_code'])?.toString() ?? '';
      if (lang.isNotEmpty) _lastInputLang = lang;
      if (text.isNotEmpty) {
        _inputTurn.write(text);
        onEvent('session.input_transcript.delta', {
          'type': 'session.input_transcript.delta',
          'delta': text,
          'lang': lang,
        });
      }
      _scheduleSegmentReset();
    }

    final output = _asMap(sc['outputTranscription']);
    if (output != null) {
      final text = output['text']?.toString() ?? '';
      if (text.isNotEmpty) {
        _outputTurn.write(text);
        // 이 세션이 이번 구간에 실제로 번역 출력을 냄 → 오디오 재생 허용.
        _segmentHasOutput = true;
        _scheduleSegmentReset();
        onEvent('session.output_transcript.delta', {
          'type': 'session.output_transcript.delta',
          'delta': text,
        });
      }
    }

    // 출력 오디오 (inlineData PCM16 24kHz). 여러 mimeType 키 변형 방어.
    final modelTurn = _asMap(sc['modelTurn']);
    if (modelTurn != null) {
      final parts = modelTurn['parts'];
      if (parts is List) {
        final incoming = <Uint8List>[];
        for (final part in parts) {
          final partMap = _asMap(part);
          final inline =
              _asMap(partMap?['inlineData']) ?? _asMap(partMap?['inline_data']);
          final data = inline?['data'];
          if (data is String && data.isNotEmpty) {
            // 실제 출력 rate를 mimeType(audio/pcm;rate=NNNNN)에서 감지.
            // 하드코딩 24kHz와 다르면 재생이 늘어지거나(낮은 rate) 빨라진다.
            final mime = (inline?['mimeType'] ?? inline?['mime_type'])?.toString();
            final rate = _parseRateHz(mime);
            if (rate != null && rate > 0 && rate != _outputRate) {
              _emitDebug('audio.rate detected=$rate (was $_outputRate) mime=$mime');
              _outputRate = rate;
            }
            try {
              incoming.add(base64Decode(data));
            } catch (_) {}
          }
        }
        if (incoming.isNotEmpty) _ingestAudio(incoming);
      }
    }

    if (sc['interrupted'] == true) {
      _emitDebug('flag=interrupted (stop+flush audio)');
      _audioFlushTimer?.cancel();
      _audioTurn.clear();
      unawaited(_player?.stop());
      if (kIsWeb) unawaited(RealtimeAudioOutputController.stopStream());
    }
    if (sc['generationComplete'] == true) {
      _emitDebug('flag=generationComplete');
    }
    if (sc['turnComplete'] == true) {
      _emitDebug('flag=turnComplete');
      _finishTurn();
    }
  }

  void _finishTurn() {
    final inputText = _inputTurn.toString();
    final outputText = _outputTurn.toString();
    _inputTurn.clear();
    _outputTurn.clear();

    if (inputText.isNotEmpty) {
      onEvent('session.input_transcript.done', {
        'type': 'session.input_transcript.done',
        'transcript': inputText,
        'lang': _lastInputLang,
      });
    }
    // 출력이 비어도(echoTargetLanguage 침묵 턴) 항상 done을 보낸다 →
    // 화면이 매 턴 commit/reset 하여 침묵 세션의 입력 자막이 누적되지 않게 한다.
    onEvent('session.output_transcript.done', {
      'type': 'session.output_transcript.done',
      'transcript': outputText,
    });
    _flushAudio();
  }

  int _audioIngestCount = 0;

  void _scheduleSegmentReset() {
    _segmentTimer?.cancel();
    _segmentTimer = Timer(_segmentResetGap, () {
      // 진단: 이 발화 구간에 모델이 보낸 출력 오디오 총 길이.
      if (_segmentAudioBytes > 0) {
        final ms = (_segmentAudioBytes / 2 / _outputRate * 1000).round();
        _emitDebug('audio.segment total=${ms}ms (${_segmentAudioBytes}B)');
        _segmentAudioBytes = 0;
      }
      _segmentHasOutput = false;
      _inputTurn.clear();
      _outputTurn.clear();
      _lastInputLang = '';
    });
  }

  // 웹: 들어오는 PCM을 gapless 스트리밍 재생. Android: 누적 후 gap에 flush.
  void _ingestAudio(List<Uint8List> chunks) {
    final bytes = chunks.fold<int>(0, (s, c) => s + c.lengthInBytes);
    if (!playTranslatedAudio || _audioMuted) {
      if (_audioIngestCount++ % 20 == 0) _emitDebug('audio.skip (off/muted)');
      return;
    }
    // 이번 구간에 번역 출력이 없는(echo 침묵) 세션의 오디오는 버린다.
    if (!_segmentHasOutput) {
      if (_audioIngestCount++ % 20 == 0) {
        _emitDebug('audio.gate skip (no output this segment)');
      }
      return;
    }
    // 구간 방향 잠금에서 진 세션(echo 오역)의 오디오도 버린다.
    if (!_audioAllowed) {
      if (_audioIngestCount++ % 20 == 0) {
        _emitDebug('audio.gate skip (not active direction)');
      }
      return;
    }
    // 발화 구간당 첫 오디오에 1회만 로그(세션별로 어느 쪽이 소리를 내는지 확인).
    final firstOfSegment = _segmentAudioBytes == 0;
    _segmentAudioBytes += bytes;
    if (firstOfSegment) {
      _emitDebug('audio.begin PLAY (${kIsWeb ? 'web' : 'android'})');
    }
    _signalAudioActivity(chunks); // 스피커 에코 가드: 실제 소리날 때만 마이크 차단


    if (kIsWeb) {
      for (final c in chunks) {
        unawaited(
          RealtimeAudioOutputController.enqueuePcm(
            c,
            sampleRate: _outputRate,
            pan: audioPan,
            voiceComm: voiceCommOutput,
          ),
        );
      }
    } else {
      // Android: 네이티브 AudioTrack gapless 스트리밍(웹처럼 즉각 재생).
      // 미지원 시 버퍼 후 audioplayers 폴백으로 1회 전환.
      unawaited(_streamOrBufferAndroid(chunks));
    }
  }

  Future<void> _streamOrBufferAndroid(List<Uint8List> chunks) async {
    if (!_androidStreamUnsupported) {
      if (_audioPanLogged != audioPan) {
        _audioPanLogged = audioPan;
        _emitDebug('stream pan=$audioPan rate=$_outputRate');
      }
      var ok = true;
      for (final c in chunks) {
        ok = await RealtimeAudioOutputController.enqueuePcm(
          c,
          sampleRate: _outputRate,
          pan: audioPan,
          voiceComm: voiceCommOutput,
        );
        if (!ok) break;
      }
      if (ok) return;
      _androidStreamUnsupported = true;
      _emitDebug('audio.stream unsupported -> buffer fallback');
    }
    _audioTurn.addAll(chunks);
    _scheduleAudioFlush();
  }

  // (Android 전용) turnComplete가 안 와도 오디오가 멈추면 누적분을 재생.
  void _scheduleAudioFlush() {
    _audioFlushTimer?.cancel();
    _audioFlushTimer = Timer(_audioFlushGap, _flushAudio);
  }

  void _flushAudio() {
    _audioFlushTimer?.cancel();
    _audioFlushTimer = null;
    if (_audioTurn.isEmpty) return;
    final chunks = List<Uint8List>.from(_audioTurn);
    _audioTurn.clear();
    final bytes = chunks.fold<int>(0, (s, c) => s + c.lengthInBytes);
    if (playTranslatedAudio && !_audioMuted) {
      _emitDebug('audio.play bytes=$bytes');
      unawaited(_playTurnAudio(chunks));
    } else {
      _emitDebug('audio.skip bytes=$bytes (off/muted)');
    }
  }

  // 출력 오디오 청크가 실제 소리(무음 아님)면 'audioActive' 이벤트를 쏜다.
  // 화면이 스피커 출력일 때 이 동안 마이크 입력을 막아 에코를 방지한다.
  // 무음/약음 구간엔 active를 켜지 않아 사용자가 바로 말할 수 있다.
  void _signalAudioActivity(List<Uint8List> chunks) {
    var sum = 0.0;
    var n = 0;
    for (final c in chunks) {
      final bd = ByteData.sublistView(c);
      final len = c.lengthInBytes & ~1;
      for (var i = 0; i < len; i += 2) {
        final s = bd.getInt16(i, Endian.little).toDouble();
        sum += s * s;
        n++;
      }
    }
    if (n == 0) return;
    if (sum / n < 430000) return; // ~ RMS 0.02 미만 = 무음/약음 → 무시
    if (!_audioActiveState) {
      _audioActiveState = true;
      onEvent('audioActive', {'type': 'audioActive', 'active': true});
    }
    _audioActivityTimer?.cancel();
    _audioActivityTimer = Timer(const Duration(milliseconds: 500), () {
      _audioActiveState = false;
      onEvent('audioActive', {'type': 'audioActive', 'active': false});
    });
  }

  // "audio/pcm;rate=24000" 같은 mimeType에서 rate 정수만 뽑는다.
  int? _parseRateHz(String? mime) {
    if (mime == null || mime.isEmpty) return null;
    final m = RegExp(r'rate=(\d+)').firstMatch(mime);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  void _emitDebug(String message) {
    onEvent('debug', {'type': 'debug', 'message': '$debugLabel $message'});
  }

  Future<void> _playTurnAudio(List<Uint8List> chunks) async {
    try {
      var wav = pcm16ToWav(
        chunks,
        sampleRate: _outputRate,
        numChannels: 1,
      );
      if (audioPan.abs() >= 0.01) {
        wav = panWavPcm16ToStereo(wav, audioPan);
      }
      // 웹은 저지연 Web Audio 경로, 그 외(Android)는 audioplayers로 폴백.
      final played = await RealtimeAudioOutputController.playBufferedAudio(
        wav,
        pan: 0, // 팬은 위에서 이미 적용.
        initialBoostGain: audioBoostGain,
        initialBoostDurationMs: audioBoostDurationMs,
      );
      if (played) {
        _emitDebug('audio.played via=webAudio');
        return;
      }
      final player = await _ensureAndroidPlayer();
      await player.play(BytesSource(wav, mimeType: 'audio/wav'));
      _emitDebug('audio.played via=audioplayers');
    } catch (e) {
      _emitDebug('audio.error $e');
    }
  }

  // 안드로이드 재생 player. 오디오 포커스를 잡지 않도록(none) 설정해야 동시에
  // 도는 record(VOICE_COMMUNICATION, echoCancel) 마이크 캡처가 끊기지 않는다.
  // 포커스 GAIN을 요청하면 캡처 오디오 세션이 교란돼 인식이 영구 정지함.
  Future<AudioPlayer> _ensureAndroidPlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final created = AudioPlayer();
    try {
      await created.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.none,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playAndRecord,
            options: const {
              AVAudioSessionOptions.mixWithOthers,
              AVAudioSessionOptions.defaultToSpeaker,
            },
          ),
        ),
      );
    } catch (e) {
      _emitDebug('audio.ctx_error $e');
    }
    _player = created;
    return created;
  }

  void _scheduleReconnect() {
    if (!_active || _reconnecting) return;
    _reconnecting = true;
    _ready = false;
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    await _teardownChannel(sendClose: false);
    if (!_active) {
      _reconnecting = false;
      return;
    }
    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      _reconnecting = false;
      _active = false;
      onEvent('connection_lost', {'type': 'connection_lost'});
      return;
    }
    // 진행 중 turn 버퍼는 버리고 새 연결에서 다시 받는다.
    _inputTurn.clear();
    _outputTurn.clear();
    _audioTurn.clear();
    final backoffMs = 250 * _reconnectAttempts;
    await Future<void>.delayed(Duration(milliseconds: backoffMs));
    if (!_active) {
      _reconnecting = false;
      return;
    }
    await _connect();
    _reconnecting = false;
  }

  Future<void> _teardownChannel({required bool sendClose}) async {
    final channel = _channel;
    final sub = _subscription;
    _channel = null;
    _subscription = null;
    _ready = false;
    await sub?.cancel();
    if (channel == null) return;
    try {
      await channel.sink.close();
    } catch (_) {}
  }

  Future<void> stop() async {
    _active = false;
    _ready = false;
    _reconnecting = false;
    _audioFlushTimer?.cancel();
    _audioFlushTimer = null;
    _audioActivityTimer?.cancel();
    _audioActivityTimer = null;
    if (_audioActiveState) {
      _audioActiveState = false;
      onEvent('audioActive', {'type': 'audioActive', 'active': false});
    }
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _segmentHasOutput = false;
    // 웹/안드로이드 공통 — 네이티브/Web Audio 스트림 해제(미시작 시 no-op).
    unawaited(RealtimeAudioOutputController.stopStream());
    await _teardownChannel(sendClose: true);
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (_) {}
    _player = null;
    _inputTurn.clear();
    _outputTurn.clear();
    _audioTurn.clear();
  }

  void _emitError(String message) {
    onEvent('error', {
      'type': 'error',
      'error': {'message': message},
    });
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    } else if (raw is List<int>) {
      try {
        decoded = jsonDecode(utf8.decode(raw));
      } catch (_) {
        return null;
      }
    }
    return _asMap(decoded);
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  @visibleForTesting
  Map<String, dynamic> debugBuildSetupMessage() => _buildSetupMessage();
}
