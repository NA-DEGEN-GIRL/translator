import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/language.dart';
import '../prompts.dart';

class RealtimeTurn {
  String input = '';
  String output = '';
  String? userItemId; // links response to user conversation item
}

class RealtimeService {
  final String apiKey;
  final String model;
  final String voice;
  final String sourceLangCode;
  final String targetLangCode;
  final double vadThreshold;
  final ToneMode tone;
  final String? instructions;
  final bool deleteConversationItems;
  final bool injectFewShot;
  final void Function(String type, Map<String, dynamic> event) onEvent;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  MediaStreamTrack? _localTrack;
  MediaStream? _remoteStream;
  RTCVideoRenderer? _remoteRenderer;
  bool _active = false;
  Completer<void>? _sessionReady;
  Timer? _unmuteWatchdog;
  Timer? _safeUnmuteTimer;

  final Map<String, RealtimeTurn> turns = {}; // keyed by response_id
  final Map<String, String> _itemToResponse = {}; // user item_id → response_id
  String? currentResponseId;
  String? _lastUserItemId; // most recent user conversation item

  RealtimeService({
    required this.apiKey,
    this.model = 'gpt-realtime-mini',
    this.voice = 'ash',
    this.sourceLangCode = 'ko',
    this.targetLangCode = 'ja',
    this.vadThreshold = 0.5,
    this.tone = ToneMode.normal,
    this.instructions,
    this.deleteConversationItems = true,
    this.injectFewShot = true,
    required this.onEvent,
  });

  bool get isActive => _active;
  MediaStream? get remoteStream => _remoteStream;

  String _buildSystemPrompt() {
    if (instructions != null) return instructions!;
    final src = getLangByCode(sourceLangCode);
    final tgt = getLangByCode(targetLangCode);
    return AppPrompts.realtimeTranslation(
      PromptLanguagePair(sourceLang: src.name, targetLang: tgt.name),
      tone: tone,
    );
  }

  Future<void> start() async {
    if (_active) return;

    final tokenRes = await http.post(
      Uri.parse('https://api.openai.com/v1/realtime/client_secrets'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'session': {
          'type': 'realtime',
          'model': model,
          'instructions': _buildSystemPrompt(),
          'audio': {
            'input': {
              'turn_detection': {
                'type': 'server_vad',
                'threshold': vadThreshold,
                'silence_duration_ms': 500,
                'create_response': true,
              },
            },
            'output': {'voice': voice},
          },
        }
      }),
    );

    if (tokenRes.statusCode != 200 && tokenRes.statusCode != 201) {
      throw Exception('Failed to create session: ${tokenRes.statusCode} ${tokenRes.body}');
    }

    final tokenData = jsonDecode(tokenRes.body);
    final ephemeralKey = tokenData['value'] as String;

