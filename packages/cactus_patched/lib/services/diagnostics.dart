import 'package:cactus/src/services/context.dart';

class CactusModelValidation {
  final bool success;
  final String message;

  const CactusModelValidation({required this.success, required this.message});
}

class CactusDiagnostics {
  static Future<CactusModelValidation> validateModelPath(
    String modelPath, {
    int contextSize = 256,
  }) async {
    final result = await CactusContext.validateModelPath(
      modelPath,
      contextSize: contextSize,
    );
    return CactusModelValidation(
      success: result.success,
      message: result.message,
    );
  }

  static Future<String> engineCompatibilityId() =>
      CactusContext.engineCompatibilityId();
}
