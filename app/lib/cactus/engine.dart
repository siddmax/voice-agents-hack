import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../agent/output_processor.dart';
import 'cactus.dart';

class CactusResponse {
  final String rawText;
  final double? confidence;
  final bool cloudHandoff;
  final String? thinking;
  final double? timeToFirstTokenMs;
  final double? decodeTps;
  final double? ramUsageMb;

  CactusResponse({
    required this.rawText,
    this.confidence,
    this.cloudHandoff = false,
    this.thinking,
    this.timeToFirstTokenMs,
    this.decodeTps,
    this.ramUsageMb,
  });

  factory CactusResponse.fromRaw(String raw) {
    final parsed = extractJsonObject(raw);
    if (parsed == null) return CactusResponse(rawText: raw);
    return CactusResponse(
      rawText: raw,
      confidence: (parsed['confidence'] as num?)?.toDouble(),
      cloudHandoff: parsed['cloud_handoff'] == true,
      thinking: parsed['thinking'] as String?,
      timeToFirstTokenMs:
          (parsed['time_to_first_token_ms'] as num?)?.toDouble(),
      decodeTps: (parsed['decode_tps'] as num?)?.toDouble(),
      ramUsageMb: (parsed['ram_usage_mb'] as num?)?.toDouble(),
    );
  }
}

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

/// Long-lived worker isolate owns the cactus model handle; main isolate
/// serializes requests to it over SendPort. Per-call Isolate.run used to
/// fail after the first call because cactus's per-thread state (RNG,
/// sampler, pthreads) doesn't survive an isolate tear-down.
class CactusEngine {
  final SendPort _requests;
  final ReceivePort _exit;
  final Isolate _worker;
  bool _closed = false;
  String? _closedReason;
  Future<void>? _pending;
  // Pending per-call completers keyed by reply port hash — so if the
  // worker dies we can fail each in-flight request with a real error
  // instead of leaving the caller hanging forever.
  final List<Completer<Object>> _pendingReplies = [];

  CactusEngine._(this._requests, this._exit, this._worker) {
    // If the worker exits unexpectedly, mark the engine dead and fail
    // every pending request. Without this, _requests.send still succeeds
    // (port still open) but no reply ever comes back.
    _exit.listen((_) {
      if (_closed) return;
      _closed = true;
      _closedReason ??= 'cactus worker isolate exited unexpectedly';
      for (final c in _pendingReplies) {
        if (!c.isCompleted) c.completeError(Exception(_closedReason!));
      }
      _pendingReplies.clear();
    });
  }

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

  /// Raw cactus response wrapper JSON. [onTokenCount] fires on the main
  /// isolate each time the worker emits a token — callers use it to drive
  /// progress UI without trying to stream raw Gemma DSL tokens (which
  /// would look like gibberish to the user).
  Future<String> completeRaw({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int tokenCount)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final result = await completeRawWithMetadata(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
      forceTools: forceTools,
      enableThinking: enableThinking,
      pcmData: pcmData,
      onTokenCount: onTokenCount,
      timeout: timeout,
    );
    return result.rawText;
  }

