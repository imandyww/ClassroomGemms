import 'package:flutter/material.dart';

/// Subject-tinted theme tokens used by the lesson hero, step tiles, and other
/// surfaces that should pick up a hint of the current lesson's subject. Keeps
/// the mapping in one place so adding a subject is a single edit.
class SubjectPalette {
  final Color seed;
  final Color tint;
  final Color accent;
  final IconData icon;
  final String shortLabel;

  const SubjectPalette({
    required this.seed,
    required this.tint,
    required this.accent,
    required this.icon,
    required this.shortLabel,
  });

  LinearGradient get heroGradient => LinearGradient(
    colors: [tint, tint.withValues(alpha: 0.35)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

SubjectPalette paletteForSubject(String? subject) {
  final key = (subject ?? '').toLowerCase();
  if (key.contains('math')) {
    return SubjectPalette(
      seed: const Color(0xFF4F46E5),
      tint: const Color(0xFFE0E7FF),
      accent: const Color(0xFF3730A3),
      icon: Icons.calculate_outlined,
      shortLabel: 'Math',
    );
  }
  if (key.contains('science')) {
    return SubjectPalette(
      seed: const Color(0xFF059669),
      tint: const Color(0xFFD1FAE5),
      accent: const Color(0xFF065F46),
      icon: Icons.science_outlined,
      shortLabel: 'Science',
    );
  }
  if (key.contains('english') || key.contains('language arts') || key == 'ela') {
    return SubjectPalette(
      seed: const Color(0xFFD97706),
      tint: const Color(0xFFFEF3C7),
      accent: const Color(0xFF92400E),
      icon: Icons.menu_book_outlined,
      shortLabel: 'ELA',
    );
  }
  if (key.contains('social') || key.contains('history') || key.contains('geography')) {
    return SubjectPalette(
      seed: const Color(0xFFBE185D),
      tint: const Color(0xFFFCE7F3),
      accent: const Color(0xFF9D174D),
      icon: Icons.public_outlined,
      shortLabel: 'Social',
    );
  }
  if (key.contains('computer') || key.contains('coding') || key.contains('cs')) {
    return SubjectPalette(
      seed: const Color(0xFF0284C7),
      tint: const Color(0xFFE0F2FE),
      accent: const Color(0xFF075985),
      icon: Icons.code,
      shortLabel: 'CS',
    );
  }
  if (key.contains('language') || key.contains('spanish') || key.contains('french')) {
    return SubjectPalette(
      seed: const Color(0xFF0D9488),
      tint: const Color(0xFFCCFBF1),
      accent: const Color(0xFF115E59),
      icon: Icons.translate,
      shortLabel: 'Lang',
    );
  }
  if (key.contains('art') || key.contains('music')) {
    return SubjectPalette(
      seed: const Color(0xFF9333EA),
      tint: const Color(0xFFEDE9FE),
      accent: const Color(0xFF6B21A8),
      icon: Icons.palette_outlined,
      shortLabel: 'Arts',
    );
  }
  if (key.contains('health') || key.contains('p.e') || key.contains('phys')) {
    return SubjectPalette(
      seed: const Color(0xFFDC2626),
      tint: const Color(0xFFFEE2E2),
      accent: const Color(0xFF991B1B),
      icon: Icons.favorite_outline,
      shortLabel: 'Health',
    );
  }
  return SubjectPalette(
    seed: const Color(0xFF0F766E),
    tint: const Color(0xFFCCFBF1),
    accent: const Color(0xFF115E59),
    icon: Icons.school_outlined,
    shortLabel: 'Class',
  );
}

/// Stable per-student tinting for roster avatars.
Color colorForFingerprint(String fingerprint) {
  const swatches = [
    Color(0xFF0EA5E9), // sky
    Color(0xFFF59E0B), // amber
    Color(0xFF22C55E), // green
    Color(0xFFEC4899), // pink
    Color(0xFF8B5CF6), // violet
    Color(0xFF14B8A6), // teal
    Color(0xFFEF4444), // red
    Color(0xFF6366F1), // indigo
  ];
  var hash = 0;
  for (final code in fingerprint.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return swatches[hash % swatches.length];
}

String initialsFor(String alias) {
  final cleaned = alias.replaceAll(RegExp(r'[^A-Za-z\s]'), ' ').trim();
  if (cleaned.isEmpty) return '·';
  final parts = cleaned.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length == 1) {
    return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1).toUpperCase();
  }
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}
