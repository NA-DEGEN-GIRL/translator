import 'dart:typed_data';

Uint8List pcm16ToWav(
  Iterable<Uint8List> chunks, {
  required int sampleRate,
  required int numChannels,
}) {
  const bytesPerSample = 2;
  final dataLength = chunks.fold<int>(
    0,
    (sum, chunk) => sum + chunk.lengthInBytes,
  );
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, numChannels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * numChannels * bytesPerSample, Endian.little);
  data.setUint16(32, numChannels * bytesPerSample, Endian.little);
  data.setUint16(34, bytesPerSample * 8, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);

  var offset = 44;
  for (final chunk in chunks) {
    bytes.setRange(offset, offset + chunk.lengthInBytes, chunk);
    offset += chunk.lengthInBytes;
  }
  return bytes;
}

Uint8List panWavPcm16ToStereo(Uint8List wavBytes, double pan) {
  final normalizedPan = pan.clamp(-1.0, 1.0).toDouble();
  if (normalizedPan.abs() < 0.01 || wavBytes.lengthInBytes < 44) {
    return wavBytes;
  }

  final bytes = wavBytes;
  final data = ByteData.sublistView(bytes);

  String ascii(int offset, int length) {
    if (offset < 0 || offset + length > bytes.lengthInBytes) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }

  if (ascii(0, 4) != 'RIFF' || ascii(8, 4) != 'WAVE') return wavBytes;

  int? audioFormat;
  int? inputChannels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  var offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final id = ascii(offset, 4);
    final size = data.getUint32(offset + 4, Endian.little);
    final bodyOffset = offset + 8;
    if (bodyOffset + size > bytes.lengthInBytes) break;

    if (id == 'fmt ' && size >= 16) {
      audioFormat = data.getUint16(bodyOffset, Endian.little);
      inputChannels = data.getUint16(bodyOffset + 2, Endian.little);
      sampleRate = data.getUint32(bodyOffset + 4, Endian.little);
      bitsPerSample = data.getUint16(bodyOffset + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = bodyOffset;
      dataLength = size;
    }

    offset = bodyOffset + size + (size.isOdd ? 1 : 0);
  }

  if (audioFormat != 1 ||
      sampleRate == null ||
      bitsPerSample != 16 ||
      dataOffset == null ||
      dataLength == null ||
      inputChannels == null ||
      inputChannels < 1 ||
      inputChannels > 2) {
    return wavBytes;
  }

  final frameBytes = inputChannels * 2;
  if (dataLength % frameBytes != 0) return wavBytes;

  final frameCount = dataLength ~/ frameBytes;
  final leftGain = normalizedPan < 0 ? 1.0 : 1.0 - normalizedPan;
  final rightGain = normalizedPan > 0 ? 1.0 : 1.0 + normalizedPan;
  final pcm = Uint8List(frameCount * 4);
  final pcmData = ByteData.sublistView(pcm);

  int clampSample(num value) {
    final rounded = value.round();
    if (rounded < -32768) return -32768;
    if (rounded > 32767) return 32767;
    return rounded;
  }

  for (var frame = 0; frame < frameCount; frame++) {
    final inOffset = dataOffset + frame * frameBytes;
    final sample = inputChannels == 1
        ? data.getInt16(inOffset, Endian.little)
        : ((data.getInt16(inOffset, Endian.little) +
                      data.getInt16(inOffset + 2, Endian.little)) /
                  2)
              .round();
    final outOffset = frame * 4;
    pcmData.setInt16(outOffset, clampSample(sample * leftGain), Endian.little);
    pcmData.setInt16(
      outOffset + 2,
      clampSample(sample * rightGain),
      Endian.little,
    );
  }

  return pcm16ToWav([pcm], sampleRate: sampleRate, numChannels: 2);
}
