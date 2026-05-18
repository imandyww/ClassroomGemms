import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Sanity-checks that the demo PDF shipped in docs/demo_lessons/ has the same
/// text shape the import flow expects: selectable, non-empty, and including
/// the science vocabulary that the lesson-draft prompt depends on.
void main() {
  test('photosynthesis_handout.pdf is text-selectable', () {
    final pdfFile = File(
      'docs/demo_lessons/photosynthesis_handout.pdf',
    );
    final fallback = File(
      '../../docs/demo_lessons/photosynthesis_handout.pdf',
    );
    final source = pdfFile.existsSync() ? pdfFile : fallback;
    expect(
      source.existsSync(),
      isTrue,
      reason: 'demo PDF missing — run scripts/build_demo_pdf.py',
    );
    final doc = PdfDocument(inputBytes: source.readAsBytesSync());
    try {
      final text = PdfTextExtractor(doc).extractText();
      expect(text.length, greaterThan(500));
      for (final needle in const [
        'PHOTOSYNTHESIS',
        'chloroplast',
        'chlorophyll',
        'Calvin cycle',
        'glucose',
      ]) {
        expect(
          text.contains(needle),
          isTrue,
          reason: 'expected "$needle" in extracted text',
        );
      }
    } finally {
      doc.dispose();
    }
  });
}
