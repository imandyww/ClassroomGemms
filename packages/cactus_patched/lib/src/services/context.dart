import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cactus/models/types.dart';
import 'package:cactus/models/tools.dart';
import 'package:cactus/src/models/binding.dart';
import 'package:cactus/src/utils/foundation_compat_stub.dart'
    if (dart.library.ui) 'package:cactus/src/utils/foundation_compat_flutter.dart';
import 'package:cactus/src/version.dart';
import 'package:ffi/ffi.dart';

import 'bindings.dart' as bindings;

class CactusValidationResult {
  final bool success;
  final String message;

  const CactusValidationResult({required this.success, required this.message});
}

// Global callback storage for streaming completions
CactusTokenCallback? _activeTokenCallback;

// Static callback function that can be used with Pointer.fromFunction
@pragma('vm:entry-point')
void _staticTokenCallbackDispatcher(
  Pointer<Utf8> tokenC,
  int tokenId,
  Pointer<Void> userData,
) {
  try {
    final callback = _activeTokenCallback;
    if (callback != null) {
      final tokenString = tokenC.toDartString();
      callback(tokenString);
    }
  } catch (e) {
    debugLog('Token callback error: $e');
  }
}

Future<(int?, String)> _initContextInIsolate(
  Map<String, dynamic> params,
) async {
  final modelPath = params['modelPath'] as String;
  final contextSize = params['contextSize'] as int;

  try {
    debugLog(
      'Initializing context with model: $modelPath, contextSize: $contextSize',
    );
    final modelPathC = modelPath.toNativeUtf8(allocator: calloc);
    try {
      // We are not using corpusDir for now, passing null pointer
      final handle = bindings.cactusInit(modelPathC, contextSize, nullptr);
      if (handle != nullptr) {
        return (handle.address, 'Context initialized successfully');
      } else {
        return (
          null,
          _readLastErrorMessage() ?? 'Failed to initialize context',
        );
      }
    } finally {
      calloc.free(modelPathC);
    }
  } catch (e) {
    final nativeError = _readLastErrorMessage();
    if (nativeError != null && nativeError.isNotEmpty) {
      return (null, nativeError);
    }
    return (null, 'Exception during context initialization: $e');
  }
}

String? _readLastErrorMessage() {
  try {
    final messagePtr = bindings.cactusGetLastError();
    if (messagePtr == nullptr) {
      return null;
    }
    final message = messagePtr.toDartString().trim();
    return message.isEmpty ? null : message;
  } catch (_) {
    return null;
  }
}

String? _readResponseBufferMessage(Pointer<Uint8> buffer, int bufferSize) {
  try {
    final bytes = buffer.asTypedList(bufferSize);
    final end = bytes.indexOf(0);
    final usableBytes = end >= 0 ? bytes.sublist(0, end) : bytes;
    if (usableBytes.isEmpty) {
      return null;
    }

    final raw = utf8.decode(usableBytes, allowMalformed: true).trim();
    if (raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is String && error.trim().isNotEmpty) {
          return error.trim();
        }
        final response = decoded['response'];
        if (response is String && response.trim().isNotEmpty) {
          return response.trim();
        }
      }
    } catch (_) {
      // Fall back to the raw buffer text when the native side does not return
      // JSON.
    }
    return raw;
  } catch (_) {
    return null;
  }
}

