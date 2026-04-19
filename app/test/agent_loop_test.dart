import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/agent_loop.dart';
import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/agent/memory.dart';
import 'package:syndai/agent/prompt_assembler.dart';
import 'package:syndai/agent/todos.dart';
import 'package:syndai/agent/tool_registry.dart';

import 'fake_cactus_engine.dart';

void main() {
  group('transcribe', () {
    test('rejects language diagnosis as non-transcript output', () async {
      final tmp = await Directory.systemTemp.createTemp('syndai_test_');
      final memory = await Memory.open(dir: tmp);
      final engine = FakeCactusEngine([])..nextRaw = 'The audio is in Tamil.';
      final loop = AgentLoop(
        engine: engine,
        todos: TodoStore(),
        memory: memory,
        tools: ToolRegistry(),
        assembler: PromptAssembler(
          todos: TodoStore(),
          readMemory: memory.readAll,
          toolResults: ToolResultStore(),
        ),
      );

      final transcript = await loop.transcribe(Uint8List.fromList([1, 2, 3]));

      expect(transcript, isNull);
      expect(
        engine.capturedMessages.single.single['content'],
        contains('Do not identify, guess, or name the spoken language'),
      );
      await tmp.delete(recursive: true);
    });

    test('strips language diagnosis prefix when spoken text follows', () {
      expect(
        normalizeTranscriptionOutput(
          'The audio is in Tamil: the checkout button is frozen',
        ),
        'the checkout button is frozen',
      );
    });

    test('parses wrapped response and removes transcript label', () {
      expect(
        normalizeTranscriptionOutput(
          '{"success":true,"response":"Transcript: checkout is broken"}',
        ),
        'checkout is broken',
      );
    });
  });

  test('5-turn loop: plan, 3 tool calls (with repeat), finish', () async {
    final tmp = await Directory.systemTemp.createTemp('syndai_test_');
    final memory = await Memory.open(dir: tmp);

    // Register a dummy MCP tool the loop can call.
    final todos = TodoStore();
    final tools = ToolRegistry();
    final assembler = PromptAssembler(
      todos: todos,
      readMemory: memory.readAll,
      toolResults: ToolResultStore(),
    );

    // Scripted responses:
    //   1) plan -> write_todos args
    //   2) step 1: echo_tool
    //   3) step 2: echo_tool (SAME args) -> appears in recent keys
    //   4) step 3: echo_tool (SAME args) -> triggers loop-guard, replan injected
    //   5) step 4: echo_tool (new args) -> executes normally
    //   6) step 5: finish
    final engine = FakeCactusEngine([
      {
        'todos': [
          {'id': 't1', 'content': 'do the thing', 'status': 'inProgress'},
        ],
      },
      {
        'name': 'echo_tool',
        'arguments': {'msg': 'a'},
      },
      {
        'name': 'echo_tool',
        'arguments': {'msg': 'a'},
      },
      {
        'name': 'echo_tool',
        'arguments': {'msg': 'a'},
      },
      {
        'name': 'echo_tool',
        'arguments': {'msg': 'b'},
      },
      {
        'name': 'finish',
        'arguments': {'summary': 'done'},
      },
    ]);

    final loop = AgentLoop(
      engine: engine,
      todos: todos,
      memory: memory,
      tools: tools,
      assembler: assembler,
    );

    tools.register(
      ToolSpec(
        name: 'echo_tool',
        description: 'echo',
        inputSchema: const {},
        executor: (args) async => {'echo': args},
      ),
    );

    final events = <AgentEvent>[];
    await for (final e in loop.run('Help me plan a trip to Paris next month')) {
      events.add(e);
    }

    // Must end with AgentFinished.
    expect(events.last, isA<AgentFinished>());
    expect((events.last as AgentFinished).summary, 'done');

    // TodoUpdate fired after plan.
    expect(events.whereType<AgentTodoUpdate>().isNotEmpty, isTrue);
    expect(todos.items.length, 1);
    expect(todos.items.first.id, 't1');

    // Tool calls in order — the loop-guard swallows the 3rd duplicate and
    // doesn't execute it, so we should see exactly: write_todos, echo (a),
    // echo (a), echo (b), finish. The first duplicate appears, the third
    // is swallowed as the guard trigger.
    final calls = events.whereType<AgentToolCall>().toList();
    final callNames = calls.map((c) => c.toolName).toList();
    expect(callNames.first, 'write_todos');
    expect(callNames.last, 'finish');
    expect(callNames.where((n) => n == 'echo_tool').length, 3);

    // Loop-guard actually fired: the third scripted echo with args {msg:a}
    // was consumed by the model call but NOT emitted as a tool call.
    // So total echo_tool emitted == 3, scripted == 4 (one was swallowed).
    // The scripted queue is fully drained => 6 responses consumed.
    expect(engine.jsonResponses.length, 6);

    await tmp.delete(recursive: true);
  });
}
