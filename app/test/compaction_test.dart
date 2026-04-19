import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/compaction.dart';
import 'package:syndai/cactus/engine.dart';

/// Scripted engine whose completeText returns queued strings, or optionally
/// throws on demand.
class _ScriptedEngine implements CactusEngine {
  final List<String> textResponses;
  final bool throwOnText;
  final List<List<Map<String, dynamic>>> seenMessages = [];
  int _i = 0;

  _ScriptedEngine(this.textResponses, {this.throwOnText = false});

  @override
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    seenMessages.add(messages);
    if (throwOnText) {
      throw StateError('scripted failure');
    }
    if (_i >= textResponses.length) {
      return '';
    }
    return textResponses[_i++];
  }

  @override
  Future<String> completeRaw({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async => '{"success":true,"response":"","function_calls":[]}';

  @override
  Future<CactusResponse> completeRawWithMetadata({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async => CactusResponse(
        rawText: '{"success":true,"response":"","function_calls":[]}',
      );

  @override
  Future<Map<String, dynamic>?> completeToolCall({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
  }) async => null;

  @override
  Future<List<Map<String, dynamic>>> completeToolCalls({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
    void Function(int)? onTokenCount,
  }) async => const [];

  @override
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
    void Function(int)? onTokenCount,
  }) async =>
      {};

  @override
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
    void Function(int)? onTokenCount,
  }) async =>
      (<String, dynamic>{}, CactusResponse(rawText: '{}'));

  @override
  void close() {}
}

void main() {
  group('MessageListCompactor', () {
    test('under threshold -> noop (identity preserved)', () async {
      final engine = _ScriptedEngine(['SUMMARY']);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 1000);
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
      ];
      final out = await c.maybeCompact(msgs);
      expect(identical(out, msgs), isTrue);
      expect(engine.seenMessages, isEmpty);
    });

    test('over threshold -> summarizes head, preserves system + last 3',
        () async {
      final engine = _ScriptedEngine(['SUMMARY OF OLD STUFF']);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 50);
      final big = 'x' * 1000; // many tokens
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': big},
        {'role': 'assistant', 'content': big},
        {'role': 'user', 'content': big},
        {'role': 'assistant', 'content': big},
        {'role': 'user', 'content': 'tail-1'},
        {'role': 'assistant', 'content': 'tail-2'},
        {'role': 'user', 'content': 'tail-3'},
      ];
      final out = await c.maybeCompact(msgs);

      // system + synthetic + last 3
      expect(out.length, 5);
      expect(out.first['role'], 'system');
      expect(out.first['content'], 'sys');
      expect(out[1]['role'], 'assistant');
      expect(out[1]['content'], contains('[compacted]'));
      expect(out[1]['content'], contains('SUMMARY OF OLD STUFF'));
      expect(out[2]['content'], 'tail-1');
      expect(out[3]['content'], 'tail-2');
      expect(out[4]['content'], 'tail-3');

      // Verify completeText was called with the head slice.
      expect(engine.seenMessages.length, 1);
      final sent = engine.seenMessages.first;
      expect(sent.first['role'], 'system');
      expect(sent.first['content'], contains('Summarize'));
      expect(sent.last['role'], 'user');
    });

    test('extracts tr_NNNN handles into synthetic message', () async {
      final engine = _ScriptedEngine(['summary']);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 50);
      final big = 'x' * 800;
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': '$big handle tr_0001 mentioned'},
        {'role': 'tool', 'content': 'got tr_0042 back $big'},
        {'role': 'assistant', 'content': 'noted tr_0001 and tr_0042'},
        {'role': 'user', 'content': 'tail-1'},
        {'role': 'assistant', 'content': 'tail-2'},
        {'role': 'user', 'content': 'tail-3'},
      ];
      final out = await c.maybeCompact(msgs);
      final synthetic = out[1]['content'] as String;
      expect(synthetic, contains('Handles still valid:'));
      expect(synthetic, contains('tr_0001'));
      expect(synthetic, contains('tr_0042'));
    });

    test('system preserved at index 0; last 3 untouched', () async {
      final engine = _ScriptedEngine(['s']);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 50);
      final big = 'x' * 800;
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'SYSTEM_PROMPT'},
        {'role': 'user', 'content': big},
        {'role': 'assistant', 'content': big},
        {'role': 'user', 'content': big},
        {'role': 'user', 'content': 'LAST_3_A'},
        {'role': 'assistant', 'content': 'LAST_3_B'},
        {'role': 'user', 'content': 'LAST_3_C'},
      ];
      final out = await c.maybeCompact(msgs);
      expect(out.first['content'], 'SYSTEM_PROMPT');
      expect(out[out.length - 3]['content'], 'LAST_3_A');
      expect(out[out.length - 2]['content'], 'LAST_3_B');
      expect(out.last['content'], 'LAST_3_C');
    });

    test('messages newer than latest write_todos are untouched', () async {
      final engine = _ScriptedEngine(['s']);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 50);
      final big = 'x' * 800;
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': big},
        {'role': 'assistant', 'content': big},
        // write_todos tool result somewhere in the middle
        {'role': 'tool', 'name': 'write_todos', 'content': 'ok'},
        {'role': 'assistant', 'content': 'POST_TODOS_1'},
        {'role': 'user', 'content': 'POST_TODOS_2'},
        {'role': 'assistant', 'content': 'POST_TODOS_3'},
        {'role': 'user', 'content': 'POST_TODOS_4'},
      ];
      final out = await c.maybeCompact(msgs);
      // Everything at/after the write_todos index must be present intact.
      final contents = out.map((m) => m['content']).toList();
      expect(contents, contains('ok'));
      expect(contents, contains('POST_TODOS_1'));
      expect(contents, contains('POST_TODOS_2'));
      expect(contents, contains('POST_TODOS_3'));
      expect(contents, contains('POST_TODOS_4'));
      expect(out.first['content'], 'sys');
    });

    test('completeText throws -> graceful placeholder, no throw', () async {
      final engine = _ScriptedEngine([], throwOnText: true);
      final c = MessageListCompactor(engine: engine, thresholdTokens: 50);
      final big = 'x' * 800;
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': big},
        {'role': 'assistant', 'content': big},
        {'role': 'user', 'content': big},
        {'role': 'user', 'content': 'tail-1'},
        {'role': 'assistant', 'content': 'tail-2'},
        {'role': 'user', 'content': 'tail-3'},
      ];
      final out = await c.maybeCompact(msgs);
      expect(out.first['content'], 'sys');
      expect(out[1]['role'], 'assistant');
      expect(out[1]['content'], contains('[compacted: elided'));
      expect(out.last['content'], 'tail-3');
    });
  });
}
