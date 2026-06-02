import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'realtime_audio_output.dart';

class RealtimeTranslationService {
  static final http.Client _httpClient = http.Client();
  static int _nextInstanceId = 1;
  static const _requestTimeout = Duration(seconds: 30);
  static const _cleanupTimeout = Duration(seconds: 2);
  static const _diagnosticLogs = true;
  static final Uri _clientSecretsUri = Uri.parse(
    'https://api.openai.com/v1/realtime/translations/client_secrets',
  );
  static final Uri _callsUri = Uri.parse(
    'https://api.openai.com/v1/realtime/translations/calls',
  );
  static const _sessionClosePayload = '{"type":"session.close"}';
  static const _sessionCloseTimeout = Duration(milliseconds: 3500);
  static final Map<String, dynamic> _mediaConstraints = {'audio': true};
  static final Map<String, dynamic> _peerConnectionConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  final String apiKey;
  final String targetLangCode;
  final String model;
  final bool playTranslatedAudio;
  final double audioPan;
  final double audioBoostGain;
  final int audioBoostDurationMs;
  final String inputNoiseReduction;
  final String debugLabel;
  final void Function(String type, Map<String, dynamic> event) onEvent;
  late final int _instanceId = _nextInstanceId++;
  late final Map<String, String> _clientSecretHeaders = {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
  };

  @visibleForTesting
  static Map<String, dynamic> buildClientSecretRequestBody({
    required String model,
    required String targetLangCode,
    String inputNoiseReduction = 'near_field',
  }) {
    final inputAudio = <String, dynamic>{};
    if (inputNoiseReduction == 'near_field' ||
        inputNoiseReduction == 'far_field') {
      inputAudio['noise_reduction'] = {'type': inputNoiseReduction};
    }
    return {
      'session': {
        'model': model,
        'audio': {
          if (inputAudio.isNotEmpty) 'input': inputAudio,
          'output': {'language': targetLangCode},
        },
      },
    };
  }

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  MediaStreamTrack? _localTrack;
  RTCRtpSender? _localSender;
  MediaStream? _remoteStream;
  RealtimeAudioOutputController? _audioOutput;
  Timer? _statsTimer;
  bool _active = false;
  bool _closing = false;
  bool _stopping = false;
  bool? _audioMuted;
  late double _audioPan;
  late double _audioBoostGain;
  late int _audioBoostDurationMs;
  MediaStream? _audioMuteAppliedStream;
  Completer<void>? _sessionReady;
  Completer<void>? _transportReady;
  Completer<void>? _sessionClosed;
  bool _sessionCloseReceived = false;
  int? _lastPacketsSent;
  int? _lastBytesSent;
  double? _lastAudioEnergy;

  RealtimeTranslationService({
    required this.apiKey,
    required this.targetLangCode,
    this.model = 'gpt-realtime-translate',
    this.playTranslatedAudio = false,
    this.audioPan = 0,
    this.audioBoostGain = 1.65,
    this.audioBoostDurationMs = 1100,
    this.inputNoiseReduction = 'near_field',
    this.debugLabel = '',
    required this.onEvent,
  }) {
    _audioPan = audioPan;
    _audioBoostGain = audioBoostGain;
    _audioBoostDurationMs = audioBoostDurationMs;
  }

  bool get isActive => _active;

  void _throwIfStopping() {
    if (_stopping) throw StateError('Realtime translation stopped');
  }

  String get _logPrefix {
    final label = debugLabel.isEmpty ? targetLangCode : debugLabel;
    return '[RT-TR:$label#$_instanceId]';
  }

  void _log(String msg) {
    if (_diagnosticLogs) debugPrint('$_logPrefix $msg');
  }

