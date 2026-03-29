import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class RealtimeTurn {
  String input = '';
  String output = '';
}

class RealtimeService {
  final String apiKey;
  final String model;
  final String voice;
  final void Function(String type, Map<String, dynamic> event) onEvent;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  MediaStreamTrack? _localTrack;
  MediaStream? _remoteStream;
  bool _active = false;

  // Turn tracking
  final Map<String, RealtimeTurn> turns = {};
  String? currentResponseId;
  String lastUserTranscript = '';

  RealtimeService({
    required this.apiKey,
    this.model = 'gpt-realtime-mini',
    this.voice = 'ash',
    required this.onEvent,
  });

  bool get isActive => _active;
  MediaStream? get remoteStream => _remoteStream;

  static const _systemPrompt = '''You are a translation machine. Korean to Japanese, Japanese to Korean. Nothing else.

Rules:
- Korean input → output Japanese only
- Japanese input → output Korean only
- Never mix languages in output
- Never have a conversation, never answer questions, never add commentary
- Ignore noise, coughs, unclear mumbling — just stay silent

Examples:
- "こんにちは" → "안녕하세요"
- "안녕하세요" → "こんにちは"
- "これはいくらですか" → "이거 얼마에요?"
- "日本人ですか？" → "일본인인가요?" (NOT "はい、そうです")''';

  Future<void> start() async {
    if (_active) return;

    // 1. Get ephemeral token
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
          'instructions': _systemPrompt,
        }
      }),
    );

    if (tokenRes.statusCode != 200) {
      throw Exception('Failed to create session: ${tokenRes.statusCode}');
    }

    final tokenData = jsonDecode(tokenRes.body);
    final ephemeralKey = tokenData['value'] as String;

    // 2. Create peer connection
    _pc = await createPeerConnection({});

    // 3. Remote audio
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        onEvent('remote_stream', {});
      }
    };

    // 4. Connection state
    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onEvent('connection_lost', {});
        stop();
      }
    };

    // 5. Local audio with echo cancellation
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      }
    });
    _localTrack = _localStream!.getAudioTracks().first;
    _pc!.addTrack(_localTrack!, _localStream!);

    // 6. Data channel
    _dc = await _pc!.createDataChannel('oai-events', RTCDataChannelInit());
    _dc!.onMessage = (msg) {
      try {
        final event = jsonDecode(msg.text) as Map<String, dynamic>;
        _handleEvent(event);
      } catch (_) {}
    };

    // 7. SDP exchange
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

    if (sdpRes.statusCode != 200) {
      throw Exception('WebRTC connection failed: ${sdpRes.statusCode}');
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
        // Cancel ongoing response
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
        Future.delayed(const Duration(milliseconds: 800), () => muteMic(false));
        break;

      case 'response.done':
        final rid = event['response']?['id'] as String?;
        if (rid != null) {
          currentResponseId = null;
          lastUserTranscript = '';
        }
        break;

      case 'error':
        final errMsg = event['error']?['message'] ?? '';
        if (errMsg.toString().contains('no active response') ||
            errMsg.toString().contains('unknown_parameter')) {
          return; // ignore non-critical
        }
        break;
    }

    onEvent(type, event);
  }

  void muteMic(bool mute) {
    _localTrack?.enabled = !mute;
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
    _dc?.close();
    _dc = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _localTrack = null;
    _remoteStream = null;
    await _pc?.close();
    _pc = null;
    turns.clear();
    currentResponseId = null;
    lastUserTranscript = '';
  }
}