  Future<CactusResponse> completeRawWithMetadata({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int tokenCount)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    _checkOpen();
    final prev = _pending;
    final completer = Completer<String>();
    _pending = completer.future;
    if (prev != null) {
      try { await prev; } catch (_) {}
    }

    final reply = ReceivePort();
    ReceivePort? tokenPort;
    if (onTokenCount != null) {
      tokenPort = ReceivePort();
      var count = 0;
      tokenPort.listen((_) {
        count += 1;
        try { onTokenCount(count); } catch (_) {}
      });
    }

    final replyCompleter = Completer<Object>();
    _pendingReplies.add(replyCompleter);
    reply.listen((msg) {
      if (!replyCompleter.isCompleted) replyCompleter.complete(msg);
    });

    try {
      _requests.send(_CompleteReq(
        reply: reply.sendPort,
        tokens: tokenPort?.sendPort,
        messagesJson: jsonEncode(messages),
        optionsJson: jsonEncode({
          'temperature': temperature,
          'max_tokens': maxTokens,
          'top_p': 0.95,
          if (forceTools) 'force_tools': true,
          if (enableThinking) 'enable_thinking_if_supported': true,
        }),
        toolsJson: tools == null ? null : jsonEncode(tools),
        pcmData: pcmData,
      ));
      final res = await replyCompleter.future.timeout(
        timeout,
        onTimeout: () =>
            throw Exception('cactus_complete timed out after ${timeout.inSeconds}s'),
      );
      if (res is _CompleteOk) {
        completer.complete(res.text);
        return CactusResponse.fromRaw(res.text);
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
    } finally {
      _pendingReplies.remove(replyCompleter);
      reply.close();
      tokenPort?.close();
    }
  }

  /// Returns ALL parsed function calls in cactus's response wrapper, in
  /// order, each in canonical {name, arguments} shape with OutputProcessor
  /// already applied. Empty list if the model produced text only.
  Future<List<Map<String, dynamic>>> completeToolCalls({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
    void Function(int tokenCount)? onTokenCount,
  }) async {
    final raw = await completeRaw(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
      forceTools: forceTools,
      onTokenCount: onTokenCount,
    );
    final wrapper = _tryParseJson(raw);
    if (wrapper == null) {
      if (looksLikeRefusal(raw)) {
        throw JsonRetryExhausted(raw, 'model refused', 1);
      }
      return const [];
    }
    final calls = wrapper['function_calls'];
    if (calls is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final c in calls) {
      if (c is! Map) continue;
      final call = c.cast<String, dynamic>();
      if (call['name'] is String && call['arguments'] is Map) {
        out.add(OutputProcessor.process(
          call: call,
          tools: tools,
          query: query,
        ));
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> completeToolCall({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
  }) async {
    final calls = await completeToolCalls(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
      query: query,
      forceTools: forceTools,
    );
    return calls.isEmpty ? null : calls.first;
  }

  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int tokenCount)? onTokenCount,
  }) async {
    return (await completeJsonWithMetadata(
      messages: messages,
      tools: tools,
      schema: schema,
      retries: retries,
      maxTokens: maxTokens,
      temperature: temperature,
      query: query,
      enableThinking: enableThinking,
      pcmData: pcmData,
      onTokenCount: onTokenCount,
    )).$1;
  }

  Future<(Map<String, dynamic>, CactusResponse)> completeJsonWithMetadata({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int tokenCount)? onTokenCount,
  }) async {
    final convo = List<Map<String, dynamic>>.from(messages);
    String lastOutput = '';
    Object? lastErr;
    CactusResponse? lastMeta;

    for (var attempt = 0; attempt <= retries; attempt++) {
      final meta = await completeRawWithMetadata(
        messages: convo,
        tools: tools,
        maxTokens: maxTokens,
        temperature: temperature,
        enableThinking: enableThinking,
        pcmData: attempt == 0 ? pcmData : null,
        onTokenCount: onTokenCount,
      );
      lastOutput = meta.rawText;
      lastMeta = meta;
      final parsed = _tryParseJson(lastOutput);
      if (parsed != null) {
        final calls = parsed['function_calls'];
        if (calls is List && calls.isNotEmpty) {
          final first = calls.first;
          if (first is Map) {
            final call = first.cast<String, dynamic>();
            if (tools != null &&
                call['name'] is String &&
                call['arguments'] is Map) {
              return (OutputProcessor.process(
                call: call,
                tools: tools,
                query: query,
              ), lastMeta!);
            }
            return (call, lastMeta!);
          }
        }
        final inner = _tryParseJson((parsed['response'] as String?) ?? '');
        if (inner != null) return (inner, lastMeta!);
        return (parsed, lastMeta!);
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
    _closedReason ??= 'engine closed';
    _worker.kill(priority: Isolate.immediate);
    _exit.close();
    for (final c in _pendingReplies) {
      if (!c.isCompleted) c.completeError(Exception(_closedReason!));
    }
    _pendingReplies.clear();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError(_closedReason ?? 'CactusEngine is closed');
    }
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
  final SendPort? tokens;
  final String messagesJson;
  final String optionsJson;
  final String? toolsJson;
  final Uint8List? pcmData;
  _CompleteReq({
    required this.reply,
    required this.tokens,
    required this.messagesJson,
    required this.optionsJson,
    required this.toolsJson,
    this.pcmData,
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
        final tokens = msg.tokens;
        final text = cactusComplete(
          handle!,
          msg.messagesJson,
          msg.optionsJson,
          msg.toolsJson,
          tokens == null ? null : (_, __) => tokens.send(1),
          pcmData: msg.pcmData,
        );
        msg.reply.send(_CompleteOk(text));
      } catch (e) {
        msg.reply.send(_CompleteErr(e.toString()));
      }
    }
  });
}
