import 'package:agent_llm/agent_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canReusePickedModelForStt', () {
    test('accepts supported Gemma models', () {
      expect(
        canReusePickedModelForStt(
          PickedModel(slug: gemma4E2b.slug, sourceLabel: 'test'),
        ),
        isTrue,
      );
      expect(
        canReusePickedModelForStt(
          PickedModel(slug: gemma4E4b.slug, sourceLabel: 'test'),
        ),
        isTrue,
      );
    });

    test('rejects the qwen fallback model', () {
      expect(
        canReusePickedModelForStt(
          PickedModel(
            slug: fallbackSlug,
            sourceLabel: 'test',
            isFallback: true,
          ),
        ),
        isFalse,
      );
    });
  });
}