Future<CactusCompletionResult> _completionInIsolate(
  Map<String, dynamic> params,
) async {
  final handle = params['handle'] as int;
  final messagesJson = params['messagesJson'] as String;
  final optionsJson = params['optionsJson'] as String;
  final toolsJson = params['toolsJson'] as String?;
  final bufferSize = params['bufferSize'] as int;
  final hasCallback = params['hasCallback'] as bool;
  final SendPort? replyPort = params['replyPort'] as SendPort?;

  final responseBuffer = calloc<Uint8>(bufferSize);
  final messagesJsonC = messagesJson.toNativeUtf8(allocator: calloc);
  final optionsJsonC = optionsJson.toNativeUtf8(allocator: calloc);
  final toolsJsonC = toolsJson?.toNativeUtf8(allocator: calloc);

  Pointer<NativeFunction<CactusTokenCallbackNative>>? callbackPointer;

  try {
    if (hasCallback && replyPort != null) {
      // Set up token callback to send tokens back through isolate
      _activeTokenCallback = (token) {
        replyPort.send({'type': 'token', 'data': token});
        return true; // Always continue in isolate mode
      };

      callbackPointer = Pointer.fromFunction<CactusTokenCallbackNative>(
        _staticTokenCallbackDispatcher,
      );
    }

    final result = bindings.cactusComplete(
      Pointer.fromAddress(handle),
      messagesJsonC,
      responseBuffer.cast<Utf8>(),
      bufferSize,
      optionsJsonC,
      toolsJsonC ?? nullptr,
      callbackPointer ?? nullptr,
      nullptr,
    );

    debugLog('Received completion result code: $result');

    if (result > 0) {
      final responseText = utf8
          .decode(responseBuffer.asTypedList(result), allowMalformed: true)
          .trim();

      try {
        final jsonResponse = jsonDecode(responseText) as Map<String, dynamic>;
        final success = jsonResponse['success'] as bool? ?? true;
        final response = jsonResponse['response'] as String? ?? responseText;
        final timeToFirstTokenMs =
            (jsonResponse['time_to_first_token_ms'] as num?)?.toDouble() ?? 0.0;
        final totalTimeMs =
            (jsonResponse['total_time_ms'] as num?)?.toDouble() ?? 0.0;
        final tokensPerSecond =
            (jsonResponse['tokens_per_second'] as num?)?.toDouble() ?? 0.0;
        final prefillTokens = jsonResponse['prefill_tokens'] as int? ?? 0;
        final decodeTokens = jsonResponse['decode_tokens'] as int? ?? 0;
        final totalTokens = jsonResponse['total_tokens'] as int? ?? 0;

        // Parse tool calls
        List<ToolCall> toolCalls = [];
        if (jsonResponse['function_calls'] != null) {
          final toolCallsJson = jsonResponse['function_calls'] as List<dynamic>;
          toolCalls = toolCallsJson
              .map(
                (toolCallJson) =>
                    ToolCall.fromJson(toolCallJson as Map<String, dynamic>),
              )
              .toList();
        }

        return CactusCompletionResult(
          success: success,
          response: response,
          timeToFirstTokenMs: timeToFirstTokenMs,
          totalTimeMs: totalTimeMs,
          tokensPerSecond: tokensPerSecond,
          prefillTokens: prefillTokens,
          decodeTokens: decodeTokens,
          totalTokens: totalTokens,
          toolCalls: toolCalls,
        );
      } catch (e) {
        debugLog('Unable to parse the response json: $e');
        return CactusCompletionResult(
          success: false,
          response: 'Error: Unable to parse the response',
          timeToFirstTokenMs: 0.0,
          totalTimeMs: 0.0,
          tokensPerSecond: 0.0,
          prefillTokens: 0,
          decodeTokens: 0,
          totalTokens: 0,
          toolCalls: [],
        );
      }
    } else {
      final nativeMessage = _readResponseBufferMessage(
        responseBuffer,
        bufferSize,
      );
      return CactusCompletionResult(
        success: false,
        response: nativeMessage ?? 'Error: completion failed with code $result',
        timeToFirstTokenMs: 0.0,
        totalTimeMs: 0.0,
        tokensPerSecond: 0.0,
        prefillTokens: 0,
        decodeTokens: 0,
        totalTokens: 0,
        toolCalls: [],
      );
    }
  } finally {
    _activeTokenCallback = null;
    calloc.free(responseBuffer);
    calloc.free(messagesJsonC);
    calloc.free(optionsJsonC);
    if (toolsJsonC != null) {
      calloc.free(toolsJsonC);
    }
  }
}

