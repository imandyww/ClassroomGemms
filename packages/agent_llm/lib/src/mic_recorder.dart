import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'wav_canonicalizer.dart';

/// Tiny push-to-talk recorder. Writes a 16 kHz mono WAV file tailored for
/// Gemma / Cactus STT.
class MicRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  String? _activePath;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path = p.join(
      dir.path,
      'ptt_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    _activePath = path;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
  }

  /// Returns the path of the produced WAV file, or null if nothing was recorded.
  Future<String?> stop() async {
    final stopped = await _recorder.stop();
    final path = stopped ?? _activePath;
    _activePath = null;
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists() || await f.length() < 1024) return null;
    return rewriteWavAsCanonicalPcm(path);
  }

  Future<void> dispose() async {
    await _recorder.dispose();
  }

  Future<bool> get isRecording => _recorder.isRecording();
}
