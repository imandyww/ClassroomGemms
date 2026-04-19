import 'hf_downloader.dart';

enum DeviceTier {
  /// iOS phone — prefer small gemma-4-E2B.
  phone,

  /// Mac — prefer gemma-4-E4B.
  desktop,
}

class PickedModel {
  final String slug;
  final String? modelPath;
  final int? quantization;
  final bool isFallback;
  final String sourceLabel;

  PickedModel({
    required this.slug,
    this.modelPath,
    this.quantization,
    this.isFallback = false,
    required this.sourceLabel,
  });
}

HfGemma4Spec primarySpec(DeviceTier tier) => tier == DeviceTier.phone ? gemma4E2b : gemma4E4b;

/// Fallback Cactus slug used when gemma-4 int4 download/init fails. This path
/// flows through the stock Supabase registry; [quantization] is read from the
/// backend so we leave it null. Must support tool calling for the ReAct loop.
const String fallbackSlug = 'qwen3-1.7';
