import 'dart:async';
import 'dart:convert';
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

/// One-shot Isolate.run on every cactus_complete call broke after the first
/// because cactus's per-thread state (set up by cactusInit) doesn't survive
/// the worker isolate being spawned/torn-down per call. The fix is a
/// long-lived worker isolate that owns the model handle and serves
/// cactusInit + cactusComplete requests via SendPort.
class CactusEngine {
  final SendPort _requests;
  final ReceivePort _exit;
  final Isolate _worker;
  bool _closed = false;
  Future<void>? _pending;

  CactusEngine._(this._requests, this._exit, this._worker);

  static Future<CactusEngine> load(String modelPath) async {
    final ready = ReceivePort();
    final exit = ReceivePort();
    final worker = await Isolate.spawn<_BootMsg>(
      _workerMain,
      _BootMsg(ready.sendPort, modelPath),
      onExit: exit.sendPort,
      debugName: 'CactusEngineWorker',
    );

    final msg = await ready.first;
    ready.close();
    if (msg is _LoadOk) {
      return CactusEngine._(msg.requests, exit, worker);
    } else if (msg is _LoadErr) {
      worker.kill(priority: Isolate.immediate);
      exit.close();
      throw Exception('cactusInit failed: ${msg.error}');
    }
    worker.kill(priority: Isolate.immediate);
    exit.close();
    throw Exception('cactusInit returned unexpected message: $msg');
  }

  /// Plain text the model produced (the `response` field of cactus's
  /// wrapper, not the wrapper itself). Used by the compactor and any
  /// caller that just wants natural language back. Tool calls live in
  /// the wrapper's `function_calls` array — use [completeToolCall] or
  /// [completeJson] for those.
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    final raw = await completeRaw(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    final wrapper = _tryParseJson(raw);
    if (wrapper == null) return raw;
    final response = wrapper['response'];
    if (response is String) return response;
    return raw;
  }

  /// Returns cactus's raw response wrapper as a JSON string. Internal-ish:
  /// completeJson and completeToolCall use this; external callers usually
  /// want completeText / completeToolCall instead.
  Future<String> completeRaw({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    _checkOpen();
    // Serialize requests — cactus is single-threaded for inference and the
    // worker only handles one at a time.
    final prev = _pending;
    final completer = Completer<String>();
    _pending = completer.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {
        // Swallow — caller of the prior request already saw the error.
      }
    }
    try {
      final reply = ReceivePort();
      _requests.send(_CompleteReq(
        reply: reply.sendPort,
        messagesJson: jsonEncode(messages),
        optionsJson: jsonEncode({
          'temperature': temperature,
          'max_tokens': maxTokens,
          'top_p': 0.95,
        }),
        toolsJson: tools == null ? null : jsonEncode(tools),
      ));
      final res = await reply.first;
      reply.close();
      if (res is _CompleteOk) {
        completer.complete(res.text);
        return res.text;
      } else if (res is _CompleteErr) {
        final err = Exception('cactus_complete failed: ${res.error}');
        completer.completeError(err);
        throw err;
      } else {
        final err = Exception('cactus worker unexpected reply: $res');
        completer.completeError(err);
        throw err;
      }
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
      rethrow;
    }
  }

  /// Returns the first parsed function call from cactus's response wrapper
  /// in `{name, arguments}` shape, or null if the model produced text only.
  ///
  /// Cactus's response_buffer is always a wrapper:
  ///   { "success": true, "response": "<text>",
  ///     "function_calls": [{"name": "...", "arguments": {...}}, ...], ... }
  /// Cactus already parses Gemma 4's `<|tool_call>call:NAME{KV}<tool_call|>`
  /// DSL into that JSON shape internally. Reading `parsed['name']` at the
  /// top level (the old code) always returned null because the call lives
  /// nested inside `function_calls`.
  Future<Map<String, dynamic>?> completeToolCall({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
  }) async {
    final raw = await completeRaw(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    final wrapper = _tryParseJson(raw);
    if (wrapper == null) {
      if (looksLikeRefusal(raw)) {
        throw JsonRetryExhausted(raw, 'model refused', 1);
      }
      return null;
    }
    final calls = wrapper['function_calls'];
    if (calls is List && calls.isNotEmpty) {
      final first = calls.first;
      if (first is Map) {
        final call = first.cast<String, dynamic>();
        if (call['name'] is String && call['arguments'] is Map) {
          return OutputProcessor.process(
            call: call,
            tools: tools,
            query: query,
          );
        }
      }
    }
    // No tool call — model returned text. Caller decides what to do.
    return null;
  }

  /// Free-form JSON output (no tools forced). Used by the planner when we
  /// want a plain `{todos: [...]}` shape rather than a tool call.
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
      lastOutput = await completeRaw(
        messages: convo,
        tools: tools,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      final parsed = _tryParseJson(lastOutput);
      if (parsed != null) {
        // Cactus wrapper unwrap: prefer the first function_call when present.
        final calls = parsed['function_calls'];
        if (calls is List && calls.isNotEmpty) {
          final first = calls.first;
          if (first is Map) {
            final call = first.cast<String, dynamic>();
            if (tools != null &&
                call['name'] is String &&
                call['arguments'] is Map) {
              return OutputProcessor.process(
                call: call,
                tools: tools,
                query: query,
              );
            }
            return call;
          }
        }
        // No function_calls — try the response text as JSON (planner case).
        final inner = _tryParseJson((parsed['response'] as String?) ?? '');
        if (inner != null) return inner;
        return parsed;
      }

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
    _worker.kill(priority: Isolate.immediate);
    _exit.close();
  }

  void _checkOpen() {
    if (_closed) throw StateError('CactusEngine is closed');
  }
}

Map<String, dynamic>? _tryParseJson(String raw) => extractJsonObject(raw);

// ---------- worker isolate protocol ----------

class _BootMsg {
  final SendPort ready;
  final String modelPath;
  _BootMsg(this.ready, this.modelPath);
}

class _LoadOk {
  final SendPort requests;
  _LoadOk(this.requests);
}

class _LoadErr {
  final String error;
  _LoadErr(this.error);
}

class _CompleteReq {
  final SendPort reply;
  final String messagesJson;
  final String optionsJson;
  final String? toolsJson;
  _CompleteReq({
    required this.reply,
    required this.messagesJson,
    required this.optionsJson,
    required this.toolsJson,
  });
}

class _CompleteOk {
  final String text;
  _CompleteOk(this.text);
}

class _CompleteErr {
  final String error;
  _CompleteErr(this.error);
}

void _workerMain(_BootMsg boot) {
  CactusModelT? handle;
  try {
    handle = cactusInit(boot.modelPath, null, false);
  } catch (e) {
    boot.ready.send(_LoadErr(e.toString()));
    return;
  }
  final requests = ReceivePort();
  boot.ready.send(_LoadOk(requests.sendPort));

  requests.listen((msg) {
    if (msg is _CompleteReq) {
      try {
        final text = cactusComplete(
          handle!,
          msg.messagesJson,
          msg.optionsJson,
          msg.toolsJson,
          null,
        );
        msg.reply.send(_CompleteOk(text));
      } catch (e) {
        msg.reply.send(_CompleteErr(e.toString()));
      }
    }
  });
}
