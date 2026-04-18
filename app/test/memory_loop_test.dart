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
  test('loop wires memory tools: create, append, view round-trip', () async {
    final tmp = await Directory.systemTemp.createTemp('syndai_mloop_');
    final memory = await Memory.open(
      dir: tmp,
      loadBootstrap: (p) async => '# seed $p\n',
    );
    final todos = TodoStore();
    final tools = ToolRegistry();
    final assembler = PromptAssembler(
      todos: todos,
      readMemory: memory.readAll,
      toolResults: ToolResultStore(),
    );

    final engine = FakeCactusEngine([
      {
        'todos': [
          {'id': 't1', 'content': 'note down prefs', 'status': 'inProgress'},
        ],
      },
      {
        'name': 'memory_create',
        'arguments': {'path': 'scratch.md', 'content': 'hello world'},
      },
      {
        'name': 'memory_append',
        'arguments': {'path': 'scratch.md', 'content': 'line two'},
      },
      {
        'name': 'memory_view',
        'arguments': {'path': 'scratch.md'},
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

    final events = <AgentEvent>[];
    await for (final e in loop.run('Help me remember something new')) {
      events.add(e);
    }

    expect(events.last, isA<AgentFinished>());
    final f = File('${memory.root.path}/scratch.md');
    expect(await f.readAsString(), contains('hello world'));
    expect(await f.readAsString(), contains('line two'));

    await tmp.delete(recursive: true);
  });
}
