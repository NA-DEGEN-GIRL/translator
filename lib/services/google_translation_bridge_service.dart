import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/web_socket_channel.dart';

class GoogleTranslationBridgeService {
  static const defaultSampleRateHz = 16000;

  final Uri bridgeUri;
  final String sourceLangCode;
  final String targetLangCode;
  final int sampleRateHz;
  final void Function(String type, Map<String, dynamic> event) onEvent;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _active = false;

  GoogleTranslationBridgeService({
    required this.bridgeUri,
    required this.sourceLangCode,
    required this.targetLangCode,
    this.sampleRateHz = defaultSampleRateHz,
    required this.onEvent,
  });

  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    final channel = WebSocketChannel.connect(bridgeUri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) {
        onEvent('error', {
          'type': 'error',
          'error': {'message': error.toString()},
        });
      },
      onDone: () {
        _active = false;
        onEvent('session.closed', {'type': 'session.closed'});
      },
    );
    channel.sink.add(
      jsonEncode(
        buildStartMessage(
          sourceLangCode: sourceLangCode,
          targetLangCode: targetLangCode,
          sampleRateHz: sampleRateHz,
        ),
      ),
    );
    _active = true;
  }

  void sendAudioChunk(Uint8List bytes) {
    if (!_active || bytes.isEmpty) return;
    _channel?.sink.add(buildAudioAppendPayload(bytes));
  }

  Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    _active = false;
    await _subscription?.cancel();
    _subscription = null;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode({'type': 'session.stop'}));
    } catch (_) {}
    await channel.sink.close();
  }

  void _handleMessage(dynamic message) {
    final event = normalizeServerEvent(message);
    if (event == null) return;
    final type = event['type'] as String? ?? '';
    if (type.isEmpty) return;
    onEvent(type, event);
  }

  @visibleForTesting
  static Map<String, dynamic> buildStartMessage({
    required String sourceLangCode,
    required String targetLangCode,
    int sampleRateHz = defaultSampleRateHz,
  }) {
    return {
      'type': 'session.start',
      'provider': 'google.media_translation',
      'source_language_code': sourceLangCode,
      'target_language_code': targetLangCode,
      'interim_results': true,
      'audio': {
        'encoding': 'linear16',
        'sample_rate_hz': sampleRateHz,
        'channels': 1,
      },
    };
  }

  @visibleForTesting
  static String buildAudioAppendPayload(Uint8List bytes) {
    return jsonEncode({'type': 'audio.append', 'audio': base64Encode(bytes)});
  }

  @visibleForTesting
  static Map<String, dynamic>? normalizeServerEvent(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    final event = _asStringKeyMap(decoded);
    if (event == null) return null;

    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'session.started':
      case 'session.closed':
      case 'source_transcript.delta':
      case 'source_transcript.done':
      case 'translation.delta':
      case 'translation.done':
      case 'error':
        return event;
      case 'transcript.delta':
        return {
          ...event,
          'type': 'source_transcript.delta',
          'delta': _textFrom(event),
        };
      case 'transcript.final':
      case 'transcript.done':
        return {
          ...event,
          'type': 'source_transcript.done',
          'transcript': _textFrom(event),
        };
      case 'translation.final':
        return {
          ...event,
          'type': 'translation.done',
          'transcript': _textFrom(event),
        };
      case 'google.media_translation.response':
      case 'google.media_translation.result':
        return _normalizeGoogleMediaTranslationResult(event) ?? event;
    }

    return _normalizeGoogleMediaTranslationResult(event) ?? event;
  }

  static Map<String, dynamic>? _normalizeGoogleMediaTranslationResult(
    Map<String, dynamic> event,
  ) {
    final result = _asStringKeyMap(event['result']) ?? event;
    final textTranslation =
        _asStringKeyMap(result['text_translation_result']) ??
        _asStringKeyMap(result['textTranslationResult']);
    if (textTranslation == null) return null;

    final translation = _textFrom(textTranslation);
    if (translation.isEmpty) return null;
    final isFinal =
        _boolFrom(textTranslation['is_final']) ??
        _boolFrom(textTranslation['isFinal']) ??
        _boolFrom(result['is_final']) ??
        _boolFrom(result['isFinal']) ??
        false;
    return {
      ...event,
      'type': isFinal ? 'translation.done' : 'translation.delta',
      if (isFinal) 'transcript': translation else 'delta': translation,
    };
  }

  static String _textFrom(Map<String, dynamic> event) {
    for (final key in const ['translation', 'transcript', 'text', 'delta']) {
      final value = event[key];
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return '';
  }

  static bool? _boolFrom(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    return null;
  }

  static Map<String, dynamic>? _asStringKeyMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
}
