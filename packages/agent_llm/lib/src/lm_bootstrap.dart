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
  ///
  /// Order of attempts:
  ///   1. Primary HF spec for this device tier (E4B on desktop, E2B on phone)
  ///   2. If the primary's zip 404s on HF, try the sibling spec (E2B ↔ E4B)
  ///   3. Only if both HF paths fail, download qwen3-1.7 from Cactus Supabase
  Future<PickedModel> ensureReady({StatusCb? onStatus}) async {
    final primary = primarySpec(tier);
    final secondary = primary.slug == gemma4E4b.slug ? gemma4E2b : gemma4E4b;

    for (final spec in [primary, secondary]) {
      try {
        onStatus?.call('Fetching ${spec.slug} weights from HuggingFace...');
        final path = await ensureGemma4(
          spec: spec,
          onProgress: (p, msg) =>
              onStatus?.call('$msg (${(p * 100).toStringAsFixed(0)}%)'),
        );

        // Phones are much tighter on RAM than desktops, and the Cactus docs
        // explicitly recommend dropping context size to reduce memory use.
        final ctxSize = tier == DeviceTier.phone ? 1024 : 4096;
        onStatus?.call('Initializing Cactus with ${spec.slug} from $path...');
        await lm.initializeModel(
          params: CactusInitParams(
            model: spec.slug,
            modelPath: path,
            quantization: 4,
            contextSize: ctxSize,
          ),
        );
        onStatus?.call('Loaded ${spec.slug}.');
        return PickedModel(
          slug: spec.slug,
          modelPath: path,
          quantization: 4,
          sourceLabel: spec == primary
              ? 'HuggingFace int4'
              : 'HuggingFace int4 (sibling fallback)',
        );
      } catch (e, st) {
        debugPrint('${spec.slug} load failed: $e\n$st');
        if (spec == primary) {
          onStatus?.call(
            '${spec.slug} int4 path failed: $e. Trying ${secondary.slug}...',
          );
        } else {
          onStatus?.call(
            '${spec.slug} also failed: $e. Falling back to $fallbackSlug.',
          );
        }
      }
    }

    await lm.downloadModel(
      model: fallbackSlug,
      downloadProcessCallback: (progress, msg, isError) {
        if (progress != null) {
          onStatus?.call(
            'Fallback dl: $msg (${(progress * 100).toStringAsFixed(0)}%)',
          );
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
