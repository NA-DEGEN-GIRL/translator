import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_ws_channel.dart';

class RealtimePostProcessWsService {
  static const _cleanupTimeout = Duration(seconds: 2);
  static const _maxIgnoredResponseIds = 24;
  static const String _responseCreatePayload = '{"type":"response.create"}';

  final String apiKey;
  final String instructions;
  final String model;
  final String reasoningEffort;
  late final Uri _uri = Uri.parse(
    'wss://api.openai.com/v1/realtime?model=$model',
  );
  late final String _sessionUpdatePayload = jsonEncode({
    'type': 'session.update',
    'session': {
      'type': 'realtime',
      'instructions': instructions,
      'output_modalities': ['text'],
      'max_output_tokens': 512,
      'reasoning': {'effort': reasoningEffort},
    },
  });

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _active = false;
  bool _stopping = false;
  Completer<void>? _sessionReady;
  Completer<String>? _pendingTextCompleter;
  Completer<String>? _activeTextCompleter;
  Future<void> _textResultChain = Future.value();
  String? _lastUserItemId;
  String? _activeResponseId;
  String? _activeUserItemId;
  StringBuffer? _activeOutput;
  final Set<String> _ignoredResponseIds = {};

  RealtimePostProcessWsService({
    required this.apiKey,
    required this.instructions,
    this.model = 'gpt-realtime-2',
    this.reasoningEffort = 'minimal',
  });

  bool get isActive => _active;

  Future<void> start() async {
    if (_active) return;
    if (_channel != null || _subscription != null) {
      await stop();
    }
    _stopping = false;
    try {
      final channel = connectRealtimeWebSocket(uri: _uri, apiKey: apiKey);
      final sessionReady = Completer<void>();
      _channel = channel;
      _sessionReady = sessionReady;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (Object error) {
          _active = false;
          _completeSessionReadyWithError(error);
          _completeAllWithError(error);
        },
        onDone: () {
          _active = false;
          final error = Exception('Realtime post-process socket closed');
          _completeSessionReadyWithError(error);
          _completeAllWithError(error);
        },
      );

      await channel.ready.timeout(const Duration(seconds: 10));
      _throwIfStopping();
      channel.sink.add(_sessionUpdatePayload);
      _throwIfStopping();

      await sessionReady.future.timeout(const Duration(seconds: 10));
      _throwIfStopping();
      if (_sessionReady == sessionReady) _sessionReady = null;
      _active = true;
    } catch (_) {
      await stop();
      rethrow;
    }
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
    _channel!.sink.add(_conversationInputTextItemPayload(text));
    _channel!.sink.add(_responseCreatePayload);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _removePendingCompleter(completer);
        throw TimeoutException('Realtime post-process timed out', timeout);
      },
    );
  }

  Future<void> stop() async {
    _stopping = true;
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.complete();
    }
    _sessionReady = null;
    _active = false;
    _completeAllWithError(Exception('Realtime post-process socket stopped'));
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await Future.wait([
      if (subscription != null) _cleanup(subscription.cancel()),
      if (channel != null) _cleanup(channel.sink.close()),
    ]);
    _clearActiveResponse();
    _ignoredResponseIds.clear();
    _lastUserItemId = null;
  }

  Future<void> _cleanup(Future<void> future) {
    return future.timeout(_cleanupTimeout, onTimeout: () {}).catchError((_) {});
  }

  void _throwIfStopping() {
    if (_stopping) {
      throw StateError('Realtime post-process socket stopped');
    }
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
        final pending = _pendingTextCompleter;
        final userItemId = _lastUserItemId;
        _lastUserItemId = null;
        if (pending == null) {
          _ignoreResponseId(responseId);
          _deleteItemId(userItemId);
          return;
        }
        _pendingTextCompleter = null;
        _activeTextCompleter = pending;
        _activeResponseId = responseId;
        _activeUserItemId = userItemId;
        _activeOutput = StringBuffer();
        break;
      case 'response.output_text.delta':
        final responseId = event['response_id'] as String?;
        if (responseId == null) return;
        if (responseId == _activeResponseId) {
          _activeOutput?.write(event['delta'] ?? '');
        }
        break;
      case 'response.done':
        final responseId = event['response']?['id'] as String?;
        if (responseId == null) return;
        if (responseId == _activeResponseId) {
          final output = _activeOutput?.toString() ?? '';
          final completer = _activeTextCompleter;
          final userItemId = _activeUserItemId;
          _clearActiveResponse();
          if (completer != null && !completer.isCompleted) {
            completer.complete(output);
          }
          _deleteCompletedItems(event, userItemId: userItemId);
        } else if (_ignoredResponseIds.remove(responseId)) {
          _deleteCompletedItems(event, userItemId: null);
        }
        break;
      case 'error':
        final message = event['error']?['message']?.toString() ?? 'error';
        final error = Exception(message);
        _completeSessionReadyWithError(error);
        _completeAllWithError(error);
        break;
    }
  }

  void _removePendingCompleter(Completer<String> completer) {
    if (_pendingTextCompleter == completer) {
      _pendingTextCompleter = null;
      final userItemId = _lastUserItemId;
      _lastUserItemId = null;
      _deleteItemId(userItemId);
      return;
    }

    if (_activeTextCompleter != completer) return;
    final responseId = _activeResponseId;
    final userItemId = _activeUserItemId;
    _clearActiveResponse();
    if (responseId != null) _ignoreResponseId(responseId);
    _deleteItemId(userItemId);
  }

  void _ignoreResponseId(String responseId) {
    _ignoredResponseIds.add(responseId);
    while (_ignoredResponseIds.length > _maxIgnoredResponseIds) {
      _ignoredResponseIds.remove(_ignoredResponseIds.first);
    }
  }

  void _deleteCompletedItems(
    Map<String, dynamic> event, {
    required String? userItemId,
  }) {
    final outputItems = event['response']?['output'] as List?;
    final assistantItemId = outputItems?.isNotEmpty == true
        ? outputItems!.first['id'] as String?
        : null;
    _deleteItemId(userItemId);
    _deleteItemId(assistantItemId);
  }

  void _deleteItemId(String? itemId) {
    if (itemId == null || _channel == null || !_active) return;
    _channel?.sink.add(_conversationItemDeletePayload(itemId));
  }

  static String _conversationItemDeletePayload(String itemId) {
    return '{"type":"conversation.item.delete","item_id":${jsonEncode(itemId)}}';
  }

  static String _conversationInputTextItemPayload(String text) {
    return '{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":${jsonEncode(text)}}]}}';
  }

  void _completeAllWithError(Object error) {
    final pending = _pendingTextCompleter;
    _pendingTextCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
    final active = _activeTextCompleter;
    if (active != null && !active.isCompleted) {
      active.completeError(error);
    }
    _clearActiveResponse();
    _ignoredResponseIds.clear();
    _lastUserItemId = null;
  }

  void _clearActiveResponse() {
    _activeTextCompleter = null;
    _activeResponseId = null;
    _activeUserItemId = null;
    _activeOutput = null;
  }

  void _completeSessionReadyWithError(Object error) {
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.completeError(error);
    }
    _sessionReady = null;
  }
}
