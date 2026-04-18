import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import '../agent/output_processor.dart';
import 'cactus.dart';

class JsonRetryExhausted implements Exception {
  final String lastOutput;
  final Object? parseError;
  final int attempts;
  JsonRetryExhausted(this.lastOutput, this.parseError, this.attempts);
  @override
  String toString() =>
      'JsonRetryExhausted(attempts=$attempts, error=$parseError, output=${_truncate(lastOutput, 200)})';
}

String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}...';

class CactusEngine {
  final CactusModelT _handle;
  bool _closed = false;

  CactusEngine._(this._handle);

  static Future<CactusEngine> load(String modelPath) async {
    // cactusInit memory-maps the weights (~8 GB for E4B) and does the model
    // graph setup — tens of seconds on a Mac, longer on iOS simulator.
    // Run it off the main isolate so the UI can render a loading state
    // instead of a frozen white screen.
    final handleAddr = await Isolate.run(() => _loadInIsolate(modelPath));
    return CactusEngine._(Pointer<Void>.fromAddress(handleAddr));
  }

  static int _loadInIsolate(String modelPath) {
    final handle = cactusInit(modelPath, null, false);
    return handle.address;
  }

  Stream<String> complete({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) {
    _checkOpen();
    final controller = StreamController<String>();
    final options = jsonEncode({
      'temperature': temperature,
      'max_tokens': maxTokens,
      'top_p': 0.95,
    });
    final messagesJson = jsonEncode(messages);
    final toolsJson = tools == null ? null : jsonEncode(tools);

    Future(() {
      try {
        cactusComplete(
          _handle,
          messagesJson,
          options,
          toolsJson,
          (token, _) {
            if (token.isNotEmpty) controller.add(token);
          },
        );
        controller.close();
      } catch (e, st) {
        controller.addError(e, st);
        controller.close();
      }
    });

    return controller.stream;
  }

  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    _checkOpen();
    // cactus_complete is a synchronous FFI call that holds the thread for the
    // full prefill+decode cycle (~seconds on a Mac, tens of seconds on iOS
    // simulator with the 4B model). Running it on the main isolate freezes
    // the UI. Hand it to a background isolate via Isolate.run and reconstruct
    // the model handle from its raw address — Pointer is sendable as int and
    // the cactus context is owned by us, accessed sequentially.
    final handleAddr = _handle.address;
    final messagesJson = jsonEncode(messages);
    final toolsJson = tools == null ? null : jsonEncode(tools);
    final optionsJson = jsonEncode({
      'temperature': temperature,
      'max_tokens': maxTokens,
      'top_p': 0.95,
    });
    return Isolate.run(() => _completeInIsolate(
          handleAddr,
          messagesJson,
          optionsJson,
          toolsJson,
        ));
  }

  static String _completeInIsolate(
    int handleAddr,
    String messagesJson,
    String optionsJson,
    String? toolsJson,
  ) {
    final handle = Pointer<Void>.fromAddress(handleAddr);
    return cactusComplete(handle, messagesJson, optionsJson, toolsJson, null);
  }

  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
  }) async {
    final convo = List<Map<String, dynamic>>.from(messages);
    String lastOutput = '';
    Object? lastErr;

    for (var attempt = 0; attempt <= retries; attempt++) {
      lastOutput = await completeText(
        messages: convo,
        tools: tools,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      final parsed = _tryParseJson(lastOutput);
      if (parsed != null) {
        // If it looks like a tool call and we have tools, run output processor.
        if (tools != null &&
            parsed['name'] is String &&
            parsed['arguments'] is Map) {
          return OutputProcessor.process(
            call: parsed,
            tools: tools,
            query: query,
          );
        }
        return parsed;
      }

      // Refusal detection: parse failed AND raw looks like a refusal -> stop.
      if (looksLikeRefusal(lastOutput)) {
        throw JsonRetryExhausted(
          lastOutput,
          'model refused',
          attempt + 1,
        );
      }

      lastErr = 'parse failed';
      if (attempt == retries) break;
      convo.add({'role': 'assistant', 'content': lastOutput});
      convo.add({
        'role': 'user',
        'content':
            'That was not valid JSON. Reply with ONLY a single JSON object matching this schema: ${jsonEncode(schema)}. No prose, no code fences, no commentary.',
      });
    }
    throw JsonRetryExhausted(lastOutput, lastErr, retries + 1);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cactusDestroy(_handle);
  }

  void _checkOpen() {
    if (_closed) throw StateError('CactusEngine is closed');
  }
}

Map<String, dynamic>? _tryParseJson(String raw) => extractJsonObject(raw);
