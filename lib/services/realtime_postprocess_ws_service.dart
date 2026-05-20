import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_ws_channel.dart';

class RealtimePostProcessWsService {
  final String apiKey;
  final String instructions;
  final String model;
  final String reasoningEffort;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _active = false;
  Completer<void>? _sessionReady;
  Completer<String>? _pendingTextCompleter;
  Future<void> _textResultChain = Future.value();
  final Map<String, StringBuffer> _outputs = {};
  final Map<String, Completer<String>> _responseCompleters = {};
  String? _lastUserItemId;
  final Map<String, String?> _responseUserItems = {};

  RealtimePostProcessWsService({
    required this.apiKey,
    required this.instructions,
    this.model = 'gpt-realtime-2',
    this.reasoningEffort = 'minimal',
  });

  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    final uri = Uri.parse('wss://api.openai.com/v1/realtime?model=$model');
    final channel = connectRealtimeWebSocket(uri: uri, apiKey: apiKey);
    _channel = channel;
    _sessionReady = Completer<void>();
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error) {
        _completeAllWithError(error);
      },
      onDone: () {
        _active = false;
        _completeAllWithError(Exception('Realtime post-process socket closed'));
      },
    );

    await channel.ready.timeout(const Duration(seconds: 10));
    channel.sink.add(
      jsonEncode({
        'type': 'session.update',
        'session': {
          'type': 'realtime',
          'instructions': instructions,
          'output_modalities': ['text'],
          'max_output_tokens': 512,
          'reasoning': {'effort': reasoningEffort},
        },
      }),
    );

    await _sessionReady!.future.timeout(const Duration(seconds: 10));
    _sessionReady = null;
    _active = true;
  }

  Future<String> sendTextForResult(
    String text, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    final task = _textResultChain.then((_) {
      return _sendTextForResultNow(text, timeout: timeout);
    });
    _textResultChain = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<String> _sendTextForResultNow(
    String text, {
    required Duration timeout,
  }) async {
    if (_channel == null || !_active) {
      throw Exception('Realtime post-process socket is not active');
    }
    final completer = Completer<String>();
    _pendingTextCompleter = completer;
    _channel!.sink.add(
      jsonEncode({
        'type': 'conversation.item.create',
        'item': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': text},
          ],
        },
      }),
    );
    _channel!.sink.add(jsonEncode({'type': 'response.create'}));
    return completer.future.timeout(timeout);
  }

  Future<void> stop() async {
    _active = false;
    _completeAllWithError(Exception('Realtime post-process socket stopped'));
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _outputs.clear();
    _responseUserItems.clear();
    _lastUserItemId = null;
  }

  void _handleMessage(dynamic message) {
    final text = message is String
        ? message
        : utf8.decode(message as List<int>);
    final event = jsonDecode(text) as Map<String, dynamic>;
    final type = event['type'] as String? ?? '';

    switch (type) {
      case 'session.updated':
      case 'session.created':
        _sessionReady?.complete();
        break;
      case 'conversation.item.added':
        final item = event['item'] as Map<String, dynamic>?;
        if (item?['type'] == 'message' && item?['role'] == 'user') {
          _lastUserItemId = item?['id'] as String?;
        }
        break;
      case 'response.created':
        final responseId = event['response']?['id'] as String?;
        if (responseId == null) return;
        _outputs[responseId] = StringBuffer();
        _responseUserItems[responseId] = _lastUserItemId;
        _lastUserItemId = null;
        final pending = _pendingTextCompleter;
        if (pending != null) {
          _responseCompleters[responseId] = pending;
          _pendingTextCompleter = null;
        }
        break;
      case 'response.output_text.delta':
        final responseId = event['response_id'] as String?;
        if (responseId == null) return;
        _outputs[responseId]?.write(event['delta'] ?? '');
        break;
      case 'response.done':
        final responseId = event['response']?['id'] as String?;
        if (responseId == null) return;
        final output = _outputs.remove(responseId)?.toString() ?? '';
        final completer = _responseCompleters.remove(responseId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(output);
        }
        _deleteCompletedItems(responseId, event);
        break;
      case 'error':
        final message = event['error']?['message']?.toString() ?? 'error';
        _completeAllWithError(Exception(message));
        break;
    }
  }

  void _deleteCompletedItems(String responseId, Map<String, dynamic> event) {
    final userItemId = _responseUserItems.remove(responseId);
    final outputItems = event['response']?['output'] as List?;
    final assistantItemId = outputItems?.isNotEmpty == true
        ? outputItems!.first['id'] as String?
        : null;
    for (final itemId in [userItemId, assistantItemId]) {
      if (itemId == null) continue;
      _channel?.sink.add(
        jsonEncode({'type': 'conversation.item.delete', 'item_id': itemId}),
      );
    }
  }

  void _completeAllWithError(Object error) {
    final pending = _pendingTextCompleter;
    _pendingTextCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
    for (final completer in _responseCompleters.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _responseCompleters.clear();
  }
}