  Future<http.Response> _createClientSecret(String noiseReduction) {
    return _httpClient
        .post(
          _clientSecretsUri,
          headers: _clientSecretHeaders,
          body: jsonEncode(
            buildClientSecretRequestBody(
              model: model,
              targetLangCode: targetLangCode,
              inputNoiseReduction: noiseReduction,
            ),
          ),
        )
        .timeout(_requestTimeout);
  }

  Future<void> start({bool muted = false}) async {
    if (_active) return;
    _log(
      'start muted=$muted target=$targetLangCode audio=$playTranslatedAudio '
      'pan=$_audioPan boost=${_audioBoostGain}x/${_audioBoostDurationMs}ms',
    );
    _stopping = false;
    _sessionCloseReceived = false;

    Future<MediaStream>? localStreamFuture;
    Future<RTCPeerConnection>? peerConnectionFuture;
    try {
      localStreamFuture = navigator.mediaDevices.getUserMedia(
        _mediaConstraints,
      );
      peerConnectionFuture = createPeerConnection(_peerConnectionConfig);

      var tokenRes = await _createClientSecret(inputNoiseReduction);
      if (inputNoiseReduction != 'none' &&
          tokenRes.statusCode == 400 &&
          tokenRes.body.contains('noise_reduction')) {
        _log('client_secret retry_without_noise_reduction');
        tokenRes = await _createClientSecret('none');
      }
      _log('client_secret status=${tokenRes.statusCode}');

      if (tokenRes.statusCode != 200 && tokenRes.statusCode != 201) {
        throw Exception(
          'Failed to create translation session: '
          '${tokenRes.statusCode} ${tokenRes.body}',
        );
      }
      _throwIfStopping();

      final ephemeralKey = extractClientSecret(jsonDecode(tokenRes.body));

      _pc = await peerConnectionFuture;
      _throwIfStopping();

      _pc!.onTrack = (event) {
        if (_stopping) return;
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          _log(
            'remote_track streams=${event.streams.length} '
            'audioTracks=${_remoteStream!.getAudioTracks().length}',
          );
          unawaited(_attachRemoteAudio(_remoteStream!));
          onEvent('remote_stream', {});
        }
      };

      _transportReady = Completer<void>();
      _pc!.onConnectionState = (state) {
        _log('pc_state=$state active=$_active stopping=$_stopping');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _completeTransportReady();
        }
        if (!_active || _stopping) return;
        if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          onEvent('connection_lost', {});
        }
      };
      _pc!.onIceConnectionState = (state) {
        _log('ice_state=$state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _completeTransportReady();
        }
      };

      _localStream = await localStreamFuture;
      _localTrack = _localStream!.getAudioTracks().first;
      _localTrack!.enabled = !muted;
      _log(
        'local_stream_ready tracks=${_localStream!.getAudioTracks().length} '
        'trackEnabled=${_localTrack!.enabled} '
        'trackMuted=${_localTrack!.muted} trackId=${_localTrack!.id}',
      );
      _localTrack!.onMute = () => _log('local_track_muted');
      _localTrack!.onUnMute = () => _log('local_track_unmuted');
      _localTrack!.onEnded = () => _log('local_track_ended');
      _localSender = await _pc!.addTrack(_localTrack!, _localStream!);
      _throwIfStopping();

      _sessionReady = Completer<void>();
      _dc = await _pc!.createDataChannel('oai-events', RTCDataChannelInit());
      _dc!.onDataChannelState = (state) {
        _log('dc_state=$state');
      };
      _dc!.onMessage = (msg) {
        try {
          final event = jsonDecode(msg.text) as Map<String, dynamic>;
          _handleEvent(event);
        } catch (_) {}
      };

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _log('local_offer_set');
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
      _log('call_sdp status=${sdpRes.statusCode}');

      if (sdpRes.statusCode != 200 && sdpRes.statusCode != 201) {
        throw Exception(
          'Realtime translation connection failed: '
          '${sdpRes.statusCode} ${sdpRes.body}',
        );
      }
      _throwIfStopping();

      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdpRes.body, 'answer'),
      );
      _log('remote_answer_set');
      _throwIfStopping();

      await Future.wait([
        _sessionReady!.future,
        _transportReady!.future,
      ]).timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw Exception('Realtime translation setup timed out'),
      );
      _throwIfStopping();
      _sessionReady = null;
      _transportReady = null;
      _active = true;
      _startStatsLogging();
      _log(
        'ready active=$_active trackEnabled=${_localTrack?.enabled} '
        'trackMuted=${_localTrack?.muted}',
      );
    } catch (_) {
      _log('start_failed');
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
      await stop();
      rethrow;
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    if (_stopping && !_closing) {
      if (type == 'session.closed') {
        _sessionCloseReceived = true;
        final sessionClosed = _sessionClosed;
        if (sessionClosed != null && !sessionClosed.isCompleted) {
          sessionClosed.complete();
        }
      }
      _log('event_ignored_stopping type=$type');
      return;
    }
    if (_shouldLogEvent(type)) {
      _log(_describeEventForLog(type, event));
    }
    switch (type) {
      case 'session.created':
      case 'session.updated':
        _sessionReady?.complete();
        break;
      case 'session.input_transcript.delta':
      case 'session.input_transcript.done':
      case 'session.input_audio_buffer.speech_started':
      case 'session.input_audio_buffer.speech_stopped':
      case 'input_audio_buffer.speech_started':
      case 'input_audio_buffer.speech_stopped':
      case 'session.output_audio.started':
      case 'session.output_audio.done':
      case 'output_audio_buffer.started':
      case 'output_audio_buffer.stopped':
      case 'session.output_transcript.delta':
      case 'session.output_transcript.done':
      case 'error':
        onEvent(type, event);
        break;
      case 'session.closed':
        _sessionCloseReceived = true;
        final sessionClosed = _sessionClosed;
        if (sessionClosed != null && !sessionClosed.isCompleted) {
          sessionClosed.complete();
        }
        onEvent(type, event);
        break;
    }
  }

  void _completeTransportReady() {
    final transportReady = _transportReady;
    if (transportReady != null && !transportReady.isCompleted) {
      _log('transport_ready');
      transportReady.complete();
    }
  }

  @visibleForTesting
  static String extractClientSecret(Object? tokenData) {
    if (tokenData case {'value': final String value} when value.isNotEmpty) {
      return value;
    }
    if (tokenData case {
      'client_secret': {'value': final String value},
    } when value.isNotEmpty) {
      return value;
    }
    throw const FormatException('Realtime translation client secret missing');
  }

  @visibleForTesting
  void handleEventForTesting(Map<String, dynamic> event) => _handleEvent(event);

  void muteMic(bool mute) {
    final enabled = !mute;
    if (_localTrack?.enabled == enabled) {
      _log(
        'muteMic($mute) skipped trackEnabled=${_localTrack?.enabled} '
        'trackMuted=${_localTrack?.muted}',
      );
      return;
    }
    _localTrack?.enabled = enabled;
    _log(
      'muteMic($mute) applied trackEnabled=${_localTrack?.enabled} '
      'trackMuted=${_localTrack?.muted}',
    );
  }

  void _startStatsLogging() {
    _statsTimer?.cancel();
    _lastPacketsSent = null;
    _lastBytesSent = null;
    _lastAudioEnergy = null;
    if (!_diagnosticLogs) return;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_logOutboundAudioStats());
    });
    unawaited(_logOutboundAudioStats());
  }

  Future<void> _logOutboundAudioStats() async {
    final sender = _localSender;
    if (!_active || _stopping || sender == null) return;
    try {
      final reports = await sender.getStats();
      StatsReport? outbound;
      StatsReport? source;
      for (final report in reports) {
        if (report.type == 'outbound-rtp') {
          final kind = report.values['kind'] ?? report.values['mediaType'];
          if (kind == null || kind.toString() == 'audio') {
            outbound = report;
          }
        } else if (report.type == 'media-source' || report.type == 'track') {
          final kind = report.values['kind'] ?? report.values['mediaType'];
          if (kind == null || kind.toString() == 'audio') {
            source = report;
          }
        }
      }
      final packets = _asInt(outbound?.values['packetsSent']);
      final bytes = _asInt(outbound?.values['bytesSent']);
      final audioLevel = _asDouble(
        source?.values['audioLevel'] ?? outbound?.values['audioLevel'],
      );
      final energy = _asDouble(
        source?.values['totalAudioEnergy'] ??
            outbound?.values['totalAudioEnergy'],
      );
      final packetsDelta = packets == null || _lastPacketsSent == null
          ? null
          : packets - _lastPacketsSent!;
      final bytesDelta = bytes == null || _lastBytesSent == null
          ? null
          : bytes - _lastBytesSent!;
      final energyDelta = energy == null || _lastAudioEnergy == null
          ? null
          : energy - _lastAudioEnergy!;
      _lastPacketsSent = packets ?? _lastPacketsSent;
      _lastBytesSent = bytes ?? _lastBytesSent;
      _lastAudioEnergy = energy ?? _lastAudioEnergy;
      final activeAudio =
          _localTrack?.enabled == true &&
          ((audioLevel != null && audioLevel > 0.015) ||
              (energyDelta != null && energyDelta > 0.01));
      if (activeAudio) {
        onEvent('local_audio_activity', {
          'audio_level': audioLevel,
          'energy_delta': energyDelta,
          'packets_delta': packetsDelta,
          'bytes_delta': bytesDelta,
          'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } catch (e) {
      _log('audio_stats_failed $e');
    }
  }

  void clearInputBuffer() {
    // Translation sessions do not support the generic Realtime
    // input_audio_buffer.clear event. Keep this as a no-op so callers can
    // share the session-switching flow without causing server errors.
    _log('clearInputBuffer noop');
  }

  void commitInputBuffer() {
    // Translation sessions create turns internally from streamed audio.
    _log('commitInputBuffer noop');
  }

  void muteAudio(bool mute) {
    final stream = _remoteStream;
    if (stream == null) {
      _audioMuted = mute;
      _audioMuteAppliedStream = null;
      _log('muteAudio($mute) queued remoteStream=null');
      return;
    }
    if (_audioMuted == mute && identical(_audioMuteAppliedStream, stream)) {
      _log('muteAudio($mute) skipped sameStream');
      return;
    }
    _audioMuted = mute;
    _audioMuteAppliedStream = stream;
    _log('muteAudio($mute) applied');
    unawaited(_audioOutput?.setMuted(mute));
  }

  void setAudioPan(double pan) {
    _audioPan = pan;
    _log('setAudioPan($pan)');
    unawaited(_audioOutput?.setPan(pan));
  }

  void setAudioBoost({required double gain, required int durationMs}) {
    _audioBoostGain = gain;
    _audioBoostDurationMs = durationMs;
    _log('setAudioBoost gain=$gain durationMs=$durationMs');
    unawaited(_audioOutput?.setBoost(gain: gain, durationMs: durationMs));
  }

  void primeAudioOutput() {
    _log('primeAudioOutput muted=$_audioMuted');
    unawaited(_audioOutput?.primeOutput());
  }

  static Future<void> setNativeOutputPan(double pan) {
    return RealtimeAudioOutputController.setGlobalPan(pan);
  }

  static Future<void> warmUpAudioOutput() {
    return RealtimeAudioOutputController.warmUp();
  }

  static Future<bool> playBufferedAudio(
    Uint8List audioBytes, {
    required double pan,
    int leadInMs = 0,
    double initialBoostGain = 1,
    int initialBoostDurationMs = 0,
    double leadInGain = 0,
  }) {
    return RealtimeAudioOutputController.playBufferedAudio(
      audioBytes,
      pan: pan,
      leadInMs: leadInMs,
      initialBoostGain: initialBoostGain,
      initialBoostDurationMs: initialBoostDurationMs,
      leadInGain: leadInGain,
    );
  }

  static Future<void> stopBufferedAudio() {
    return RealtimeAudioOutputController.stopBufferedAudio();
  }

  Future<void> _attachRemoteAudio(MediaStream stream) async {
    final output = _audioOutput ??= RealtimeAudioOutputController();
    final mute = _audioMuted ?? !playTranslatedAudio;
    try {
      _log(
        'attachRemoteAudio muted=$mute pan=$_audioPan '
        'boost=${_audioBoostGain}x/${_audioBoostDurationMs}ms',
      );
      await output.attach(
        stream,
        muted: mute,
        pan: _audioPan,
        boostGain: _audioBoostGain,
        boostDurationMs: _audioBoostDurationMs,
      );
      if (!_stopping) muteAudio(mute);
    } catch (e) {
      _log('attachRemoteAudio_failed $e');
    }
  }

  static String _describeEventForLog(String type, Map<String, dynamic> event) {
    final parts = <String>['event=$type'];
    final responseId = event['response_id'] ?? event['response']?['id'];
    final itemId = event['item_id'];
    if (responseId != null) parts.add('response=$responseId');
    if (itemId != null) parts.add('item=$itemId');
    final delta = event['delta'];
    if (delta != null) parts.add('deltaLen=${delta.toString().length}');
    final transcript = event['transcript'];
    if (transcript != null) {
      parts.add('transcriptLen=${transcript.toString().length}');
    }
    final err = event['error']?['message'];
    if (err != null) parts.add('error=$err');
    return parts.join(' ');
  }

  static bool _shouldLogEvent(String type) {
    return switch (type) {
      'session.output_transcript.delta' ||
      'session.input_transcript.delta' => false,
      _ => true,
    };
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static Future<void> _closePeerConnection(RTCPeerConnection pc) async {
    try {
      await pc.close();
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

  Future<void> _closeSessionGracefully(RTCDataChannel dataChannel) async {
    if (_sessionCloseReceived ||
        !_active ||
        dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    final closed = _sessionClosed ??= Completer<void>();
    try {
      dataChannel.send(RTCDataChannelMessage(_sessionClosePayload));
      await closed.future.timeout(_sessionCloseTimeout, onTimeout: () {});
    } catch (_) {}
  }

  Future<void> stop() async {
    _log('stop active=$_active stopping=$_stopping');
    if (_stopping) return;
    _statsTimer?.cancel();
    _statsTimer = null;
    final dataChannel = _dc;
    _closing = true;
    _localTrack?.enabled = false;
    if (dataChannel != null) {
      await _closeSessionGracefully(dataChannel);
    }
    _closing = false;
    _stopping = true;

    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.complete();
    }
    _sessionReady = null;
    final transportReady = _transportReady;
    if (transportReady != null && !transportReady.isCompleted) {
      transportReady.complete();
    }
    _transportReady = null;
    final sessionClosed = _sessionClosed;
    if (sessionClosed != null && !sessionClosed.isCompleted) {
      sessionClosed.complete();
    }
    _sessionClosed = null;
    _sessionCloseReceived = false;
    _active = false;

    _dc = null;
    final localStream = _localStream;
    _localStream = null;
    _localTrack = null;
    _localSender = null;
    final remoteStream = _remoteStream;
    _remoteStream = null;
    final audioOutput = _audioOutput;
    _audioOutput = null;
    _audioMuted = null;
    _audioMuteAppliedStream = null;
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
      if (remoteStream != null) _cleanup(_disposeMediaStream(remoteStream)),
      if (audioOutput != null) _cleanup(audioOutput.dispose()),
      if (peerConnection != null)
        _cleanup(_closePeerConnection(peerConnection)),
    ]);
  }
}
