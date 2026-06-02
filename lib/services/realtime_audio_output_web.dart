import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_webrtc/dart_webrtc.dart' as dart_webrtc;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

class RealtimeAudioOutputController {
  static web.AudioContext? _sharedContext;
  static web.ConstantSourceNode? _keepAliveSource;
  static web.OscillatorNode? _keepAliveOscillator;
  static web.AudioBufferSourceNode? _keepAliveNoiseSource;
  static web.GainNode? _keepAliveGain;
  static final Set<web.AudioBufferSourceNode> _bufferedSources = {};
  static const double _bufferedStartDelaySeconds = 0.08;
  static const double _streamDelaySeconds = 0.22;
  static const double _comfortNoiseGain = 0.0012;

  web.HTMLAudioElement? _audioElement;
  web.MediaStream? _webStream;
  web.MediaStreamAudioSourceNode? _source;
  web.DelayNode? _delay;
  web.GainNode? _gain;
  web.StereoPannerNode? _panner;
  bool _muted = true;
  double _boostGain = 1.65;
  int _boostDurationMs = 1100;

  Future<void> attach(
    MediaStream stream, {
    required bool muted,
    required double pan,
    required double boostGain,
    required int boostDurationMs,
  }) async {
    await dispose();
    final webStream = (stream as dart_webrtc.MediaStreamWeb).jsStream;
    _webStream = webStream;
    _muted = muted;
    _boostGain = _normalizeBoostGain(boostGain);
    _boostDurationMs = _normalizeBoostDurationMs(boostDurationMs);

    final audio = web.HTMLAudioElement()
      ..autoplay = true
      ..controls = false
      ..muted = muted
      ..volume = muted ? 0 : 1
      ..srcObject = webStream;
    audio.setAttribute('playsinline', 'true');
    audio.style.display = 'none';
    web.document.body?.appendChild(audio);
    _audioElement = audio;

    await _configureOutput(pan);
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _applyMuteState();
    if (!muted) {
      await warmUp();
      await _play(_audioElement);
    }
  }

  Future<void> setPan(double pan) async {
    await _configureOutput(pan);
  }

  Future<void> setBoost({required double gain, required int durationMs}) async {
    _boostGain = _normalizeBoostGain(gain);
    _boostDurationMs = _normalizeBoostDurationMs(durationMs);
  }

  Future<void> primeOutput() async {
    await warmUp();
    await _play(_audioElement);
    if (_muted) return;
    final context = _sharedContext;
    final gain = _gain;
    if (context == null || gain == null) return;
    final now = context.currentTime;
    try {
      gain.gain.cancelScheduledValues(now);
      final boostGain = _boostGain;
      final durationSeconds = _boostDurationMs / 1000;
      if (boostGain <= 1 || durationSeconds <= 0) {
        gain.gain.setValueAtTime(1, now);
        return;
      }
      final holdSeconds = durationSeconds < 0.65 ? durationSeconds * 0.6 : 0.65;
      gain.gain.setValueAtTime(boostGain, now);
      gain.gain.setValueAtTime(boostGain, now + holdSeconds);
      gain.gain.linearRampToValueAtTime(1, now + durationSeconds);
    } catch (_) {
      gain.gain.value = 1;
    }
  }

  Future<void> dispose() async {
    _disposeAudioGraph();
    final audio = _audioElement;
    _audioElement = null;
    _webStream = null;
    if (audio != null) {
      try {
        audio.pause();
      } catch (_) {}
      try {
        audio.srcObject = null;
      } catch (_) {}
      try {
        audio.remove();
      } catch (_) {}
    }
  }

  static Future<void> setGlobalPan(double pan) {
    return Future.value();
  }

  static Future<void> warmUp() async {
    final context = _sharedContext ??= web.AudioContext();
    _ensureKeepAlive(context);
    await _resume(context);
  }

