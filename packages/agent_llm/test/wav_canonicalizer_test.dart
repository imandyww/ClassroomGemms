import 'dart:io';
import 'dart:typed_data';

import 'package:agent_llm/src/wav_canonicalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wav canonicalizer', () {
    test('canonicalizeWavAsPcm rewrites extensible wav chunks into PCM', () {
      final pcm = Uint8List.fromList(const <int>[0x34, 0x12, 0x78, 0x56]);
      final extensible = _buildExtensibleWave(pcm);

      final canonical = canonicalizeWavAsPcm(extensible);
      final data = ByteData.sublistView(canonical);

      expect(String.fromCharCodes(canonical.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(canonical.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(canonical.sublist(12, 16)), 'fmt ');
      expect(data.getUint32(16, Endian.little), 16);
      expect(data.getUint16(20, Endian.little), 1);
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint32(24, Endian.little), 16000);
      expect(data.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(canonical.sublist(36, 40)), 'data');
      expect(data.getUint32(40, Endian.little), pcm.length);
      expect(canonical.sublist(44), pcm);
      expect(canonical.length, 44 + pcm.length);
    });

    test('rewriteWavAsCanonicalPcm updates files in place', () async {
      final tempDir = await Directory.systemTemp.createTemp('wav-canon-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/sample.wav');
      final pcm = Uint8List.fromList(List<int>.generate(8, (index) => index));
      await file.writeAsBytes(_buildExtensibleWave(pcm));

      final rewrittenPath = await rewriteWavAsCanonicalPcm(file.path);
      final canonical = await File(rewrittenPath).readAsBytes();
      final data = ByteData.sublistView(canonical);

      expect(rewrittenPath, file.path);
      expect(data.getUint16(20, Endian.little), 1);
      expect(String.fromCharCodes(canonical.sublist(36, 40)), 'data');
      expect(canonical.sublist(44), pcm);
    });
  });
}

Uint8List _buildExtensibleWave(Uint8List pcmData) {
  final builder = BytesBuilder(copy: false);
  final junkChunkSize = 28;
  final fillerChunkSize = 16;
  final totalSize =
      12 +
      8 +
      junkChunkSize +
      8 +
      40 +
      8 +
      fillerChunkSize +
      8 +
      pcmData.length;

  builder.add('RIFF'.codeUnits);
  builder.add(_u32(totalSize - 8));
  builder.add('WAVE'.codeUnits);

  builder.add('JUNK'.codeUnits);
  builder.add(_u32(junkChunkSize));
  builder.add(Uint8List(junkChunkSize));

  builder.add('fmt '.codeUnits);
  builder.add(_u32(40));
  builder.add(_u16(0xFFFE));
  builder.add(_u16(1));
  builder.add(_u32(16000));
  builder.add(_u32(32000));
  builder.add(_u16(2));
  builder.add(_u16(16));
  builder.add(_u16(22));
  builder.add(_u16(16));
  builder.add(_u32(0));
  builder.add(
    Uint8List.fromList(const <int>[
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
    ]),
  );

  builder.add('FLLR'.codeUnits);
  builder.add(_u32(fillerChunkSize));
  builder.add(Uint8List(fillerChunkSize));

  builder.add('data'.codeUnits);
  builder.add(_u32(pcmData.length));
  builder.add(pcmData);

  return builder.takeBytes();
}

Uint8List _u16(int value) {
  final data = ByteData(2)..setUint16(0, value, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _u32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}
