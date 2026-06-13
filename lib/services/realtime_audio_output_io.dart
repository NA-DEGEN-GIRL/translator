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

  // Android 네이티브 AudioTrack(MODE_STREAM) gapless 스트리밍. 첫 호출에서
  // 스트림을 시작(lazy)하고 이후 PCM을 써넣는다. 미지원 시 false → 호출자 폴백.
  static int _pcmStreamRate = 0;
  static double _pcmStreamPan = 0;
  static bool _pcmStreamVoiceComm = false;
  static bool _pcmStreamUnavailable = false;

  static Future<bool> enqueuePcm(
    Uint8List pcm16, {
    required int sampleRate,
    double pan = 0,
    bool voiceComm = false,
  }) async {
    if (_pcmStreamUnavailable) return false;
    try {
      // rate 또는 출력 usage(voiceComm)가 바뀌면 트랙을 새 설정으로 재생성.
      if (_pcmStreamRate != sampleRate ||
          _pcmStreamVoiceComm != voiceComm) {
        await _channel.invokeMethod<void>('pcmStart', {
          'sampleRate': sampleRate,
          'voiceComm': voiceComm,
        });
        _pcmStreamRate = sampleRate;
        _pcmStreamVoiceComm = voiceComm;
        _pcmStreamPan = pan;
        await _channel.invokeMethod<void>('pcmSetPan', {'pan': pan});
      } else if ((pan - _pcmStreamPan).abs() >= 0.01) {
        _pcmStreamPan = pan;
        await _channel.invokeMethod<void>('pcmSetPan', {'pan': pan});
      }
      await _channel.invokeMethod<void>('pcmWrite', {'bytes': pcm16});
      return true;
    } on MissingPluginException {
      _pcmStreamUnavailable = true;
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopStream() async {
    if (_pcmStreamRate == 0) return;
    _pcmStreamRate = 0;
    try {
      await _channel.invokeMethod<void>('pcmStop');
    } catch (_) {}
  }

  // 헤드셋(유선/BT/USB) 출력 연결 여부. 스피커 출력 판정용(에코 가드).
  static Future<bool> isHeadsetConnected() async {
    try {
      final r = await _channel.invokeMethod<bool>('isHeadsetConnected');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  // 오디오 모드 전환(0=NORMAL 스테레오 / 3=IN_COMMUNICATION 이어폰 마이크).
  static Future<void> setAudioMode(int mode) async {
    try {
      await _channel.invokeMethod<void>('setAudioMode', {'mode': mode});
    } catch (_) {}
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
