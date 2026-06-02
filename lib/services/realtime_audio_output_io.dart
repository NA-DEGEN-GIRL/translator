import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RealtimeAudioOutputController {
  static const MethodChannel _channel = MethodChannel(
    'koja_translator/audio_balance',
  );

  RTCVideoRenderer? _renderer;

  Future<void> attach(
    MediaStream stream, {
    required bool muted,
    required double pan,
    required double boostGain,
    required int boostDurationMs,
  }) async {
    await _disposeRenderer();
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    _renderer = renderer;
    await renderer.setVolume(muted ? 0 : 1);
  }

  Future<void> setMuted(bool muted) async {
    await _renderer?.setVolume(muted ? 0 : 1);
  }

  Future<void> setPan(double pan) {
    return Future.value();
  }

  Future<void> setBoost({required double gain, required int durationMs}) {
    return Future.value();
  }

  Future<void> primeOutput() {
    return Future.value();
  }

  Future<void> dispose() async {
    await _disposeRenderer();
  }

  static Future<void> setGlobalPan(double pan) async {
    try {
      await _channel.invokeMethod<void>('setStereoPan', {
        'pan': _normalizePan(pan),
      });
    } on MissingPluginException {
      // Non-Android platforms use their normal audio path.
    } catch (_) {}
  }

  static Future<void> warmUp() {
    return Future.value();
  }

  static Future<bool> playBufferedAudio(
    Uint8List audioBytes, {
    required double pan,
    int leadInMs = 0,
    double initialBoostGain = 1,
    int initialBoostDurationMs = 0,
    double leadInGain = 0,
  }) {
    return Future.value(false);
  }

  static Future<void> stopBufferedAudio() {
    return Future.value();
  }

  Future<void> _disposeRenderer() async {
    final renderer = _renderer;
    _renderer = null;
    if (renderer == null) return;
    try {
      await renderer.setVolume(0);
    } catch (_) {}
    try {
      renderer.srcObject = null;
    } catch (_) {}
    try {
      await renderer.dispose();
    } catch (_) {}
  }

  static double _normalizePan(double pan) => pan.clamp(-1.0, 1.0).toDouble();
}
