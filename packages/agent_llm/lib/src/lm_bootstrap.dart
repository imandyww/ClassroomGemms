import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';

import 'hf_downloader.dart';
import 'model_picker.dart';

typedef StatusCb = void Function(String message);

class LmBootstrap {
  final CactusLM lm;
  final DeviceTier tier;

  LmBootstrap({required this.tier, CactusLM? lm})
      : lm = lm ?? CactusLM(enableToolFiltering: false);

  /// Try gemma-4 int4 via the vendored modelPath bypass; fall back to a
  /// stock Cactus-hosted model if anything breaks.
  Future<PickedModel> ensureReady({StatusCb? onStatus}) async {
    final spec = primarySpec(tier);
    try {
      onStatus?.call('Fetching ${spec.slug} weights from HuggingFace...');
      final path = await ensureGemma4(
        spec: spec,
        onProgress: (p, msg) => onStatus?.call('$msg (${(p * 100).toStringAsFixed(0)}%)'),
      );

      final ctxSize = tier == DeviceTier.phone ? 2048 : 4096;
      onStatus?.call('Initializing Cactus with ${spec.slug} from $path...');
      await lm.initializeModel(params: CactusInitParams(
        model: spec.slug,
        modelPath: path,
        quantization: 4,
        contextSize: ctxSize,
      ));
      onStatus?.call('Loaded ${spec.slug}.');
      return PickedModel(
        slug: spec.slug,
        modelPath: path,
        quantization: 4,
        sourceLabel: 'HuggingFace int4',
      );
    } catch (e, st) {
      debugPrint('gemma-4 load failed: $e\n$st');
      onStatus?.call('gemma-4 int4 path failed: $e. Falling back to $fallbackSlug.');
      await lm.downloadModel(
        model: fallbackSlug,
        downloadProcessCallback: (progress, msg, isError) {
          if (progress != null) {
            onStatus?.call('Fallback dl: $msg (${(progress * 100).toStringAsFixed(0)}%)');
          } else {
            onStatus?.call('Fallback dl: $msg');
          }
        },
      );
      await lm.initializeModel(params: CactusInitParams(model: fallbackSlug));
      onStatus?.call('Loaded fallback $fallbackSlug.');
      return PickedModel(
        slug: fallbackSlug,
        sourceLabel: 'Cactus Supabase fallback',
        isFallback: true,
      );
    }
  }
}
