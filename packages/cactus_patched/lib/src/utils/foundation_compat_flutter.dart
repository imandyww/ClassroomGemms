import 'dart:async';

import 'package:flutter/foundation.dart';

void debugLog(String message) {
  debugPrint(message);
}

Future<R> runInBackground<Q, R>(
  FutureOr<R> Function(Q message) callback,
  Q message,
) {
  return compute(callback, message);
}
