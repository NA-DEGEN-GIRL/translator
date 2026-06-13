import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koja_translator/services/wav_audio.dart';

void main() {
  test('pcm16ToWav wraps PCM data with a valid WAV header', () {
    final wav = pcm16ToWav(
      [
        Uint8List.fromList([1, 0, 255, 255]),
        Uint8List.fromList([2, 0]),
      ],
      sampleRate: 24000,
      numChannels: 1,
    );
    final data = ByteData.sublistView(wav);

    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(data.getUint32(4, Endian.little), 42);
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(ascii.decode(wav.sublist(12, 16)), 'fmt ');
    expect(data.getUint16(20, Endian.little), 1);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint32(28, Endian.little), 48000);
    expect(data.getUint16(32, Endian.little), 2);
    expect(data.getUint16(34, Endian.little), 16);
    expect(ascii.decode(wav.sublist(36, 40)), 'data');
    expect(data.getUint32(40, Endian.little), 6);
    expect(wav.sublist(44), [1, 0, 255, 255, 2, 0]);
  });

  test('panWavPcm16ToStereo sends mono PCM to one channel', () {
    final pcm = Uint8List(4);
    final pcmData = ByteData.sublistView(pcm);
    pcmData.setInt16(0, 1000, Endian.little);
    pcmData.setInt16(2, -1000, Endian.little);

    final wav = pcm16ToWav([pcm], sampleRate: 24000, numChannels: 1);
    final panned = panWavPcm16ToStereo(wav, -1);
    final data = ByteData.sublistView(panned);

    expect(data.getUint16(22, Endian.little), 2);
    expect(data.getUint32(40, Endian.little), 8);
    expect(data.getInt16(44, Endian.little), 1000);
    expect(data.getInt16(46, Endian.little), 0);
    expect(data.getInt16(48, Endian.little), -1000);
    expect(data.getInt16(50, Endian.little), 0);
  });

  test('panWavPcm16ToStereo handles streaming data size (0xFFFFFFFF)', () {
    // OpenAI TTS 등 스트리밍 WAV는 data 크기를 0xFFFFFFFF로 둔다 → 실제 남은
    // 바이트로 보정해 패닝돼야 한다(이전엔 break돼 원본 mono 그대로였음).
    final pcm = Uint8List(4);
    final pcmData = ByteData.sublistView(pcm);
    pcmData.setInt16(0, 1000, Endian.little);
    pcmData.setInt16(2, -1000, Endian.little);
    final wav = pcm16ToWav([pcm], sampleRate: 24000, numChannels: 1);
    // data 청크 크기(오프셋 40)를 0xFFFFFFFF로 덮어쓴다(스트리밍 WAV 모사).
    ByteData.sublistView(wav).setUint32(40, 0xFFFFFFFF, Endian.little);

    final panned = panWavPcm16ToStereo(wav, 1); // 오른쪽으로
    final data = ByteData.sublistView(panned);

    expect(data.getUint16(22, Endian.little), 2, reason: 'stereo로 변환돼야 함');
    expect(data.getUint32(40, Endian.little), 8);
    // pan=1(오른쪽): left=0, right=sample
    expect(data.getInt16(44, Endian.little), 0);
    expect(data.getInt16(46, Endian.little), 1000);
    expect(data.getInt16(48, Endian.little), 0);
    expect(data.getInt16(50, Endian.little), -1000);
  });
}
