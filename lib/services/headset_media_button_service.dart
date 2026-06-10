import 'package:flutter/services.dart';

class HeadsetMediaButtonEvent {
  const HeadsetMediaButtonEvent({
    required this.action,
    required this.keyCode,
    required this.timestampMs,
  });

  final String action;
  final int keyCode;
  final int timestampMs;

  static HeadsetMediaButtonEvent? fromMap(Object? value) {
    if (value is! Map) return null;
    final action = value['action'];
    final keyCode = value['keyCode'];
    final timestampMs = value['timestampMs'];
    if (action is! String || keyCode is! int || timestampMs is! int) {
      return null;
    }
    return HeadsetMediaButtonEvent(
      action: action,
      keyCode: keyCode,
      timestampMs: timestampMs,
    );
  }
}

class HeadsetMediaButtonService {
  static const MethodChannel _channel = MethodChannel(
    'koja_translator/headset_media_buttons',
  );

  ValueChanged<HeadsetMediaButtonEvent>? _onEvent;

  HeadsetMediaButtonService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onMediaButton') return;
      final event = HeadsetMediaButtonEvent.fromMap(call.arguments);
      if (event == null) return;
      _onEvent?.call(event);
    });
  }

  void setHandler(ValueChanged<HeadsetMediaButtonEvent>? onEvent) {
    _onEvent = onEvent;
  }

  Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('startListening') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopListening');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> dispose() async {
    _onEvent = null;
    await stop();
  }
}
