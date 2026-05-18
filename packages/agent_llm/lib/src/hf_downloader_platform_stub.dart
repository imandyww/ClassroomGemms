import 'dart:io';

Future<Directory> defaultGemmaAppSupportDirectory() {
  throw UnsupportedError(
    'A Gemma app-support directory resolver is required on non-Flutter '
    'platforms. Pass installRootDirectory explicitly when running the preload '
    'CLI.',
  );
}

void gemmaDebugLog(String message) {
  stderr.writeln(message);
}
