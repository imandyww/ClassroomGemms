import 'dart:io';
import 'dart:typed_data';

const int _waveFormatPcm = 0x0001;
const int _waveFormatExtensible = 0xFFFE;

final Uint8List _pcmSubformatGuid = Uint8List.fromList(const <int>[
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x10,
  0x00,
  0x80,
  0x00,
  0x00,
  0xAA,
  0x00,
  0x38,
  0x9B,
  0x71,
]);

/// Rewrites WAV files into the simplest PCM RIFF layout that the native
/// Cactus/Gemma parser accepts. Apple's recorder often emits WAVE_FORMAT_
/// EXTENSIBLE plus padding chunks, which macOS tools can read but Cactus
/// currently rejects.
Future<String> rewriteWavAsCanonicalPcm(String path) async {
  final file = File(path);
  final input = await file.readAsBytes();
  final canonical = canonicalizeWavAsPcm(input);
  await file.writeAsBytes(canonical, flush: true);
  return path;
}

Uint8List canonicalizeWavAsPcm(Uint8List bytes) {
  final parsed = _parseWave(bytes);
  return _buildCanonicalWave(
    sampleRate: parsed.sampleRate,
    channelCount: parsed.channelCount,
    bitsPerSample: parsed.bitsPerSample,
    pcmData: parsed.pcmData,
  );
}

_ParsedWave _parseWave(Uint8List bytes) {
  if (bytes.lengthInBytes < 12) {
    throw const FormatException('WAV file too short');
  }

  final byteData = ByteData.sublistView(bytes);
  if (_readFourCc(bytes, 0) != 'RIFF' || _readFourCc(bytes, 8) != 'WAVE') {
    throw const FormatException('Expected RIFF/WAVE file');
  }

  int? audioFormat;
  int? channelCount;
  int? sampleRate;
  int? bitsPerSample;
  Uint8List? pcmData;

  var offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final chunkId = _readFourCc(bytes, offset);
    final chunkSize = byteData.getUint32(offset + 4, Endian.little);
    final chunkDataStart = offset + 8;
    final chunkDataEnd = chunkDataStart + chunkSize;
    if (chunkDataEnd > bytes.lengthInBytes) {
      throw FormatException('Truncated $chunkId chunk');
    }

    switch (chunkId) {
      case 'fmt ':
        if (chunkSize < 16) {
          throw const FormatException('fmt chunk too short');
        }
        audioFormat = byteData.getUint16(chunkDataStart, Endian.little);
        channelCount = byteData.getUint16(chunkDataStart + 2, Endian.little);
        sampleRate = byteData.getUint32(chunkDataStart + 4, Endian.little);
        bitsPerSample = byteData.getUint16(chunkDataStart + 14, Endian.little);

        final isPcm =
            audioFormat == _waveFormatPcm ||
            (audioFormat == _waveFormatExtensible &&
                chunkSize >= 40 &&
                _matchesPcmSubformat(bytes, chunkDataStart + 24));
        if (!isPcm) {
          throw FormatException(
            'Unsupported WAV format tag 0x${audioFormat.toRadixString(16)}',
          );
        }
        if (bitsPerSample != 16) {
          throw FormatException(
            'Only 16-bit PCM WAV supported, got $bitsPerSample-bit',
          );
        }
        break;
      case 'data':
        pcmData = Uint8List.fromList(
          bytes.sublist(chunkDataStart, chunkDataEnd),
        );
        break;
    }

    offset = chunkDataEnd + (chunkSize.isOdd ? 1 : 0);
  }

  if (audioFormat == null) {
    throw const FormatException('Missing fmt chunk');
  }
  if (pcmData == null) {
    throw const FormatException('Missing data chunk');
  }
  if (sampleRate == null || channelCount == null || bitsPerSample == null) {
    throw const FormatException('Incomplete fmt chunk');
  }

  return _ParsedWave(
    sampleRate: sampleRate,
    channelCount: channelCount,
    bitsPerSample: bitsPerSample,
    pcmData: pcmData,
  );
}

Uint8List _buildCanonicalWave({
  required int sampleRate,
  required int channelCount,
  required int bitsPerSample,
  required Uint8List pcmData,
}) {
  final bytesPerSample = bitsPerSample ~/ 8;
  final blockAlign = channelCount * bytesPerSample;
  final byteRate = sampleRate * blockAlign;
  final riffSize = 36 + pcmData.lengthInBytes;

  final header = ByteData(44);
  _writeFourCc(header, 0, 'RIFF');
  header.setUint32(4, riffSize, Endian.little);
  _writeFourCc(header, 8, 'WAVE');
  _writeFourCc(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, _waveFormatPcm, Endian.little);
  header.setUint16(22, channelCount, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  _writeFourCc(header, 36, 'data');
  header.setUint32(40, pcmData.lengthInBytes, Endian.little);

  final output = Uint8List(44 + pcmData.lengthInBytes);
  output.setRange(0, 44, header.buffer.asUint8List());
  output.setRange(44, output.length, pcmData);
  return output;
}

bool _matchesPcmSubformat(Uint8List bytes, int offset) {
  if (offset + _pcmSubformatGuid.length > bytes.lengthInBytes) {
    return false;
  }
  for (var i = 0; i < _pcmSubformatGuid.length; i++) {
    if (bytes[offset + i] != _pcmSubformatGuid[i]) {
      return false;
    }
  }
  return true;
}

String _readFourCc(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

void _writeFourCc(ByteData data, int offset, String value) {
  data.buffer.asUint8List(offset, 4).setAll(0, value.codeUnits);
}

class _ParsedWave {
  const _ParsedWave({
    required this.sampleRate,
    required this.channelCount,
    required this.bitsPerSample,
    required this.pcmData,
  });

  final int sampleRate;
  final int channelCount;
  final int bitsPerSample;
  final Uint8List pcmData;
}
