import 'dart:async';
import 'dart:convert';

import '../cactus/engine.dart';
import 'agent_service.dart';
import 'memory.dart';
import 'prompt_assembler.dart';
import 'todos.dart';
import 'tool_registry.dart';

class AgentLoop implements AgentService {
  final CactusEngine engine;
  final TodoStore todos;
  final Memory memory;
  final ToolRegistry tools;
  final PromptAssembler assembler;
  final int maxSteps;

  final List<Map<String, dynamic>> _history = [];
  final List<String> _recentToolKeys = [];
  bool _cancelled = false;
  int _stepsSinceReminder = 0;

  AgentLoop({
    required this.engine,
    required this.todos,
    required this.memory,
    required this.tools,
    required this.assembler,
    // Lane A's 20-step eval showed Gemma 4 E4B INT4 degrades past ~turn 11
    // without set_tool_constraints. 10 leaves headroom for the plan phase.
    this.maxSteps = 10,
  }) {
    _registerCoreTools();
  }

  void _registerCoreTools() {
    tools.register(ToolSpec(
      name: 'write_todos',
      description:
          'Replace the TODO ledger. Provide a full list of todos with id (t1,t2,...), content, status.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'todos': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'content': {'type': 'string'},
                'status': {
                  'type': 'string',
                  'enum': ['pending', 'inProgress', 'completed'],
                },
                'notes': {'type': 'string'},
              },
              'required': ['id', 'content', 'status'],
            },
          },
        },
        'required': ['todos'],
      },
      executor: (args) async {
        final list = (args['todos'] as List).cast<Map>();
        final parsed = list
            .map((m) => TodoItem(
                  m['id'] as String,
                  m['content'] as String,
                  _parseStatus(m['status'] as String),
                ))
            .toList();
        todos.replaceAll(parsed);
        return {'ok': true, 'count': parsed.length};
      },
    ));

    tools.register(ToolSpec(
      name: 'read_tool_result',
      description:
          'Re-fetch a previously truncated tool result by its handle (tr_NNNN).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'handle': {'type': 'string'},
        },
        'required': ['handle'],
      },
      executor: (args) async {
        final handle = args['handle'] as String;
        final v = assembler.toolResults.get(handle);
        return v == null
            ? {'error': 'unknown_handle', 'handle': handle}
            : {'content': v};
      },
    ));

    tools.register(ToolSpec(
      name: 'finish',
      description:
          'Call when the user\'s goal is complete. Provide a short spoken summary.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string'},
        },
        'required': ['summary'],
      },
      executor: (args) async => {'ok': true, 'summary': args['summary']},
    ));

    tools.register(ToolSpec(
      name: 'request_user_input',
      description:
          'Ask the user a clarifying question. The run pauses until the user replies.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
        },
        'required': ['question'],
      },
      executor: (args) async => {'ok': true, 'question': args['question']},
    ));
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  @override
  Stream<AgentEvent> run(String userInput) async* {
    _cancelled = false;
    final bool isNewGoal = _history.isEmpty || _looksLikeNewGoal(userInput);
    _history.add({'role': 'user', 'content': userInput});

    if (isNewGoal) {
      final plan = await _plan(userInput);
      if (plan != null) {
        yield AgentToolCall('write_todos', plan);
        await tools.call('write_todos', plan);
        yield AgentTodoUpdate(todos.items);
      }
    }

    for (var step = 0; step < maxSteps; step++) {
      if (_cancelled) return;

      if (todos.allDone) {
        yield const AgentFinished('All todos complete.');
        await _logSession(userInput, 'all todos complete');
        return;
      }

      _stepsSinceReminder += 1;
      String? reminder;
      if (_stepsSinceReminder >= 3 && todos.active != null) {
        reminder = 'current goal: ${todos.active!.content}';
        _stepsSinceReminder = 0;
      }

      final call = await _nextCall(reminder: reminder);
      if (call == null) {
        yield const AgentFinished('Model returned no tool call.');
        await _logSession(userInput, 'no tool call');
        return;
      }
      final name = call['name'] as String;
      final args = (call['arguments'] as Map?)?.cast<String, dynamic>() ?? {};

      final key = _canonicalKey(name, args);
      _recentToolKeys.add(key);
      if (_recentToolKeys.length > 5) {
        _recentToolKeys.removeAt(0);
      }
      if (_isStuckLoop()) {
        _history.add({
          'role': 'system',
          'content':
              '[loop-guard] the last 3 tool calls were identical. Replan: either pick a different tool, mark the current todo completed, or call finish.',
        });
        _recentToolKeys.clear();
        continue;
      }

      yield AgentToolCall(name, args);
      final raw = await tools.call(name, args);
      final rawStr = jsonEncode(raw);
      final compact = assembler.compactToolResult(name, rawStr);
      final summary = compact['content'] as String;
      _history.add({
        'role': 'tool',
        'name': name,
        'content': summary,
      });
      yield AgentToolResult(name, _shortSummary(summary));

      if (name == 'write_todos') {
        yield AgentTodoUpdate(todos.items);
      }
      if (name == 'finish') {
        final sum = (args['summary'] as String?) ?? '';
        yield AgentFinished(sum);
        await _logSession(userInput, 'finished: $sum');
        return;
      }
      if (name == 'request_user_input') {
        final q = (args['question'] as String?) ?? '';
        yield AgentToolResult('request_user_input', q);
        return;
      }
    }

    yield const AgentFinished('Step limit reached.');
    await _logSession(userInput, 'step limit');
  }

  // ---- internals ----

  bool _looksLikeNewGoal(String input) {
    final t = input.trim();
    if (t.length < 8) return false;
    final lower = t.toLowerCase();
    return lower.startsWith('help me') ||
        lower.startsWith('i want to') ||
        lower.startsWith('i need to') ||
        lower.startsWith('can you') ||
        lower.startsWith('let\'s') ||
        lower.startsWith('plan ') ||
        t.split(' ').length > 6;
  }

  Future<Map<String, dynamic>?> _plan(String userInput) async {
    final schema = {
      'type': 'object',
      'properties': {
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'content': {'type': 'string'},
              'status': {
                'type': 'string',
                'enum': ['pending', 'inProgress', 'completed'],
              },
            },
            'required': ['id', 'content', 'status'],
          },
        },
      },
      'required': ['todos'],
    };
    final messages = assembler.build(history: _history, reminder: 'plan phase: return write_todos args (a todos list) for this user request.');
    try {
      return await engine.completeJson(
        messages: messages,
        schema: schema,
        retries: 2,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _nextCall({String? reminder}) async {
    final schema = {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'arguments': {'type': 'object'},
      },
      'required': ['name', 'arguments'],
    };
    final messages = assembler.build(history: _history, reminder: reminder);
    try {
      final json = await engine.completeJson(
        messages: messages,
        tools: tools.toSchemas(),
        schema: schema,
        retries: 2,
      );
      return json;
    } catch (_) {
      return null;
    }
  }

  String _canonicalKey(String name, Map<String, dynamic> args) {
    final sorted = Map.fromEntries(
        args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return '$name:${jsonEncode(sorted)}';
  }

  bool _isStuckLoop() {
    if (_recentToolKeys.length < 3) return false;
    final last3 = _recentToolKeys.sublist(_recentToolKeys.length - 3);
    return last3.every((k) => k == last3.first);
  }

  String _shortSummary(String s) =>
      s.length > 120 ? '${s.substring(0, 120)}...' : s;

  Future<void> _logSession(String userInput, String outcome) async {
    if (_cancelled) return;
    final line =
        '- ${DateTime.now().toIso8601String()} :: "${userInput.trim()}" -> $outcome';
    try {
      await memory.append('Notes', line);
    } catch (_) {}
  }
}

TodoStatus _parseStatus(String s) => switch (s) {
      'inProgress' => TodoStatus.inProgress,
      'in_progress' => TodoStatus.inProgress,
      'completed' => TodoStatus.completed,
      _ => TodoStatus.pending,
    };
