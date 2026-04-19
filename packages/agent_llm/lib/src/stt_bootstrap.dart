import 'package:cactus/cactus.dart';

import 'lm_bootstrap.dart' show StatusCb;

class SttBootstrap {
  final CactusSTT stt;
  static const String whisperSlug = 'whisper-tiny';

  SttBootstrap({CactusSTT? stt}) : stt = stt ?? CactusSTT();

  Future<void> ensureReady({StatusCb? onStatus}) async {
    onStatus?.call('Downloading $whisperSlug...');
    await stt.downloadModel(
      model: whisperSlug,
      downloadProcessCallback: (progress, msg, isError) {
        if (progress != null) {
          onStatus?.call('Whisper dl: $msg (${(progress * 100).toStringAsFixed(0)}%)');
        } else {
          onStatus?.call('Whisper dl: $msg');
        }
      },
    );
    onStatus?.call('Initializing Whisper...');
    await stt.initializeModel(params: CactusInitParams(model: whisperSlug));
    onStatus?.call('Whisper ready.');
  }

  Future<String> transcribeFile(String path) async {
    final result = await stt.transcribe(audioFilePath: path);
    if (!result.success) {
      throw Exception('STT failed: ${result.errorMessage}');
    }
    return result.text;
  }
}
