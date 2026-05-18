import 'dart:async';
import 'dart:io';
import 'dart:isolate';

void debugLog(String message) {
  stderr.writeln(message);
}

Future<R> runInBackground<Q, R>(
  FutureOr<R> Function(Q message) callback,
  Q message,
) {
  return Isolate.run(() => callback(message));
}
