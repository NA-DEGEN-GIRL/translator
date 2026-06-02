import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_ws_channel.dart';

class RealtimeTranscriptionWsService {
  static const _cleanupTimeout = Duration(seconds: 2);
  static const _liveCommitInterval = Duration(milliseconds: 1200);
  static const _minApiCommitBytes = 4800; // 100ms of 24kHz mono PCM16.
  static const _minCommitBytes = 12000;

  final String apiKey;
  final String transcriptionModel;
  final String language;
  final String delay;
  final String noiseReduction;
  final String? prompt;
  void Function(String delta)? onDelta;

  late final Uri _uri = Uri.parse(
    'wss://api.openai.com/v1/realtime?intent=transcription',
  );

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Future<void>? _startFuture;
  Completer<void>? _sessionReady;
  Completer<String>? _resultCompleter;
  Timer? _liveCommitTimer;
  final Queue<Uint8List> _queuedChunks = Queue<Uint8List>();
  final List<String> _itemOrder = <String>[];
  final Map<String, StringBuffer> _itemDeltas = <String, StringBuffer>{};
  final Map<String, String> _completedItems = <String, String>{};
  bool _ready = false;
  bool _stopping = false;
  bool _finalizing = false;
  int _queuedBytes = 0;
  int _sentBytes = 0;
  int _bytesSinceCommit = 0;
  int _pendingCommits = 0;
  int _generatedItemSerial = 0;

  RealtimeTranscriptionWsService({
    required this.apiKey,
    required this.language,
    this.transcriptionModel = 'gpt-realtime-whisper',
    this.delay = 'minimal',
    this.noiseReduction = 'near_field',
    this.prompt,
    this.onDelta,
  });

  bool get isActive => _channel != null && !_stopping;
  int get bufferedBytes => _queuedBytes + _sentBytes;

  Map<String, dynamic> buildSessionUpdatePayloadForTesting() {
    return _buildSessionUpdatePayload();
  }

  int minApiCommitBytesForTesting() => _minApiCommitBytes;

  void handleEventForTesting(Map<String, dynamic> event) {
    _handleEvent(event);
  }

  Future<void> start() {
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    _stopping = false;
    final sessionReady = Completer<void>();
    _sessionReady = sessionReady;
    try {
      final channel = connectRealtimeWebSocket(uri: _uri, apiKey: apiKey);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (Object error) {
          _ready = false;
          _completeSessionReadyWithError(error);
          _completeResultWithError(error);
        },
        onDone: () {
          _ready = false;
          if (_stopping) return;
          final error = Exception('Realtime transcription socket closed');
          _completeSessionReadyWithError(error);
          _completeResultWithError(error);
        },
      );

      await channel.ready.timeout(const Duration(seconds: 10));
      _throwIfStopping();
      channel.sink.add(jsonEncode(_buildSessionUpdatePayload()));
      _throwIfStopping();

      await sessionReady.future.timeout(const Duration(seconds: 10));
      _throwIfStopping();
      _ready = true;
      _flushQueuedChunks();
      _startLiveCommitTimer();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void appendPcm16(Uint8List chunk) {
    if (chunk.isEmpty || _stopping || _finalizing) return;
    final stableChunk = Uint8List.fromList(chunk);
    if (_ready && _channel != null) {
      _sendAudioChunk(stableChunk);
      return;
    }
    _queuedChunks.add(stableChunk);
    _queuedBytes += stableChunk.length;
  }

  Future<String> commitAndWait({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_finalizing) {
      return (_resultCompleter?.future ?? Future.value(_fullTranscript()))
          .timeout(timeout);
    }
    await start();
    _flushQueuedChunks();
    _finalizing = true;
    _liveCommitTimer?.cancel();
    _liveCommitTimer = null;
    if (_sentBytes < 1000) return '';

    final channel = _channel;
    if (channel == null || _stopping) {
      throw StateError('Realtime transcription socket is not active');
    }

    _commitBufferedAudio(minBytes: _minApiCommitBytes);
    final resultCompleter = Completer<String>();
    _resultCompleter = resultCompleter;
    _completeResultIfReady();
    return resultCompleter.future.timeout(
      timeout,
      onTimeout: () {
        final transcript = _fullTranscript().trim();
        if (transcript.isNotEmpty) return transcript;
        throw TimeoutException('Realtime transcription timed out', timeout);
      },
    );
  }

  Future<void> stop() async {
    _stopping = true;
    _ready = false;
    _liveCommitTimer?.cancel();
    _liveCommitTimer = null;
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.complete();
    }
    _sessionReady = null;
    _completeResultWithError(
      Exception('Realtime transcription socket stopped'),
    );

    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await Future.wait([
      if (subscription != null) _cleanup(subscription.cancel()),
      if (channel != null) _cleanup(channel.sink.close()),
    ]);
    _queuedChunks.clear();
    _queuedBytes = 0;
  }

  Map<String, dynamic> _buildSessionUpdatePayload() {
    final transcription = <String, dynamic>{
      'model': transcriptionModel,
      'language': language,
      'delay': delay,
    };
    final trimmedPrompt = prompt?.trim();
    if (trimmedPrompt != null && trimmedPrompt.isNotEmpty) {
      transcription['prompt'] = trimmedPrompt;
    }
    final input = <String, dynamic>{
      'format': {'type': 'audio/pcm', 'rate': 24000},
      'transcription': transcription,
      'turn_detection': null,
    };
    if (noiseReduction != 'none') {
      input['noise_reduction'] = {'type': noiseReduction};
    }
    return {
      'type': 'session.update',
      'session': {
        'type': 'transcription',
        'audio': {'input': input},
      },
    };
  }

