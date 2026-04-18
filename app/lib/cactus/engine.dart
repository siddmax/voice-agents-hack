import 'dart:async';
import 'dart:convert';

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
    final handle = cactusInit(modelPath, null, false);
    return CactusEngine._(handle);
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
    final buf = StringBuffer();
    await for (final t in complete(
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      temperature: temperature,
    )) {
      buf.write(t);
    }
    return buf.toString();
  }

  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
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
      if (parsed != null) return parsed;

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

Map<String, dynamic>? _tryParseJson(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final candidates = <String>[text];
  final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fenced != null) candidates.add(fenced.group(1)!.trim());
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start != -1 && end > start) {
    candidates.add(text.substring(start, end + 1));
  }
  for (final c in candidates) {
    try {
      final v = jsonDecode(c);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
  }
  return null;
}
