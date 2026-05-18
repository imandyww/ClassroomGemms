import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> defaultGemmaAppSupportDirectory() =>
    getApplicationSupportDirectory();

void gemmaDebugLog(String message) {
  debugPrint(message);
}
