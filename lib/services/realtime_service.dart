import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/language.dart';
import '../prompts.dart';

class RealtimeTurn {
  String input = '';
  final StringBuffer _output = StringBuffer();
  String? _cachedOutput;
  String? userItemId; // links response to user conversation item

  String get output => _cachedOutput ??= _output.toString();

  void appendOutput(Object? delta) {
    if (delta != null) {
      _output.write(delta);
      _cachedOutput = null;
    }
  }

  void appendInput(Object? delta) {
    if (delta == null) return;
    input = '$input$delta';
  }

  void replaceInput(Object? transcript) {
    final text = transcript?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty) return;
    input = text;
  }
}

class RealtimeService {
  static final http.Client _httpClient = http.Client();
  static const _requestTimeout = Duration(seconds: 30);
  static const _cleanupTimeout = Duration(seconds: 2);
  static const _verboseLogs = false;
  static const _maxRetainedTurns = 32;
  static final Uri _clientSecretsUri = Uri.parse(
    'https://api.openai.com/v1/realtime/client_secrets',
  );
  static final Uri _callsUri = Uri.parse(
    'https://api.openai.com/v1/realtime/calls',
  );
  static const String _responseCancelPayload = '{"type":"response.cancel"}';
  static const String _inputAudioBufferClearPayload =
      '{"type":"input_audio_buffer.clear"}';
  static const String _responseCreatePayload = '{"type":"response.create"}';
  static final Map<String, dynamic> _mediaConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
  };
  static final Map<String, dynamic> _peerConnectionConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };
  static final Map<String, List<String>> _fewShotPayloadCache = {};

  final String apiKey;
  final String model;
  final String voice;
  final String sourceLangCode;
  final String targetLangCode;
  // VAD / turn-detection tunables. Mutable so updateTurnDetection() can change
  // them live via session.update without recreating the WebRTC session.
  double vadThreshold;
  String turnDetectionType; // 'server_vad' | 'semantic_vad'
  String vadEagerness; // semantic_vad only: 'low' | 'medium' | 'high' | 'auto'
  int silenceDurationMs; // server_vad only
  final ToneMode tone;
  final String? instructions;
  final bool deleteConversationItems;
  final bool injectFewShot;
  final bool textOnly;
  final String? reasoningEffort;
  final bool inputTranscriptionEnabled;
  final String inputTranscriptionModel;
  final String? inputTranscriptionLanguage;
  final void Function(String type, Map<String, dynamic> event) onEvent;
  late final bool _usesRealtime2 = model.toLowerCase().startsWith(
    'gpt-realtime-2',
  );
  late final Map<String, String> _clientSecretHeaders = {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };
  String _buildClientSecretBody({bool forceServerVad = false}) => jsonEncode({
    'session': _buildSessionConfig(forceServerVad: forceServerVad),
  });

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  MediaStreamTrack? _localTrack;
  MediaStream? _remoteStream;
  RTCVideoRenderer? _remoteRenderer;
  bool? _audioMuted;
  MediaStream? _audioMuteAppliedStream;
  bool _active = false;
  bool _stopping = false;
  Completer<void>? _sessionReady;
  Timer? _unmuteWatchdog;
  Timer? _safeUnmuteTimer;

  final Map<String, RealtimeTurn> turns = {}; // keyed by response_id
  final Map<String, String> _itemToResponse = {}; // user item_id → response_id
  final Map<String, StringBuffer> _itemInputTranscripts = {};
  String? currentResponseId;
  String? _lastUserItemId; // most recent user conversation item

  RealtimeService({
    required this.apiKey,
    this.model = 'gpt-realtime-2',
    this.voice = 'ash',
    this.sourceLangCode = 'ko',
    this.targetLangCode = 'ja',
    this.vadThreshold = 0.5,
    this.turnDetectionType = 'server_vad',
    this.vadEagerness = 'low',
    this.silenceDurationMs = 500,
    this.tone = ToneMode.normal,
    this.instructions,
    this.deleteConversationItems = true,
    this.injectFewShot = true,
    this.textOnly = false,
    this.reasoningEffort,
    this.inputTranscriptionEnabled = true,
    this.inputTranscriptionModel = 'gpt-4o-transcribe',
    this.inputTranscriptionLanguage,
    required this.onEvent,
  });

  bool get isActive => _active;
  MediaStream? get remoteStream => _remoteStream;

  void _throwIfStopping() {
    if (_stopping) throw StateError('Realtime stopped');
  }

  void _log(String Function() message) {
    if (_verboseLogs) debugPrint(message());
  }

  void removeTurn(String responseId) {
    final turn = turns.remove(responseId);
    final userItemId = turn?.userItemId;
    if (userItemId != null) {
      _itemToResponse.remove(userItemId);
      _itemInputTranscripts.remove(userItemId);
    }
    if (currentResponseId == responseId) {
      currentResponseId = null;
    }
  }

  void _pruneTurns() {
    while (turns.length > _maxRetainedTurns) {
      final key = turns.keys.firstWhere(
        (id) => id != currentResponseId,
        orElse: () => '',
      );
      if (key.isEmpty) return;
      removeTurn(key);
    }
  }

  String _buildSystemPrompt() {
    if (instructions != null) return instructions!;
    final src = getLangByCode(sourceLangCode);
    final tgt = getLangByCode(targetLangCode);
    return AppPrompts.realtimeTranslation(
      PromptLanguagePair(sourceLang: src.name, targetLang: tgt.name),
      tone: tone,
    );
  }

  Map<String, dynamic> _buildTurnDetection({bool forceServerVad = false}) {
    if (!forceServerVad && turnDetectionType == 'semantic_vad') {
      return {
        'type': 'semantic_vad',
        'eagerness': vadEagerness,
        'create_response': true,
      };
    }
    return {
      'type': 'server_vad',
      'threshold': vadThreshold,
      'silence_duration_ms': silenceDurationMs,
      'create_response': true,
    };
  }

  Map<String, dynamic> _buildSessionConfig({bool forceServerVad = false}) {
    final inputAudio = <String, dynamic>{
      'turn_detection': _buildTurnDetection(forceServerVad: forceServerVad),
    };
    if (inputTranscriptionEnabled) {
      final transcription = <String, dynamic>{'model': inputTranscriptionModel};
      final language = inputTranscriptionLanguage?.trim();
      if (language != null && language.isNotEmpty) {
        transcription['language'] = language;
      }
      inputAudio['transcription'] = transcription;
      inputAudio['noise_reduction'] = {'type': 'near_field'};
    }

    final audio = <String, dynamic>{'input': inputAudio};
    if (!textOnly) {
      audio['output'] = {'voice': voice};
    }

    final session = <String, dynamic>{
      'type': 'realtime',
      'model': model,
      'instructions': _buildSystemPrompt(),
      'max_output_tokens': 512,
      'audio': audio,
    };
    if (textOnly) {
      session['output_modalities'] = ['text'];
    }
    if (_usesRealtime2) {
      session['reasoning'] = {'effort': reasoningEffort ?? 'minimal'};
    }
    return session;
  }

  @visibleForTesting
  Map<String, dynamic> buildSessionConfigForTesting() => _buildSessionConfig();

  @visibleForTesting
  void handleEventForTesting(Map<String, dynamic> event) => _handleEvent(event);

  Future<void> start({bool muted = false}) async {
    if (_active) return;
    _stopping = false;

    Future<MediaStream>? localStreamFuture;
    Future<RTCPeerConnection>? peerConnectionFuture;
    Future<RTCVideoRenderer?>? remoteRendererFuture;
    try {
      localStreamFuture = navigator.mediaDevices.getUserMedia(
        _mediaConstraints,
      );
      peerConnectionFuture = createPeerConnection(_peerConnectionConfig);
      remoteRendererFuture = _createRemoteRenderer();

      var tokenRes = await _httpClient
          .post(
            _clientSecretsUri,
            headers: _clientSecretHeaders,
            body: _buildClientSecretBody(),
          )
          .timeout(_requestTimeout);

      // Some realtime model snapshots may not accept semantic_vad. Fall back to
      // server_vad once on a 400 so the session still connects.
      if (tokenRes.statusCode == 400 && turnDetectionType == 'semantic_vad') {
        turnDetectionType = 'server_vad';
        tokenRes = await _httpClient
            .post(
              _clientSecretsUri,
              headers: _clientSecretHeaders,
              body: _buildClientSecretBody(forceServerVad: true),
            )
            .timeout(_requestTimeout);
      }

      if (tokenRes.statusCode != 200 && tokenRes.statusCode != 201) {
        throw Exception(
          'Failed to create session: ${tokenRes.statusCode} ${tokenRes.body}',
        );
      }
      _throwIfStopping();

      final tokenData = jsonDecode(tokenRes.body);
      final ephemeralKey = tokenData['value'] as String;

      _pc = await peerConnectionFuture;
      _remoteRenderer = await remoteRendererFuture;
      _throwIfStopping();

      _pc!.onTrack = (event) {
        if (_stopping) return;
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _remoteRenderer?.srcObject = _remoteStream;
          onEvent('remote_stream', {});
        }
      };

      _pc!.onConnectionState = (state) {
        if (!_active || _stopping) return;
        if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          onEvent('connection_lost', {});
        }
      };

      _localStream = await localStreamFuture;
      _localTrack = _localStream!.getAudioTracks().first;
      _manualMute = muted;
      _localTrack!.enabled = !muted;
      _pc!.addTrack(_localTrack!, _localStream!);
      _throwIfStopping();

      // Create completer BEFORE data channel to avoid race with session.created
      _sessionReady = Completer<void>();

      _dc = await _pc!.createDataChannel('oai-events', RTCDataChannelInit());
      _dc!.onMessage = (msg) {
        try {
          final event = jsonDecode(msg.text) as Map<String, dynamic>;
          _handleEvent(event);
        } catch (_) {}
      };

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _throwIfStopping();

      final sdpRes = await _httpClient
          .post(
            _callsUri,
            headers: {
              'Authorization': 'Bearer $ephemeralKey',
              'Content-Type': 'application/sdp',
            },
            body: offer.sdp,
          )
          .timeout(_requestTimeout);

      if (sdpRes.statusCode != 200 && sdpRes.statusCode != 201) {
        throw Exception(
          'WebRTC connection failed: ${sdpRes.statusCode} ${sdpRes.body}',
        );
      }
      _throwIfStopping();

      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdpRes.body, 'answer'),
      );
      _throwIfStopping();

      await _sessionReady!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Realtime session setup timed out'),
      );
      _throwIfStopping();
      _sessionReady = null;
      _active = true;
    } catch (_) {
      if (_localStream == null) {
        final pendingLocalStream = localStreamFuture;
        if (pendingLocalStream != null) {
          unawaited(
            pendingLocalStream.then<void>(_disposeMediaStream, onError: (_) {}),
          );
        }
      }
      if (_pc == null) {
        final pendingPeerConnection = peerConnectionFuture;
        if (pendingPeerConnection != null) {
          unawaited(
            pendingPeerConnection.then<void>(
              _closePeerConnection,
              onError: (_) {},
            ),
          );
        }
      }
      if (_remoteRenderer == null) {
        final pendingRemoteRenderer = remoteRendererFuture;
        if (pendingRemoteRenderer != null) {
          unawaited(
            pendingRemoteRenderer.then<void>(
              _disposeRemoteRenderer,
              onError: (_) {},
            ),
          );
        }
      }
      await stop();
      rethrow;
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    if (_stopping) return;
    final type = event['type'] as String? ?? '';
    if (_verboseLogs) debugPrint('[RT] event: $type');
    var forwardEvent = false;

    switch (type) {
      case 'session.updated':
        _log(() {
          final updatedInstr =
              event['session']?['instructions'] as String? ?? '';
          return '[RT] session.updated: instructionsLen=${updatedInstr.length} first100="${updatedInstr.substring(0, updatedInstr.length > 100 ? 100 : updatedInstr.length)}"';
        });
        break;

      case 'session.created':
        _log(() {
          final createdInstr =
              event['session']?['instructions'] as String? ?? '';
          final vadConfig =
              event['session']?['audio']?['input']?['turn_detection'];
          return '[RT] session.created: instructionsLen=${createdInstr.length} vad=$vadConfig';
        });
        if (injectFewShot &&
            _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _injectFewShotExamples();
        }
        _sessionReady?.complete();
        break;

      case 'input_audio_buffer.speech_started':
        forwardEvent = true;
        if (currentResponseId != null) {
          _sendControlMessage(_responseCancelPayload);
        }
        break;

      case 'input_audio_buffer.speech_stopped':
        forwardEvent = true;
        break;

      case 'conversation.item.added':
        final addedItem = event['item'] as Map<String, dynamic>?;
        if (addedItem?['type'] == 'message' && addedItem?['role'] == 'user') {
          final itemId = addedItem?['id'] as String?;
          if (itemId != null) {
            _lastUserItemId = itemId;
          }
        }
        break;

      case 'conversation.item.input_audio_transcription.delta':
        forwardEvent = true;
        _appendInputTranscript(event['item_id'] as String?, event['delta']);
        break;

      case 'conversation.item.input_audio_transcription.completed':
        forwardEvent = true;
        _replaceInputTranscript(
          event['item_id'] as String?,
          event['transcript'],
        );
        break;

      case 'response.created':
        forwardEvent = true;
        final respId = event['response']?['id'] as String?;
        _log(
          () => '[RT] response.created: id=$respId userItem=$_lastUserItemId',
        );
        if (respId != null) {
          currentResponseId = respId;
          final userItem = _lastUserItemId;
          _lastUserItemId = null; // consume to prevent stale reuse
          final turn = RealtimeTurn()..userItemId = userItem;
          if (_pendingTextInput != null) {
            turn.input = _pendingTextInput!;
            _pendingTextInput = null;
          } else if (userItem != null) {
            final bufferedInput = _itemInputTranscripts.remove(userItem);
            final inputText = bufferedInput
                ?.toString()
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (inputText != null && inputText.isNotEmpty) {
              turn.input = inputText;
            }
          }
          turns[respId] = turn;
          if (userItem != null) {
            _itemToResponse[userItem] = respId;
          }
          _pruneTurns();
        }
        break;

      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
        forwardEvent = true;
        final rid = event['response_id'] as String?;
        if (rid != null) turns[rid]?.appendOutput(event['delta']);
        break;

      case 'output_audio_buffer.started':
        _localTrack?.enabled = false; // mute mic during playback
        _safeUnmuteTimer?.cancel();
        _startUnmuteWatchdog(); // safety: unmute if stopped event never fires
        _sendControlMessage(_inputAudioBufferClearPayload);
        break;

      case 'output_audio_buffer.stopped':
      case 'output_audio_buffer.cleared':
        // Clear any echo captured in buffer during playback
        _sendControlMessage(_inputAudioBufferClearPayload);
        _safeUnmute();
        break;

      case 'response.done':
        forwardEvent = true;
        final rid = event['response']?['id'] as String?;
        final status = event['response']?['status'] as String?;
        _log(() => '[RT] response.done: id=$rid status=$status');
        if (rid != null) {
          _log(() {
            final turnOutput = turns[rid]?.output ?? '';
            final turnInput = turns[rid]?.input ?? '';
            return '[RT] response.done: input="$turnInput" output="${turnOutput.length > 100 ? turnOutput.substring(0, 100) : turnOutput}"';
          });

          // Delete conversation items to prevent history bias (configurable)
          if (deleteConversationItems &&
              status == 'completed' &&
              _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
            final userItemId = turns[rid]?.userItemId;
            final outputItems = event['response']?['output'] as List?;
            final assistantItemId = outputItems?.isNotEmpty == true
                ? outputItems!.first['id'] as String?
                : null;
            if (userItemId != null) {
              _dc!.send(
                RTCDataChannelMessage(
                  _conversationItemDeletePayload(userItemId),
                ),
              );
            }
            if (assistantItemId != null) {
              _dc!.send(
                RTCDataChannelMessage(
                  _conversationItemDeletePayload(assistantItemId),
                ),
              );
            }
          }

          currentResponseId = null;
        }
        if (status != null && status != 'completed') {
          _safeUnmute();
        }
        break;

      case 'error':
        forwardEvent = true;
        final errMsg = event['error']?['message'] ?? '';
        final errCode = event['error']?['code'] ?? '';
        _log(() => '[RT] ERROR: code=$errCode msg=$errMsg');
        final errText = errMsg.toString();
        if (errText.contains('no active response')) {
          return;
        }
        _safeUnmute();
        break;
    }

    if (forwardEvent) onEvent(type, event);
  }

  bool _aiHold = false;
  bool _manualMute =
      false; // set by external muteMic(true), prevents auto-unmute

  void enterAIHold() {
    _aiHold = true;
    _cancelUnmuteWatchdog();
    _localTrack?.enabled = false;
    if (currentResponseId != null) {
      _sendControlMessage(_responseCancelPayload);
    }
  }

  void exitAIHold() {
    _aiHold = false;
    _localTrack?.enabled = true;
  }

  void muteMic(bool mute) {
    if (_aiHold) return;
    final track = _localTrack;
    final enabled = !mute;
    if (_manualMute == mute && track?.enabled == enabled) return;
    _manualMute = mute;
    track?.enabled = enabled;
    if (!mute) {
      _cancelUnmuteWatchdog();
      _safeUnmuteTimer?.cancel();
    }
  }

  void _startUnmuteWatchdog() {
    _cancelUnmuteWatchdog();
    _unmuteWatchdog = Timer(const Duration(seconds: 15), () {
      if (_active && !_aiHold && !_manualMute) {
        _localTrack?.enabled = true;
      }
    });
  }

  void _cancelUnmuteWatchdog() {
    _unmuteWatchdog?.cancel();
    _unmuteWatchdog = null;
  }

  void _safeUnmute() {
    if (_aiHold || _manualMute) return; // don't auto-unmute if manually muted
    _cancelUnmuteWatchdog();
    _safeUnmuteTimer?.cancel();
    _safeUnmuteTimer = Timer(const Duration(milliseconds: 500), () {
      if (_active && !_aiHold && !_manualMute) {
        _localTrack?.enabled = true;
      }
    });
  }

  /// Simple on/off audio control
  void muteAudio(bool mute) {
    final stream = _remoteStream;
    if (stream == null) {
      _audioMuted = mute;
      _audioMuteAppliedStream = null;
      return;
    }
    if (_audioMuted == mute && identical(_audioMuteAppliedStream, stream)) {
      return;
    }
    _audioMuted = mute;
    _audioMuteAppliedStream = stream;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !mute;
    }
  }

  void _injectFewShotExamples() {
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    final payloads = _fewShotPayloads(sourceLangCode, targetLangCode);
    for (final payload in payloads) {
      _dc!.send(RTCDataChannelMessage(payload));
    }
  }

  static List<String> _fewShotPayloads(String sourceCode, String targetCode) {
    final key = '$sourceCode\x1f$targetCode';
    final cached = _fewShotPayloadCache[key];
    if (cached != null) return cached;

    final examples = AppPrompts.realtimeFewShotExamples(sourceCode, targetCode);
    final payloads = <String>[];
    for (final ex in examples) {
      payloads
        ..add(_conversationInputTextItemPayload(ex['user'] ?? ''))
        ..add(_conversationOutputTextItemPayload(ex['assistant'] ?? ''));
    }
    _fewShotPayloadCache[key] = payloads;
    return payloads;
  }

  String? getResponseIdForItem(String itemId) => _itemToResponse[itemId];

  String inputTranscriptForItem(String itemId) {
    final responseId = _itemToResponse[itemId];
    if (responseId != null) {
      final input = turns[responseId]?.input.trim();
      if (input != null && input.isNotEmpty) return input;
    }
    return _itemInputTranscripts[itemId]
            ?.toString()
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim() ??
        '';
  }

  void _appendInputTranscript(String? itemId, Object? delta) {
    if (itemId == null || delta == null) return;
    final responseId = _itemToResponse[itemId];
    if (responseId != null) {
      turns[responseId]?.appendInput(delta);
      return;
    }
    _itemInputTranscripts.putIfAbsent(itemId, StringBuffer.new).write(delta);
  }

  void _replaceInputTranscript(String? itemId, Object? transcript) {
    if (itemId == null) return;
    final text = transcript?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty) return;
    final responseId = _itemToResponse[itemId];
    if (responseId != null) {
      turns[responseId]?.replaceInput(text);
      return;
    }
    _itemInputTranscripts[itemId] = StringBuffer(text);
  }

  void clearInputBuffer() {
    _sendControlMessage(_inputAudioBufferClearPayload);
  }

  /// Apply VAD / turn-detection changes to a live session without recreating it.
  /// turn_detection is runtime-mutable via session.update (unlike voice/model).
  void updateTurnDetection({
    String? turnDetectionType,
    double? vadThreshold,
    int? silenceDurationMs,
    String? vadEagerness,
  }) {
    if (turnDetectionType != null) this.turnDetectionType = turnDetectionType;
    if (vadThreshold != null) this.vadThreshold = vadThreshold;
    if (silenceDurationMs != null) this.silenceDurationMs = silenceDurationMs;
    if (vadEagerness != null) this.vadEagerness = vadEagerness;
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    final payload = jsonEncode({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'audio': {
          'input': {'turn_detection': _buildTurnDetection()},
        },
      },
    });
    _sendControlMessage(payload);
  }

  void clearState() {
    sendCancel();
    turns.clear();
    _itemToResponse.clear();
    _itemInputTranscripts.clear();
    currentResponseId = null;
    _lastUserItemId = null;
    _pendingTextInput = null;
  }

  void sendCancel() {
    if (currentResponseId != null) {
      _sendControlMessage(_responseCancelPayload);
    }
  }

  String? _pendingTextInput; // for text input (no transcript event)

  void sendText(String text) {
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _pendingTextInput = text;
    _dc!.send(RTCDataChannelMessage(_conversationInputTextItemPayload(text)));
    _sendControlMessage(_responseCreatePayload);
  }

  void _sendControlMessage(String payload) {
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dc!.send(RTCDataChannelMessage(payload));
    }
  }

  static String _conversationItemDeletePayload(String itemId) {
    return '{"type":"conversation.item.delete","item_id":${jsonEncode(itemId)}}';
  }

  static String _conversationInputTextItemPayload(String text) {
    return '{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":${jsonEncode(text)}}]}}';
  }

  static String _conversationOutputTextItemPayload(String text) {
    return '{"type":"conversation.item.create","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":${jsonEncode(text)}}]}}';
  }

  Future<RTCVideoRenderer?> _createRemoteRenderer() async {
    if (textOnly) return null;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    return renderer;
  }

  static Future<void> _closePeerConnection(RTCPeerConnection pc) async {
    try {
      await pc.close();
    } catch (_) {}
  }

  static Future<void> _disposeRemoteRenderer(RTCVideoRenderer? renderer) async {
    if (renderer == null) return;
    try {
      renderer.srcObject = null;
      await renderer.dispose();
    } catch (_) {}
  }

  static Future<void> _disposeMediaStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  static Future<void> _cleanup(Future<void> future) {
    return future.timeout(_cleanupTimeout, onTimeout: () {}).catchError((_) {});
  }

  Future<void> stop() async {
    _stopping = true;
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.complete();
    }
    _sessionReady = null;
    _active = false;
    _aiHold = false;
    _manualMute = false;
    _cancelUnmuteWatchdog();
    _safeUnmuteTimer?.cancel();

    final dataChannel = _dc;
    _dc = null;
    final localStream = _localStream;
    _localStream = null;
    _localTrack = null;
    _remoteStream = null;
    _audioMuted = null;
    _audioMuteAppliedStream = null;
    final remoteRenderer = _remoteRenderer;
    _remoteRenderer = null;
    final peerConnection = _pc;
    _pc = null;

    await Future.wait([
      if (dataChannel != null)
        _cleanup(() async {
          try {
            await dataChannel.close();
          } catch (_) {}
        }()),
      if (localStream != null) _cleanup(_disposeMediaStream(localStream)),
      if (remoteRenderer != null)
        _cleanup(_disposeRemoteRenderer(remoteRenderer)),
      if (peerConnection != null)
        _cleanup(_closePeerConnection(peerConnection)),
    ]);

    turns.clear();
    _itemToResponse.clear();
    _itemInputTranscripts.clear();
    currentResponseId = null;
    _lastUserItemId = null;
    _pendingTextInput = null;
  }
}