  static Future<bool> playBufferedAudio(
    Uint8List audioBytes, {
    required double pan,
    int leadInMs = 0,
    double initialBoostGain = 1,
    int initialBoostDurationMs = 0,
    double leadInGain = 0,
  }) async {
    web.AudioBufferSourceNode? source;
    web.GainNode? gain;
    web.StereoPannerNode? panner;
    try {
      final context = _sharedContext ??= web.AudioContext();
      _ensureKeepAlive(context);
      await _resume(context);

      final decodedBuffer = await context
          .decodeAudioData(Uint8List.fromList(audioBytes).buffer.toJS)
          .toDart;
      final buffer = _addLeadIn(
        context,
        decodedBuffer,
        leadInMs,
        leadInGain: leadInGain <= 0 ? _comfortNoiseGain : leadInGain,
      );
      source = context.createBufferSource();
      gain = context.createGain();
      panner = context.createStereoPanner();

      source.buffer = buffer;
      gain.gain.value = 1;
      panner.pan.value = _normalizePan(pan);
      _scheduleInitialBoost(
        context: context,
        gain: gain,
        startAt: context.currentTime + _bufferedStartDelaySeconds,
        leadInMs: leadInMs,
        boostGain: initialBoostGain,
        boostDurationMs: initialBoostDurationMs,
      );

      source.connect(gain);
      gain.connect(panner);
      panner.connect(context.destination);

      _bufferedSources.add(source);
      source.start(context.currentTime + _bufferedStartDelaySeconds);
      final duration = Duration(
        milliseconds:
            (_bufferedStartDelaySeconds * 1000).ceil() +
            (buffer.duration * 1000).ceil() +
            80,
      );
      await Future<void>.delayed(duration);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (source != null) _bufferedSources.remove(source);
      try {
        source?.stop();
      } catch (_) {}
      for (final node in [source, gain, panner]) {
        try {
          node?.disconnect();
        } catch (_) {}
      }
    }
  }

  static web.AudioBuffer _addLeadIn(
    web.AudioContext context,
    web.AudioBuffer buffer,
    int leadInMs, {
    required double leadInGain,
  }) {
    if (leadInMs <= 0) return buffer;
    final leadFrames = (buffer.sampleRate * leadInMs / 1000).round();
    if (leadFrames <= 0) return buffer;
    final gain = leadInGain.clamp(0.0002, 0.004).toDouble();

    final result = web.AudioBuffer(
      web.AudioBufferOptions(
        numberOfChannels: buffer.numberOfChannels,
        length: buffer.length + leadFrames,
        sampleRate: buffer.sampleRate,
      ),
    );
    for (var channel = 0; channel < buffer.numberOfChannels; channel++) {
      final source = buffer.getChannelData(channel).toDart;
      final target = result.getChannelData(channel).toDart;
      var seed = 0x4d2b79f5 + channel;
      for (var i = 0; i < leadFrames; i++) {
        seed = (1664525 * seed + 1013904223) & 0xffffffff;
        target[i] = ((((seed >> 24) & 0xff) - 128) / 128) * gain;
      }
      target.setAll(leadFrames, source);
    }
    return result;
  }

  static void _scheduleInitialBoost({
    required web.AudioContext context,
    required web.GainNode gain,
    required double startAt,
    required int leadInMs,
    required double boostGain,
    required int boostDurationMs,
  }) {
    final normalizedBoost = boostGain.clamp(1.0, 2.2).toDouble();
    final normalizedMs = boostDurationMs.clamp(0, 1800).toInt();
    if (normalizedBoost <= 1 || normalizedMs <= 0) {
      gain.gain.value = 1;
      return;
    }
    final now = context.currentTime;
    final speechStart = startAt + leadInMs / 1000;
    final rampStart = leadInMs > 100
        ? speechStart - 0.09
        : (speechStart - 0.03).clamp(now, speechStart).toDouble();
    final end = speechStart + normalizedMs / 1000;
    try {
      gain.gain.cancelScheduledValues(now);
      gain.gain.setValueAtTime(1, now);
      gain.gain.setValueAtTime(1, rampStart);
      gain.gain.linearRampToValueAtTime(normalizedBoost, speechStart);
      gain.gain.setValueAtTime(normalizedBoost, speechStart + 0.12);
      gain.gain.linearRampToValueAtTime(1, end);
    } catch (_) {
      gain.gain.value = normalizedBoost;
    }
  }