Future<CactusEmbeddingResult> _generateEmbeddingInIsolate(
  Map<String, dynamic> params,
) async {
  final handle = params['handle'] as int;
  final text = params['text'] as String;
  final bufferSize = params['bufferSize'] as int;

  final textC = text.toNativeUtf8(allocator: calloc);
  final embeddingDimPtr = calloc<Size>();
  final embeddingsBuffer = calloc<Float>(bufferSize);

  try {
    debugLog(
      'Generating embedding for text: ${text.length > 50 ? "${text.substring(0, 50)}..." : text}',
    );

    // Calculate buffer size in bytes (bufferSize * sizeof(float))
    final bufferSizeInBytes = bufferSize * 4;

    final result = bindings.cactusEmbed(
      Pointer.fromAddress(handle),
      textC,
      embeddingsBuffer,
      bufferSizeInBytes,
      embeddingDimPtr,
    );

    debugLog('Received embedding result code: $result');

    if (result > 0) {
      final actualEmbeddingDim = embeddingDimPtr.value;
      debugLog('Actual embedding dimension: $actualEmbeddingDim');

      if (actualEmbeddingDim > bufferSize) {
        return CactusEmbeddingResult(
          success: false,
          embeddings: [],
          dimension: 0,
          errorMessage:
              'Embedding dimension ($actualEmbeddingDim) exceeds allocated buffer size ($bufferSize)',
        );
      }

      final embeddings = <double>[];
      for (int i = 0; i < actualEmbeddingDim; i++) {
        embeddings.add(embeddingsBuffer[i]);
      }

      debugLog('Successfully extracted ${embeddings.length} embedding values');

      return CactusEmbeddingResult(
        success: true,
        embeddings: embeddings,
        dimension: actualEmbeddingDim,
      );
    } else {
      return CactusEmbeddingResult(
        success: false,
        embeddings: [],
        dimension: 0,
        errorMessage: 'Embedding generation failed with code $result',
      );
    }
  } catch (e) {
    debugLog('Exception during embedding generation: $e');
    return CactusEmbeddingResult(
      success: false,
      embeddings: [],
      dimension: 0,
      errorMessage: 'Exception: $e',
    );
  } finally {
    calloc.free(textC);
    calloc.free(embeddingDimPtr);
    calloc.free(embeddingsBuffer);
  }
}

Future<CactusTranscriptionResult> _transcribeInIsolate(
  Map<String, dynamic> params,
) async {
  final handle = params['handle'] as int;
  final audioFilePath = params['audioFilePath'] as String?;
  final prompt = params['prompt'] as String;
  final optionsJson = params['optionsJson'] as String;
  final bufferSize = params['bufferSize'] as int;
  final hasCallback = params['hasCallback'] as bool;
  final SendPort? replyPort = params['replyPort'] as SendPort?;
  final List<int>? pcmData = params['pcmData'] as List<int>?;

  if (audioFilePath == null && pcmData == null) {
    debugLog('ERROR: Neither audio file path nor PCM buffer provided');
    return CactusTranscriptionResult(
      success: false,
      text: '',
      errorMessage: 'Either audio file path or PCM buffer must be provided',
    );
  }

  if (audioFilePath != null) {
    final audioFile = File(audioFilePath);
    if (!audioFile.existsSync()) {
      debugLog('ERROR: Audio file does not exist at path: $audioFilePath');
      return CactusTranscriptionResult(
        success: false,
        text: '',
        errorMessage: 'Audio file not found: $audioFilePath',
      );
    }

    final fileSize = audioFile.lengthSync();
    debugLog('Audio file exists, size: $fileSize bytes');
  } else {
    debugLog('Using PCM buffer, size: ${pcmData!.length} bytes');
  }

  final responseBuffer = calloc<Uint8>(bufferSize);
  final audioFilePathC = audioFilePath?.toNativeUtf8(allocator: calloc);
  final promptC = prompt.toNativeUtf8(allocator: calloc);
  final optionsJsonC = optionsJson.toNativeUtf8(allocator: calloc);

  Pointer<Uint8>? pcmBufferPtr;
  if (pcmData != null) {
    final Uint8List pcmBytes = pcmData is Uint8List
        ? pcmData
        : Uint8List.fromList(pcmData);
    pcmBufferPtr = calloc<Uint8>(pcmBytes.length);
    final nativeList = pcmBufferPtr.asTypedList(pcmBytes.length);
    nativeList.setAll(0, pcmBytes);
  }

  Pointer<NativeFunction<CactusTokenCallbackNative>>? callbackPointer;

  try {
    if (hasCallback && replyPort != null) {
      _activeTokenCallback = (token) {
        replyPort.send({'type': 'token', 'data': token});
        return true;
      };

      callbackPointer = Pointer.fromFunction<CactusTokenCallbackNative>(
        _staticTokenCallbackDispatcher,
      );
    }

    final result = bindings.cactusTranscribe(
      Pointer.fromAddress(handle),
      audioFilePathC ?? nullptr,
      promptC,
      responseBuffer.cast<Utf8>(),
      bufferSize,
      optionsJsonC,
      callbackPointer ?? nullptr,
      nullptr,
      pcmBufferPtr ?? nullptr,
      pcmData?.length ?? 0,
    );

    final nativeMessage = _readResponseBufferMessage(
      responseBuffer,
      bufferSize,
    );
    if (result <= 0 && nativeMessage != null) {
      debugLog('Error message from C++: $nativeMessage');
    }

    if (result > 0) {
      final responseText = utf8
          .decode(responseBuffer.asTypedList(result), allowMalformed: true)
          .trim();
      try {
        final jsonResponse = jsonDecode(responseText) as Map<String, dynamic>;
        final success = jsonResponse['success'] as bool? ?? true;
        // Try 'text' first, then 'response', then fall back to raw responseText
        final text =
            (jsonResponse['text'] as String?) ??
            (jsonResponse['response'] as String?) ??
            responseText;
        final timeToFirstTokenMs =
            (jsonResponse['time_to_first_token_ms'] as num?)?.toDouble() ?? 0.0;
        final totalTimeMs =
            (jsonResponse['total_time_ms'] as num?)?.toDouble() ?? 0.0;
        final tokensPerSecond =
            (jsonResponse['tokens_per_second'] as num?)?.toDouble() ?? 0.0;

        return CactusTranscriptionResult(
          success: success,
          // [TEMP] Clean up special tokens from the text
          text: text.trim().replaceAll('<|startoftranscript|>', ''),
          timeToFirstTokenMs: timeToFirstTokenMs,
          totalTimeMs: totalTimeMs,
          tokensPerSecond: tokensPerSecond,
        );
      } catch (e) {
        debugLog('Unable to parse the transcription response json: $e');
        return CactusTranscriptionResult(success: false, text: '');
      }
    } else {
      return CactusTranscriptionResult(
        success: false,
        text: '',
        errorMessage:
            nativeMessage ?? 'Error: transcription failed with code $result',
      );
    }
  } finally {
    _activeTokenCallback = null;
    calloc.free(responseBuffer);
    if (audioFilePathC != null) {
      calloc.free(audioFilePathC);
    }
    calloc.free(promptC);
    calloc.free(optionsJsonC);
    if (pcmBufferPtr != null) {
      calloc.free(pcmBufferPtr);
    }
  }
}

