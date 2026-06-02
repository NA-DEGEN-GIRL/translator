import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'openai_ws_channel.dart';

class ResponsesTextWsService {
  static final Uri _defaultUri = Uri.parse('wss://api.openai.com/v1/responses');
  static const _cleanupTimeout = Duration(seconds: 2);
  static const _maxConnectionAge = Duration(minutes: 55);

  final String apiKey;
  final Uri uri;
  final bool sendApiKey;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Future<void>? _startFuture;
  DateTime? _connectedAt;
  bool _active = false;
  bool _stopping = false;
  Future<void> _requestChain = Future.value();
  Completer<String>? _pendingCompleter;
  String? _activeResponseId;
  StringBuffer? _activeOutput;
  void Function(String delta)? _activeDeltaHandler;

  ResponsesTextWsService({
    required this.apiKey,
    Uri? uri,
    this.sendApiKey = true,
  }) : uri = uri ?? _defaultUri;

  bool get isActive => _active;

  Future<void> start() {
    final existing = _startFuture;
    if (existing != null) return existing;
    if (_active && !_isTooOld) return Future.value();
    return _startFuture = _start().whenComplete(() => _startFuture = null);
  }

  Future<String> sendTextForResult({
    required String model,
    required String instructions,
    required String text,
    List<Map<String, String>> context = const [],
    bool jsonObject = false,
    double? temperature,
    String? reasoningEffort,
    void Function(String delta)? onDelta,
    int maxOutputTokens = 512,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final task = _requestChain.then((_) async {
      await start();
      return _sendTextForResultNow(
        model: model,
        instructions: instructions,
        text: text,
        context: context,
        jsonObject: jsonObject,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        onDelta: onDelta,
        maxOutputTokens: maxOutputTokens,
        timeout: timeout,
      );
    });
    _requestChain = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<void> stop() async {
    _stopping = true;
    _active = false;
    _startFuture = null;
    _completePendingWithError(Exception('Responses WebSocket stopped'));
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    _connectedAt = null;
    await Future.wait([
      if (subscription != null) _cleanup(subscription.cancel()),
      if (channel != null) _cleanup(channel.sink.close()),
    ]);
    _clearActiveResponse();
    _stopping = false;
  }

  Future<void> _start() async {
    if (_channel != null || _subscription != null || _isTooOld) {
      await stop();
    }
    _stopping = false;
    try {
      final channel = connectOpenAIWebSocket(
        uri: uri,
        apiKey: sendApiKey ? apiKey : null,
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (Object error) {
          _active = false;
          _completePendingWithError(error);
        },
        onDone: () {
          _active = false;
          _completePendingWithError(Exception('Responses WebSocket closed'));
        },
      );
      await channel.ready.timeout(const Duration(seconds: 10));
      if (_stopping) throw StateError('Responses WebSocket stopped');
      _connectedAt = DateTime.now();
      _active = true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<String> _sendTextForResultNow({
    required String model,
    required String instructions,
    required String text,
    required List<Map<String, String>> context,
    required bool jsonObject,
    required double? temperature,
    required String? reasoningEffort,
    required void Function(String delta)? onDelta,
    required int maxOutputTokens,
    required Duration timeout,
  }) {
    final channel = _channel;
    if (channel == null || !_active) {
      throw Exception('Responses WebSocket is not active');
    }
    final completer = Completer<String>();
    _pendingCompleter = completer;
    _activeDeltaHandler = onDelta;
    channel.sink.add(
      jsonEncode(
        _responseCreatePayload(
          model: model,
          instructions: instructions,
          text: text,
          context: context,
          jsonObject: jsonObject,
          temperature: temperature,
          reasoningEffort: reasoningEffort,
          maxOutputTokens: maxOutputTokens,
        ),
      ),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (_pendingCompleter == completer) _pendingCompleter = null;
        if (_activeOutput != null) {
          _clearActiveResponse();
        } else {
          _activeDeltaHandler = null;
        }
        throw TimeoutException('Responses WebSocket timed out', timeout);
      },
    );
  }

  Map<String, dynamic> _responseCreatePayload({
    required String model,
    required String instructions,
    required String text,
    required List<Map<String, String>> context,
    required bool jsonObject,
    required double? temperature,
    required String? reasoningEffort,
    required int maxOutputTokens,
  }) {
    final payload = <String, dynamic>{
      'type': 'response.create',
      'model': model,
      'store': false,
      'instructions': instructions,
      'input': _inputMessages(text, context, jsonObject: jsonObject),
      'tools': <Object>[],
      'max_output_tokens': maxOutputTokens,
      'text': {
        'format': {'type': jsonObject ? 'json_object' : 'text'},
      },
    };
    if (temperature != null && _supportsCustomTemperature(model)) {
      payload['temperature'] = temperature;
    }
    final normalizedReasoning = _responsesReasoningEffort(
      model,
      reasoningEffort,
    );
    if (normalizedReasoning != null) {
      payload['reasoning'] = {'effort': normalizedReasoning};
    }
    return payload;
  }

  List<Map<String, dynamic>> _inputMessages(
    String text,
    List<Map<String, String>> context, {
    required bool jsonObject,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (jsonObject) {
      messages.add(_message('system', 'Output must be valid JSON.'));
    }
    if (context.isNotEmpty) {
      final buffer = StringBuffer();
      for (final item in context) {
        final role = item['role'] ?? 'user';
        final content = item['content'] ?? '';
        if (content.trim().isEmpty) continue;
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln('[$role]');
        buffer.write(content);
      }
      if (buffer.isNotEmpty) {
        messages.add(_message('user', 'Conversation context:\n$buffer'));
      }
    }
    messages.add(_message('user', text));
    return messages;
  }

  Map<String, dynamic> _message(String role, String text) {
    return {
      'type': 'message',
      'role': role,
      'content': [
        {'type': 'input_text', 'text': text},
      ],
    };
  }

  void _handleMessage(dynamic message) {
    final text = message is String
        ? message
        : utf8.decode(message as List<int>);
    final event = _tryDecodeObject(text);
    if (event == null) return;
    final type = event['type']?.toString() ?? '';

    switch (type) {
      case 'response.created':
        final responseId = event['response']?['id'] as String?;
        _activeResponseId = responseId;
        _activeOutput = StringBuffer();
        break;
      case 'response.output_text.delta':
        if (_matchesActiveResponse(event)) {
          final delta = event['delta']?.toString() ?? '';
          _activeOutput?.write(delta);
          if (delta.isNotEmpty) _activeDeltaHandler?.call(delta);
        }
        break;
      case 'response.completed':
      case 'response.done':
        if (!_matchesDoneResponse(event)) return;
        final output = _activeOutput?.toString().trim();
        final fallback = _extractResponseOutputText(event['response']);
        final completer = _pendingCompleter;
        _pendingCompleter = null;
        _clearActiveResponse();
        if (completer != null && !completer.isCompleted) {
          completer.complete(
            output?.isNotEmpty == true ? output! : fallback.trim(),
          );
        }
        break;
      case 'response.failed':
      case 'response.incomplete':
        _completePendingWithError(Exception(_responseErrorMessage(event)));
        break;
      case 'error':
        _completePendingWithError(Exception(_responseErrorMessage(event)));
        break;
    }
  }

  bool _matchesActiveResponse(Map<String, dynamic> event) {
    final activeId = _activeResponseId;
    if (activeId == null) return true;
    final eventId =
        event['response_id']?.toString() ??
        event['response']?['id']?.toString();
    return eventId == null || eventId == activeId;
  }

  bool _matchesDoneResponse(Map<String, dynamic> event) {
    final activeId = _activeResponseId;
    if (activeId == null) return true;
    final eventId = event['response']?['id']?.toString();
    return eventId == null || eventId == activeId;
  }

  String _extractResponseOutputText(dynamic response) {
    final output = response is Map ? response['output'] : null;
    if (output is! List) return '';
    final buffer = StringBuffer();
    for (final item in output) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is Map && part['type'] == 'output_text') {
          buffer.write(part['text'] ?? '');
        }
      }
    }
    return buffer.toString();
  }

  String _responseErrorMessage(Map<String, dynamic> event) {
    final error = event['error'];
    if (error is Map && error['message'] != null) {
      return error['message'].toString();
    }
    final responseError = event['response']?['error'];
    if (responseError is Map && responseError['message'] != null) {
      return responseError['message'].toString();
    }
    final response = event['response'];
    final status = response is Map ? response['status'] : null;
    final incompleteDetails = response is Map
        ? response['incomplete_details']
        : null;
    final details = incompleteDetails == null
        ? ''
        : ' details=${jsonEncode(incompleteDetails)}';
    final type = event['type']?.toString() ?? 'unknown';
    final raw = jsonEncode(event);
    final clipped = raw.length > 800 ? '${raw.substring(0, 800)}...' : raw;
    return 'Responses WebSocket error type=$type status=$status$details event=$clipped';
  }

  void _completePendingWithError(Object error) {
    final completer = _pendingCompleter;
    _pendingCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
    _clearActiveResponse();
  }

  void _clearActiveResponse() {
    _activeResponseId = null;
    _activeOutput = null;
    _activeDeltaHandler = null;
  }

  bool get _isTooOld {
    final connectedAt = _connectedAt;
    return connectedAt != null &&
        DateTime.now().difference(connectedAt) >= _maxConnectionAge;
  }

  Future<void> _cleanup(Future<void> future) {
    return future.timeout(_cleanupTimeout, onTimeout: () {}).catchError((_) {});
  }

  static Map<String, dynamic>? _tryDecodeObject(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _supportsCustomTemperature(String model) {
    final id = model.toLowerCase();
    return !id.startsWith('gpt-5') &&
        !id.startsWith('o1') &&
        !id.startsWith('o3') &&
        !id.startsWith('o4');
  }

  static bool _supportsReasoningEffort(String model) {
    final id = model.toLowerCase();
    return id.startsWith('gpt-5') || id.startsWith('o');
  }

  static String? _responsesReasoningEffort(
    String model,
    String? reasoningEffort,
  ) {
    final effort = reasoningEffort?.trim();
    if (effort == null ||
        effort.isEmpty ||
        effort == 'none' ||
        !_supportsReasoningEffort(model)) {
      return null;
    }

    final id = model.toLowerCase();
    final isBaseGpt5 = id == 'gpt-5' || id.startsWith('gpt-5-');
    if (effort == 'minimal' && !isBaseGpt5) {
      return null;
    }
    return effort;
  }
}
