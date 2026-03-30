import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/language.dart';

class RealtimeTurn {
  String input = '';
  String output = '';
}

class RealtimeService {
  final String apiKey;
  final String model;
  final String voice;
  final String sourceLangCode;
  final String targetLangCode;
  final void Function(String type, Map<String, dynamic> event) onEvent;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  MediaStreamTrack? _localTrack;
  MediaStream? _remoteStream;
  RTCVideoRenderer? _remoteRenderer;
  bool _active = false;
  Timer? _unmuteWatchdog;

  final Map<String, RealtimeTurn> turns = {};
  String? currentResponseId;
  String lastUserTranscript = '';

  RealtimeService({
    required this.apiKey,
    this.model = 'gpt-realtime-mini',
    this.voice = 'ash',
    this.sourceLangCode = 'ko',
    this.targetLangCode = 'ja',
    required this.onEvent,
  });

  bool get isActive => _active;
  MediaStream? get remoteStream => _remoteStream;

  String _buildSystemPrompt() {
    final src = getLangByCode(sourceLangCode);
    final tgt = getLangByCode(targetLangCode);

    return '''You are a strict translation engine.

TASK
- Translate ${src.name} <-> ${tgt.name} only.
- ${src.name} input -> ${tgt.name} output only.
- ${tgt.name} input -> ${src.name} output only.

HARD RULES
- DO NOT answer the user.
- DO NOT act like an assistant.
- DO NOT continue the conversation.
- DO NOT explain, summarize, or add politeness not present in the source.
- Preserve sentence type: question -> question, statement -> statement, command -> command.
- Preserve meaning, tone, and intent as literally as natural.
- Output translation only. No quotes. No labels. No extra words.
- If input is unclear, noise-only, or incomplete, output nothing.''';
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
          'audio': {'output': {'voice': voice}},
          'instructions': _buildSystemPrompt(),
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

    _active = true;
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';

    switch (type) {
      case 'input_audio_buffer.speech_started':
        if (currentResponseId != null) {
          _dc?.send(RTCDataChannelMessage(jsonEncode({'type': 'response.cancel'})));
        }
        break;

      case 'conversation.item.done':
        final item = event['item'] as Map<String, dynamic>?;
        if (item?['type'] == 'message' && item?['role'] == 'user') {
          final content = item?['content'] as List?;
          if (content != null) {
            for (final c in content) {
              if (c['type'] == 'input_audio' && c['transcript'] != null) {
                lastUserTranscript = c['transcript'];
              }
            }
          }
        }
        break;

      case 'response.created':
        final respId = event['response']?['id'] as String?;
        if (respId != null) {
          currentResponseId = respId;
          turns[respId] = RealtimeTurn()..input = lastUserTranscript;
        }
        break;

      case 'response.output_audio_transcript.delta':
        final rid = event['response_id'] as String?;
        if (rid != null && turns.containsKey(rid)) {
          turns[rid]!.output += (event['delta'] ?? '');
        }
        break;

      case 'output_audio_buffer.started':
        muteMic(true);
        break;

      case 'output_audio_buffer.stopped':
      case 'output_audio_buffer.cleared':
        _safeUnmute();
        break;

      case 'response.done':
        final rid = event['response']?['id'] as String?;
        if (rid != null) {
          currentResponseId = null;
          lastUserTranscript = '';
        }
        final status = event['response']?['status'] as String?;
        if (status != null && status != 'completed') {
          _safeUnmute();
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? '';
        if (errMsg.toString().contains('no active response') ||
            errMsg.toString().contains('unknown_parameter')) {
          return;
        }
        _safeUnmute();
        break;
    }

    onEvent(type, event);
  }

  bool _aiHold = false; // AI mode hold — prevents auto unmute

  void enterAIHold() {
    _aiHold = true;
    _cancelUnmuteWatchdog();
    _localTrack?.enabled = false;
    // Cancel any ongoing response
    if (currentResponseId != null && _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dc!.send(RTCDataChannelMessage(jsonEncode({'type': 'response.cancel'})));
    }
  }

  void exitAIHold() {
    _aiHold = false;
    _localTrack?.enabled = true;
  }

  void muteMic(bool mute) {
    if (_aiHold) return; // Don't auto-unmute during AI hold
    _localTrack?.enabled = !mute;
    if (mute) {
      _startUnmuteWatchdog();
    } else {
      _cancelUnmuteWatchdog();
    }
  }

  void _startUnmuteWatchdog() {
    _cancelUnmuteWatchdog();
    _unmuteWatchdog = Timer(const Duration(seconds: 5), () {
      if (_active && !_aiHold) {
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
    if (_aiHold) return; // Don't auto-unmute during AI hold
    _cancelUnmuteWatchdog();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_active && !_aiHold) _localTrack?.enabled = true;
    });
  }

  void muteAudio(bool mute) {
    if (_remoteStream != null) {
      for (final track in _remoteStream!.getAudioTracks()) {
        track.enabled = !mute;
      }
    }
  }

  void sendText(String text) {
    if (_dc?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    lastUserTranscript = text;
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
    _cancelUnmuteWatchdog();
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
    currentResponseId = null;
    lastUserTranscript = '';
  }
}