class CactusContext {
  static Future<CactusValidationResult> validateModelPath(
    String modelPath, {
    int contextSize = 256,
  }) async {
    final result = await initContext(modelPath, contextSize);
    final handle = result.$1;
    if (handle != null) {
      freeContext(handle);
      return CactusValidationResult(success: true, message: result.$2);
    }
    return CactusValidationResult(success: false, message: result.$2);
  }

  // Identifies the bundled cactus engine for the hf_downloader's ready/rejected
  // markers. Must be stable across relaunches of the *same* build: if this flips
  // on every launch, the downloader treats cached weights and known-bad refs
  // as fresh input and re-downloads multi-GB archives every launch. macOS
  // `flutter run` re-copies/re-signs the framework and bumps its mtime, so we
  // deliberately avoid mtime here. Package version + binary size is stable
  // across launches and flips when the vendored cactus package is upgraded or
  // the binary itself changes.
  static Future<String> engineCompatibilityId() async {
    final libraryPath = bindings.resolveCactusLibraryPath();
    if (libraryPath == null) {
      return 'cactus:${Platform.operatingSystem}:$packageVersion:unresolved';
    }

    final stat = await File(libraryPath).stat();
    return 'cactus:${Platform.operatingSystem}:$packageVersion:${stat.size}';
  }