  void _handleMessage(dynamic message) {
    final text = message is String
        ? message
        : utf8.decode(message as List<int>);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;
    _handleEvent(decoded);
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    switch (type) {
      case 'transcription_session.created':
        break;
      case 'transcription_session.updated':
      case 'session.updated':
        _completeSessionReady();
        break;
      case 'conversation.item.input_audio_transcription.delta':
        final itemId = _eventItemId(event);
        final delta = event['delta']?.toString() ?? '';
        if (delta.isEmpty) return;
        final buffer = _deltaBufferFor(itemId);
        final isFirstDeltaForItem = buffer.isEmpty;
        if (isFirstDeltaForItem && _hasPriorTranscript(itemId)) {
          final joiner = _transcriptJoiner();
          if (joiner.isNotEmpty) onDelta?.call(joiner);
        }
        buffer.write(delta);
        onDelta?.call(delta);
        break;
      case 'conversation.item.input_audio_transcription.completed':
        final itemId = _eventItemId(event);
        final transcript =
            event['transcript']?.toString().trim() ??
            _itemDeltas[itemId]?.toString().trim() ??
            '';
        final previous = _itemDeltas[itemId]?.toString().trim() ?? '';
        _ensureItemOrder(itemId);
        if (transcript.isNotEmpty) {
          _completedItems[itemId] = transcript;
          if (previous.isEmpty) {
            final joiner = _hasPriorTranscript(itemId)
                ? _transcriptJoiner()
                : '';
            onDelta?.call('$joiner$transcript');
          } else if (transcript.startsWith(previous) &&
              transcript.length > previous.length) {
            onDelta?.call(transcript.substring(previous.length));
          }
        }
        if (_pendingCommits > 0) _pendingCommits--;
        _completeResultIfReady();
        break;
      case 'error':
        final error = event['error'];
        final message = error is Map
            ? error['message']?.toString()
            : event['message']?.toString();
        final exception = Exception(
          'Realtime transcription failed: ${message ?? event}',
        );
        _completeSessionReadyWithError(exception);
        _completeResultWithError(exception);
        break;
    }
  }

  void _flushQueuedChunks() {
    if (!_ready || _channel == null) return;
    while (_queuedChunks.isNotEmpty) {
      final chunk = _queuedChunks.removeFirst();
      _queuedBytes -= chunk.length;
      _sendAudioChunk(chunk);
    }
    _queuedBytes = 0;
  }

  void _sendAudioChunk(Uint8List chunk) {
    final channel = _channel;
    if (channel == null || _stopping || _finalizing) return;
    _sentBytes += chunk.length;
    _bytesSinceCommit += chunk.length;
    channel.sink.add(
      jsonEncode({
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(chunk),
      }),
    );
  }

  void _startLiveCommitTimer() {
    _liveCommitTimer?.cancel();
    _liveCommitTimer = Timer.periodic(_liveCommitInterval, (_) {
      if (_stopping || _finalizing) return;
      _commitBufferedAudio(minBytes: _minCommitBytes);
    });
  }

  bool _commitBufferedAudio({required int minBytes}) {
    final channel = _channel;
    if (channel == null || _stopping || _bytesSinceCommit < minBytes) {
      return false;
    }
    _pendingCommits++;
    _bytesSinceCommit = 0;
    channel.sink.add('{"type":"input_audio_buffer.commit"}');
    return true;
  }

  String _eventItemId(Map<String, dynamic> event) {
    final itemId = event['item_id']?.toString();
    if (itemId != null && itemId.isNotEmpty) return itemId;
    return 'generated_${++_generatedItemSerial}';
  }

  void _ensureItemOrder(String itemId) {
    if (_itemOrder.contains(itemId)) return;
    _itemOrder.add(itemId);
  }

  StringBuffer _deltaBufferFor(String itemId) {
    _ensureItemOrder(itemId);
    return _itemDeltas.putIfAbsent(itemId, StringBuffer.new);
  }

  bool _hasPriorTranscript(String itemId) {
    for (final id in _itemOrder) {
      if (id == itemId) return false;
      final text = _completedItems[id] ?? _itemDeltas[id]?.toString() ?? '';
      if (text.trim().isNotEmpty) return true;
    }
    return false;
  }

  String _transcriptJoiner() {
    final lang = language.toLowerCase();
    if (lang == 'ja' || lang == 'zh' || lang == 'zh-cn' || lang == 'zh-tw') {
      return '';
    }
    return ' ';
  }

  String _fullTranscript() {
    final parts = <String>[];
    for (final itemId in _itemOrder) {
      final text =
          _completedItems[itemId] ?? _itemDeltas[itemId]?.toString() ?? '';
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) parts.add(trimmed);
    }
    return parts.join(_transcriptJoiner()).trim();
  }

  void _completeResultIfReady() {
    if (!_finalizing || _pendingCommits > 0) return;
    _completeResult(_fullTranscript());
  }

  Future<void> _cleanup(Future<void> future) {
    return future.timeout(_cleanupTimeout, onTimeout: () {}).catchError((_) {});
  }

  void _throwIfStopping() {
    if (_stopping) throw StateError('Realtime transcription socket stopped');
  }

  void _completeSessionReady() {
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.complete();
    }
  }

  void _completeSessionReadyWithError(Object error) {
    final sessionReady = _sessionReady;
    if (sessionReady != null && !sessionReady.isCompleted) {
      sessionReady.completeError(error);
    }
  }

  void _completeResult(String text) {
    final resultCompleter = _resultCompleter;
    if (resultCompleter != null && !resultCompleter.isCompleted) {
      resultCompleter.complete(text);
    }
  }

  void _completeResultWithError(Object error) {
    final resultCompleter = _resultCompleter;
    if (resultCompleter != null && !resultCompleter.isCompleted) {
      resultCompleter.completeError(error);
    }
  }
}