  static Future<void> stopBufferedAudio() async {
    for (final source in _bufferedSources.toList(growable: false)) {
      try {
        source.stop();
      } catch (_) {}
      try {
        source.disconnect();
      } catch (_) {}
    }
    _bufferedSources.clear();
  }

  Future<void> _configureOutput(double pan) async {
    final normalizedPan = _normalizePan(pan);
    final webStream = _webStream;
    if (webStream == null) return;
    final context = _sharedContext ??= web.AudioContext();
    final source = context.createMediaStreamSource(webStream);
    final delay = context.createDelay(1);
    final gain = context.createGain();
    final panner = context.createStereoPanner();

    delay.delayTime.value = _streamDelaySeconds;
    gain.gain.value = _muted ? 0 : 1;
    panner.pan.value = normalizedPan;

    _disposeAudioGraph();
    source.connect(delay);
    delay.connect(gain);
    gain.connect(panner);
    panner.connect(context.destination);

    _source = source;
    _delay = delay;
    _gain = gain;
    _panner = panner;
    _applyMuteState();
    if (!_muted) {
      _ensureKeepAlive(context);
      await _resume(context);
      await _play(_audioElement);
    }
  }

  void _disposeAudioGraph() {
    for (final node in [_source, _delay, _gain, _panner]) {
      try {
        node?.disconnect();
      } catch (_) {}
    }
    _source = null;
    _delay = null;
    _gain = null;
    _panner = null;
  }

  void _applyMuteState() {
    final audio = _audioElement;
    if (audio != null) {
      audio.muted = true;
      audio.volume = 0;
    }
    _gain?.gain.value = _muted ? 0 : 1;
  }

  static Future<void> _play(web.HTMLAudioElement? audio) async {
    if (audio == null) return;
    try {
      await audio.play().toDart;
    } catch (_) {}
  }

  static void _ensureKeepAlive(web.AudioContext context) {
    if (_keepAliveGain != null &&
        (_keepAliveNoiseSource != null ||
            _keepAliveSource != null ||
            _keepAliveOscillator != null)) {
      return;
    }
    try {
      final gain = context.createGain();
      gain.gain.value = 1;
      try {
        final sampleRate = context.sampleRate;
        final frameCount = (sampleRate * 0.5).round();
        final buffer = web.AudioBuffer(
          web.AudioBufferOptions(
            numberOfChannels: 1,
            length: frameCount,
            sampleRate: sampleRate,
          ),
        );
        final channel = buffer.getChannelData(0).toDart;
        var seed = 0x7f4a7c15;
        for (var i = 0; i < frameCount; i++) {
          seed = (1664525 * seed + 1013904223) & 0xffffffff;
          channel[i] =
              ((((seed >> 24) & 0xff) - 128) / 128) * _comfortNoiseGain;
        }
        final source = context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        source.connect(gain);
        source.start();
        _keepAliveNoiseSource = source;
      } catch (_) {
        final source = context.createConstantSource();
        source.offset.value = _comfortNoiseGain;
        source.connect(gain);
        source.start();
        _keepAliveSource = source;
      }
      gain.connect(context.destination);
      _keepAliveGain = gain;
    } catch (_) {}
  }

  static Future<void> _resume(web.AudioContext context) async {
    try {
      await context.resume().toDart;
    } catch (_) {}
  }

  static double _normalizePan(double pan) => pan.clamp(-1.0, 1.0).toDouble();

  static double _normalizeBoostGain(double gain) {
    return gain.clamp(1.0, 2.5).toDouble();
  }

  static int _normalizeBoostDurationMs(int durationMs) {
    return durationMs.clamp(0, 2500).toInt();
  }
}
