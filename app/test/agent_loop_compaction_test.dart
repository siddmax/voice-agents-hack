import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/agent_loop.dart';
import 'package:syndai/agent/compaction.dart';
import 'package:syndai/agent/memory.dart';
import 'package:syndai/agent/prompt_assembler.dart';
import 'package:syndai/agent/todos.dart';
import 'package:syndai/agent/tool_registry.dart';
import 'package:syndai/cactus/engine.dart';

/// Scripted engine where:
///  - completeJson rotates through a supplied script of JSON objects,
///  - completeText always returns a short summary string (used by compactor).
class _ScriptedEngine implements CactusEngine {
  final List<Map<String, dynamic>> jsonScript;
  int _i = 0;
  int completeTextCalls = 0;

  _ScriptedEngine(this.jsonScript);

  @override
  Stream<String> complete({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) =>
      const Stream.empty();

  @override
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    completeTextCalls += 1;
    return 'SUMMARY: elided prior conversation in brief.';
  }

  @override
  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    if (_i >= jsonScript.length) {
      throw StateError('ran out of scripted JSON');
    }
    return jsonScript[_i++];
  }

  @override
  void close() {}
}

void main() {
  test('compaction fires and keeps history under threshold across turns',
      () async {
    final tmp = await Directory.systemTemp.createTemp('syndai_compaction_');
    final memory = await Memory.open(dir: tmp);
    final todos = TodoStore();
    final tools = ToolRegistry();
    final assembler = PromptAssembler(
      todos: todos,
      readMemory: memory.readAll,
      toolResults: ToolResultStore(),
    );

    // Tool that returns a huge blob to bloat history quickly.
    tools.register(ToolSpec(
      name: 'big_blob',
      description: 'returns a big string',
      inputSchema: const {'type': 'object', 'properties': {}},
      // Keep under PromptAssembler's 500-token compaction (2000 chars) so the
      // tool result stays inline in _history and actually inflates it.
      executor: (args) async => {'blob': 'B' * 1500},
    ));

    // Build a long JSON script: plan -> repeated big_blob calls -> finish.
    // 15 simulated turns.
    final script = <Map<String, dynamic>>[
      {
        'todos': [
          {'id': 't1', 'content': 'gather data', 'status': 'inProgress'},
        ],
      },
    ];
    for (var i = 0; i < 13; i++) {
      script.add({
        'name': 'big_blob',
        'arguments': {'i': i},
      });
    }
    script.add({
      'name': 'finish',
      'arguments': {'summary': 'done'},
    });

    final engine = _ScriptedEngine(script);
    final compactor = MessageListCompactor(
      engine: engine,
      thresholdTokens: 2000, // force compaction early
    );
    final loop = AgentLoop(
      engine: engine,
      todos: todos,
      memory: memory,
      tools: tools,
      assembler: assembler,
      compactor: compactor,
      maxSteps: 15,
    );

    // Track token counts before/after each compaction via a tracking wrapper.
    final before = <int>[];
    final after = <int>[];
    final trackingCompactor = _TrackingCompactor(compactor, before, after);

    final loop2 = AgentLoop(
      engine: engine,
      todos: todos,
      memory: memory,
      tools: tools,
      assembler: assembler,
      compactor: trackingCompactor,
      maxSteps: 15,
    );
    expect(loop.maxSteps, 15); // keep reference for lint
    final events = <String>[];
    await for (final e in loop2.run('please do the big thing for me now')) {
      events.add(e.runtimeType.toString());
    }

    // At least one compaction should have fired.
    expect(engine.completeTextCalls, greaterThanOrEqualTo(1),
        reason: 'expected compactor to invoke engine.completeText at least once');

    // Print (stdout captured by flutter test) before/after for at least one
    // firing event.
    final firings = <int>[];
    for (var i = 0; i < before.length; i++) {
      if (after[i] < before[i]) firings.add(i);
    }
    expect(firings.isNotEmpty, isTrue,
        reason: 'no measurable compaction shrinkage observed');
    // ignore: avoid_print
    print(
        'Compaction firings: ${firings.length}; first: before=${before[firings.first]} tokens, after=${after[firings.first]} tokens');

    // After the run, history should be bounded: no post-compaction snapshot
    // exceeds ~ thresholdTokens + one large message of slack.
    for (final a in after) {
      expect(a, lessThan(compactor.thresholdTokens + 2000),
          reason: 'post-compaction snapshot exceeded budget: $a');
    }
  });
}

/// Wraps a real compactor but records token counts before/after each call.
class _TrackingCompactor implements MessageListCompactor {
  final MessageListCompactor inner;
  final List<int> before;
  final List<int> after;
  _TrackingCompactor(this.inner, this.before, this.after);

  @override
  CactusEngine get engine => inner.engine;
  @override
  int get thresholdTokens => inner.thresholdTokens;
  @override
  int get targetTokens => inner.targetTokens;

  @override
  Future<List<Map<String, dynamic>>> maybeCompact(
      List<Map<String, dynamic>> messages) async {
    final b = TokenCounter.estimate(jsonEncode(messages));
    final out = await inner.maybeCompact(messages);
    final a = TokenCounter.estimate(jsonEncode(out));
    before.add(b);
    after.add(a);
    return out;
  }
}
