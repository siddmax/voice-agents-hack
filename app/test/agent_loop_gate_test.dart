import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/agent_loop.dart';
import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/agent/memory.dart';
import 'package:syndai/agent/prompt_assembler.dart';
import 'package:syndai/agent/todos.dart';
import 'package:syndai/agent/tool_registry.dart';

import 'fake_cactus_engine.dart';

void main() {
  test(
    'semantic gate blocks wrong tool and loop still finishes',
    () async {
      final tmp = await Directory.systemTemp.createTemp('syndai_gate_test_');
      final memory = await Memory.open(dir: tmp);
      final todos = TodoStore();
      final tools = ToolRegistry();
      final assembler = PromptAssembler(
        todos: todos,
        readMemory: memory.readAll,
        toolResults: ToolResultStore(),
      );

      var setAlarmCalled = 0;
      var playMusicCalled = 0;

      // Scripted:
      //   1) plan -> todos list
      //   2) wrong tool: set_alarm (should be gated)
      //   3) correct tool: play_music (executes)
      //   4) finish
      final engine = FakeCactusEngine([
        {
          'todos': [
            {'id': 't1', 'content': 'play music', 'status': 'inProgress'},
          ],
        },
        {
          'name': 'set_alarm',
          'arguments': {'time': '07:00'},
        },
        {
          'name': 'play_music',
          'arguments': {'genre': 'jazz'},
        },
        {
          'name': 'finish',
          'arguments': {'summary': 'playing jazz'},
        },
      ]);

      final loop = AgentLoop(
        engine: engine,
        todos: todos,
        memory: memory,
        tools: tools,
        assembler: assembler,
      );

      tools.register(ToolSpec(
        name: 'set_alarm',
        description: 'set an alarm',
        inputSchema: const {},
        executor: (args) async {
          setAlarmCalled += 1;
          return {'ok': true};
        },
      ));
      tools.register(ToolSpec(
        name: 'play_music',
        description: 'play music',
        inputSchema: const {},
        executor: (args) async {
          playMusicCalled += 1;
          return {'ok': true};
        },
      ));

      final events = <AgentEvent>[];
      await for (final e in loop.run('please play some music for me')) {
        events.add(e);
      }

      // Gate triggered exactly once.
      // ignore: avoid_print
      print('gateTriggerCount=${loop.gateTriggerCount}');
      expect(loop.gateTriggerCount, 1);

      // set_alarm was NEVER executed.
      expect(setAlarmCalled, 0);
      // play_music was executed.
      expect(playMusicCalled, 1);

      // Loop eventually finished.
      expect(events.last, isA<AgentFinished>());
      expect((events.last as AgentFinished).summary, 'playing jazz');

      // No AgentToolCall for set_alarm was emitted.
      final toolCalls = events.whereType<AgentToolCall>().toList();
      expect(
        toolCalls.any((c) => c.toolName == 'set_alarm'),
        isFalse,
      );
      expect(
        toolCalls.any((c) => c.toolName == 'play_music'),
        isTrue,
      );

      await tmp.delete(recursive: true);
    },
  );
}