  static String _escapeJsonString(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  static Map<String, String?> _prepareCompletionJson(
    List<ChatMessage> messages,
    CactusCompletionParams params,
  ) {
    // Prepare messages JSON
    final messagesJsonBuffer = StringBuffer('[');
    for (int i = 0; i < messages.length; i++) {
      if (i > 0) messagesJsonBuffer.write(',');
      messagesJsonBuffer.write('{');
      messagesJsonBuffer.write('"role":"${messages[i].role}",');
      messagesJsonBuffer.write(
        '"content":"${_escapeJsonString(messages[i].content)}"',
      );
      if (messages[i].images.isNotEmpty) {
        messagesJsonBuffer.write(',"images":[');
        for (int j = 0; j < messages[i].images.length; j++) {
          if (j > 0) messagesJsonBuffer.write(',');
          messagesJsonBuffer.write(
            '"${_escapeJsonString(messages[i].images[j])}"',
          );
        }
        messagesJsonBuffer.write(']');
      }
      if (messages[i].audio.isNotEmpty) {
        messagesJsonBuffer.write(',"audio":[');
        for (int j = 0; j < messages[i].audio.length; j++) {
          if (j > 0) messagesJsonBuffer.write(',');
          messagesJsonBuffer.write(
            '"${_escapeJsonString(messages[i].audio[j])}"',
          );
        }
        messagesJsonBuffer.write(']');
      }
      messagesJsonBuffer.write('}');
    }
    messagesJsonBuffer.write(']');
    final messagesJson = messagesJsonBuffer.toString();

    // Prepare options JSON
    final optionsJsonBuffer = StringBuffer('{');
    params.temperature != null
        ? optionsJsonBuffer.write('"temperature":${params.temperature},')
        : null;
    params.topK != null
        ? optionsJsonBuffer.write('"top_k":${params.topK},')
        : null;
    params.topP != null
        ? optionsJsonBuffer.write('"top_p":${params.topP},')
        : null;
    params.forceTools != null
        ? optionsJsonBuffer.write('"force_tools":${params.forceTools},')
        : null;
    optionsJsonBuffer.write('"max_tokens":${params.maxTokens}');
    if (params.stopSequences.isNotEmpty) {
      optionsJsonBuffer.write(',"stop_sequences":[');
      for (int i = 0; i < params.stopSequences.length; i++) {
        if (i > 0) optionsJsonBuffer.write(',');
        optionsJsonBuffer.write(
          '"${_escapeJsonString(params.stopSequences[i])}"',
        );
      }
      optionsJsonBuffer.write(']');
    }
    optionsJsonBuffer.write('}');
    final optionsJson = optionsJsonBuffer.toString();

    // Prepare tools JSON if tools are provided
    String? toolsJson;
    if (params.tools != null && params.tools!.isNotEmpty) {
      toolsJson = params.tools!.toToolsJson();
    }

    return {
      'messagesJson': messagesJson,
      'optionsJson': optionsJson,
      'toolsJson': toolsJson,
    };
  }

  static Future<(int?, String)> initContext(
    String modelPath,
    int contextSize,
  ) async {
    // Run the heavy initialization in an isolate using compute
    final isolateParams = {'modelPath': modelPath, 'contextSize': contextSize};

    return await runInBackground(_initContextInIsolate, isolateParams);
  }

  static void freeContext(int handle) {
    try {
      bindings.cactusDestroy(Pointer.fromAddress(handle));
      debugLog('Context destroyed');
    } catch (e) {
      debugLog('Error destroying context: $e');
    }
  }

  static void resetContext(int handle) {
    try {
      bindings.cactusReset(Pointer.fromAddress(handle));
      debugLog('Context reset - cache cleared');
    } catch (e) {
      debugLog('Error resetting context: $e');
    }
  }

  static Future<CactusCompletionResult> completion(
    int handle,
    List<ChatMessage> messages,
    CactusCompletionParams params,
    int quantization,
  ) async {
    final jsonData = _prepareCompletionJson(messages, params);

    return await runInBackground(_completionInIsolate, {
      'handle': handle,
      'messagesJson': jsonData['messagesJson']!,
      'optionsJson': jsonData['optionsJson']!,
      'toolsJson': jsonData['toolsJson'],
      'bufferSize': max(params.maxTokens * quantization, 2048),
      'hasCallback': false,
      'replyPort': null,
    });
  }

  static CactusStreamedCompletionResult completionStream(
    int handle,
    List<ChatMessage> messages,
    CactusCompletionParams params,
    int quantization,
  ) {
    final jsonData = _prepareCompletionJson(messages, params);

    final controller = StreamController<String>();
    final resultCompleter = Completer<CactusCompletionResult>();
    final replyPort = ReceivePort();

    late StreamSubscription subscription;
    subscription = replyPort.listen((message) {
      if (message is Map) {
        final type = message['type'] as String;
        if (type == 'token') {
          final token = message['data'] as String;
          controller.add(token);
        } else if (type == 'result') {
          final result = message['data'] as CactusCompletionResult;
          resultCompleter.complete(result);
          controller.close();
          subscription.cancel();
          replyPort.close();
        } else if (type == 'error') {
          final error = message['data'];
          if (error is CactusCompletionResult) {
            resultCompleter.complete(error);
          } else {
            resultCompleter.completeError(error.toString());
          }
          controller.addError(error);
          controller.close();
          subscription.cancel();
          replyPort.close();
        }
      }
    });

    Isolate.spawn(_isolateCompletionEntry, {
      'handle': handle,
      'messagesJson': jsonData['messagesJson']!,
      'optionsJson': jsonData['optionsJson']!,
      'toolsJson': jsonData['toolsJson'],
      'bufferSize': max(params.maxTokens * quantization, 2048),
      'hasCallback': true,
      'replyPort': replyPort.sendPort,
    });

    return CactusStreamedCompletionResult(
      stream: controller.stream,
      result: resultCompleter.future,
    );
  }

  static Future<CactusEmbeddingResult> generateEmbedding(
    int handle,
    String text,
    int quantization,
  ) async {
    return await runInBackground(_generateEmbeddingInIsolate, {
      'handle': handle,
      'text': text,
      'bufferSize': max(text.length * quantization, 1024),
    });
  }

  static Future<CactusTranscriptionResult> transcribe(
    int handle,
    String prompt, {
    String? audioFilePath,
    List<int>? pcmData,
    CactusTranscriptionParams? params,
  }) async {
    final transcriptionParams = params ?? CactusTranscriptionParams();
    final optionsJson = '{"max_tokens":${transcriptionParams.maxTokens}}';

    return await runInBackground(_transcribeInIsolate, {
      'handle': handle,
      'audioFilePath': audioFilePath,
      'prompt': prompt,
      'optionsJson': optionsJson,
      'bufferSize': transcriptionParams.maxTokens * 8,
      'hasCallback': false,
      'replyPort': null,
      'pcmData': pcmData != null ? Uint8List.fromList(pcmData) : null,
    });
  }

  static CactusStreamedTranscriptionResult transcribeStream(
    int handle,
    String prompt, {
    String? audioFilePath,
    List<int>? pcmData,
    CactusTranscriptionParams? params,
  }) {
    final transcriptionParams = params ?? CactusTranscriptionParams();
    final optionsJson = '{"max_tokens":${transcriptionParams.maxTokens}}';

    final controller = StreamController<String>();
    final resultCompleter = Completer<CactusTranscriptionResult>();
    final replyPort = ReceivePort();

    late StreamSubscription subscription;
    subscription = replyPort.listen((message) {
      if (message is Map) {
        final type = message['type'] as String;
        if (type == 'token') {
          final token = message['data'] as String;
          if (!transcriptionParams.stopSequences.contains(token)) {
            controller.add(token);
          }
        } else if (type == 'result') {
          final result = message['data'] as CactusTranscriptionResult;
          resultCompleter.complete(result);
          controller.close();
          subscription.cancel();
          replyPort.close();
        } else if (type == 'error') {
          final error = message['data'];
          if (error is CactusTranscriptionResult) {
            resultCompleter.complete(error);
          } else {
            resultCompleter.completeError(error.toString());
          }
          controller.addError(error);
          controller.close();
          subscription.cancel();
          replyPort.close();
        }
      }
    });

    Isolate.spawn(_isolateTranscriptionEntry, {
      'handle': handle,
      'audioFilePath': audioFilePath,
      'prompt': prompt,
      'optionsJson': optionsJson,
      'bufferSize': transcriptionParams.maxTokens * 8,
      'hasCallback': true,
      'replyPort': replyPort.sendPort,
      'pcmData': pcmData != null ? Uint8List.fromList(pcmData) : null,
    });

    return CactusStreamedTranscriptionResult(
      stream: controller.stream,
      result: resultCompleter.future,
    );
  }

  static Future<void> _isolateCompletionEntry(
    Map<String, dynamic> params,
  ) async {
    final replyPort = params['replyPort'] as SendPort;
    try {
      final result = await _completionInIsolate(params);
      if (result.success) {
        replyPort.send({'type': 'result', 'data': result});
      } else {
        replyPort.send({'type': 'error', 'data': result});
      }
    } catch (e) {
      replyPort.send({'type': 'error', 'data': e.toString()});
    }
  }

  static Future<void> _isolateTranscriptionEntry(
    Map<String, dynamic> params,
  ) async {
    final replyPort = params['replyPort'] as SendPort;
    try {
      final result = await _transcribeInIsolate(params);
      if (result.success) {
        replyPort.send({'type': 'result', 'data': result});
      } else {
        replyPort.send({'type': 'error', 'data': result});
      }
    } catch (e) {
      replyPort.send({'type': 'error', 'data': e.toString()});
    }
  }
}