    _pc = await createPeerConnection({
      'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
    });

    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _remoteRenderer!.srcObject = _remoteStream;
        onEvent('remote_stream', {});
      }
    };

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onEvent('connection_lost', {});
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      }
    });
    _localTrack = _localStream!.getAudioTracks().first;
    _pc!.addTrack(_localTrack!, _localStream!);

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

    final sdpRes = await http.post(
      Uri.parse('https://api.openai.com/v1/realtime/calls'),
      headers: {
        'Authorization': 'Bearer $ephemeralKey',
        'Content-Type': 'application/sdp',
      },
      body: offer.sdp,
    );

    if (sdpRes.statusCode != 200 && sdpRes.statusCode != 201) {
      throw Exception('WebRTC connection failed: ${sdpRes.statusCode} ${sdpRes.body}');
    }

    await _pc!.setRemoteDescription(
      RTCSessionDescription(sdpRes.body, 'answer'),
    );

    await _sessionReady!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw Exception('Realtime session setup timed out'),
    );
    _sessionReady = null;
    _active = true;
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    debugPrint('[RT] event: $type');

    switch (type) {
      case 'session.updated':
        final updatedInstr = event['session']?['instructions'] as String? ?? '';
        debugPrint('[RT] session.updated: instructionsLen=${updatedInstr.length} first100="${updatedInstr.substring(0, updatedInstr.length > 100 ? 100 : updatedInstr.length)}"');
        break;

      case 'session.created':
        final createdInstr = event['session']?['instructions'] as String? ?? '';
        final vadConfig = event['session']?['audio']?['input']?['turn_detection'];
        debugPrint('[RT] session.created: instructionsLen=${createdInstr.length} vad=$vadConfig');
        if (injectFewShot && _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _injectFewShotExamples();
        }
        _sessionReady?.complete();
        break;

      case 'input_audio_buffer.speech_started':
        if (currentResponseId != null) {
          _dc?.send(RTCDataChannelMessage(jsonEncode({'type': 'response.cancel'})));
        }
        break;

      case 'conversation.item.added':
        final addedItem = event['item'] as Map<String, dynamic>?;
        if (addedItem?['type'] == 'message' && addedItem?['role'] == 'user') {
          final itemId = addedItem?['id'] as String?;
          if (itemId != null) _lastUserItemId = itemId;
        }
        break;

      // transcription removed — Realtime model's understanding is a black box
      // back-translation serves as the "original" text instead

      case 'response.created':
        final respId = event['response']?['id'] as String?;
        debugPrint('[RT] response.created: id=$respId userItem=$_lastUserItemId');
        if (respId != null) {
          currentResponseId = respId;
          final userItem = _lastUserItemId;
          _lastUserItemId = null; // consume to prevent stale reuse
          final turn = RealtimeTurn()..userItemId = userItem;
          if (_pendingTextInput != null) {
            turn.input = _pendingTextInput!;
            _pendingTextInput = null;
          }
          turns[respId] = turn;
          if (userItem != null) {
            _itemToResponse[userItem] = respId;
          }
        }
        break;

      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
        final rid = event['response_id'] as String?;
        if (rid != null && turns.containsKey(rid)) {
          turns[rid]!.output += (event['delta'] ?? '');
        }
        break;

      case 'output_audio_buffer.started':
        _localTrack?.enabled = false; // mute mic during playback
        _safeUnmuteTimer?.cancel();
        _startUnmuteWatchdog(); // safety: unmute if stopped event never fires
        if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'input_audio_buffer.clear'})));
        }
        break;

      case 'output_audio_buffer.stopped':
      case 'output_audio_buffer.cleared':
        // Clear any echo captured in buffer during playback
        if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'input_audio_buffer.clear'})));
        }
        _safeUnmute();
        break;

      case 'response.done':
        final rid = event['response']?['id'] as String?;
        final status = event['response']?['status'] as String?;
        debugPrint('[RT] response.done: id=$rid status=$status');
        if (rid != null) {
          final turnOutput = turns[rid]?.output ?? '';
          final turnInput = turns[rid]?.input ?? '';
          debugPrint('[RT] response.done: input="$turnInput" output="${turnOutput.length > 100 ? turnOutput.substring(0, 100) : turnOutput}"');

          // Delete conversation items to prevent history bias (configurable)
          if (deleteConversationItems && status == 'completed' && _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
            final userItemId = turns[rid]?.userItemId;
            final outputItems = event['response']?['output'] as List?;
            final assistantItemId = outputItems?.isNotEmpty == true ? outputItems!.first['id'] as String? : null;
            if (userItemId != null) {
              _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'conversation.item.delete', 'item_id': userItemId})));
            }
            if (assistantItemId != null) {
              _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'conversation.item.delete', 'item_id': assistantItemId})));
            }
          }

          currentResponseId = null;
        }
        if (status != null && status != 'completed') {
          _safeUnmute();
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? '';
        final errCode = event['error']?['code'] ?? '';
        debugPrint('[RT] ERROR: code=$errCode msg=$errMsg');
        if (errMsg.toString().contains('no active response')) {
          return;
        }
        _safeUnmute();
        break;
    }

    onEvent(type, event);
  }

  bool _aiHold = false;
  bool _manualMute = false; // set by external muteMic(true), prevents auto-unmute

  void enterAIHold() {
    _aiHold = true;
    _cancelUnmuteWatchdog();
    _localTrack?.enabled = false;
    if (currentResponseId != null && _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'response.cancel'})));
    }
  }

  void exitAIHold() {
    _aiHold = false;
    _localTrack?.enabled = true;
  }

  void muteMic(bool mute) {
    if (_aiHold) return;
    _manualMute = mute;
    _localTrack?.enabled = !mute;
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
        onEvent('watchdog_unmute', {});
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
      if (_active && !_aiHold && !_manualMute) _localTrack?.enabled = true;
    });
  }

  /// Simple on/off audio control
  void muteAudio(bool mute) {
    if (_remoteStream != null) {
      for (final track in _remoteStream!.getAudioTracks()) {
        track.enabled = !mute;
      }
    }
  }

  void _injectFewShotExamples() {
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    final examples = AppPrompts.realtimeFewShotExamples(sourceLangCode, targetLangCode);
    for (final ex in examples) {
      _dc!.send(RTCDataChannelMessage(jsonEncode({
        'type': 'conversation.item.create',
        'item': {
          'type': 'message',
          'role': 'user',
          'content': [{'type': 'input_text', 'text': ex['user']}],
        },
      })));
      _dc!.send(RTCDataChannelMessage(jsonEncode({
        'type': 'conversation.item.create',
        'item': {
          'type': 'message',
          'role': 'assistant',
          'content': [{'type': 'output_text', 'text': ex['assistant']}],
        },
      })));
    }
  }

  List<Map<String, dynamic>> _buildFewShotInput() {
    final examples = AppPrompts.realtimeFewShotExamples(sourceLangCode, targetLangCode);
    final items = <Map<String, dynamic>>[];
    for (final ex in examples) {
      items.add({
        'type': 'message',
        'role': 'user',
        'content': [{'type': 'input_text', 'text': ex['user']}],
      });
      items.add({
        'type': 'message',
        'role': 'assistant',
        'content': [{'type': 'output_text', 'text': ex['assistant']}],
      });
    }
    return items;
  }


  String? getResponseIdForItem(String itemId) => _itemToResponse[itemId];

  void clearInputBuffer() {
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'input_audio_buffer.clear'})));
    }
  }

  void clearState() {
    sendCancel();
    turns.clear();
    _itemToResponse.clear();
    currentResponseId = null;
    _lastUserItemId = null;
    _pendingTextInput = null;
  }

  void sendCancel() {
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen && currentResponseId != null) {
      _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'response.cancel'})));
    }
  }

  String? _pendingTextInput; // for text input (no transcript event)

  void sendText(String text) {
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _pendingTextInput = text;
    _dc!.send(RTCDataChannelMessage(jsonEncode({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [{'type': 'input_text', 'text': text}],
      },
    })));
    _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'response.create'})));
  }

  Future<void> stop() async {
    _active = false;
    _aiHold = false;
    _manualMute = false;
    _cancelUnmuteWatchdog();
    _safeUnmuteTimer?.cancel();
    _dc?.close();
    _dc = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _localTrack = null;
    _remoteStream = null;
    if (_remoteRenderer != null) {
      try {
        _remoteRenderer!.srcObject = null;
        await _remoteRenderer!.dispose();
      } catch (_) {}
      _remoteRenderer = null;
    }
    await _pc?.close();
    _pc = null;
    turns.clear();
    _itemToResponse.clear();
    currentResponseId = null;
    _lastUserItemId = null;
    _pendingTextInput = null;
  }
}
