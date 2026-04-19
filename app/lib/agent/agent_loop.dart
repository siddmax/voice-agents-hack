import 'dart:async';
import 'dart:convert';

import '../cactus/engine.dart';
import 'agent_service.dart';
import 'compaction.dart';
import 'output_processor.dart' show validateArgsAgainstSchema;
import 'memory.dart';
import 'memory_tools.dart';
import 'prompt_assembler.dart';
import 'semantic_gate.dart';
import 'todos.dart';
import 'tool_registry.dart';

const _gateSkipTools = {
  'write_todos',
  'read_tool_result',
  'finish',
  'request_user_input',
};
final _memoryToolPattern = RegExp(r'^memory_');

class AgentLoop implements AgentService {
  final CactusEngine engine;
  final TodoStore todos;
  final Memory memory;
  final ToolRegistry tools;
  final PromptAssembler assembler;
  final MessageListCompactor? compactor;
  final int maxSteps;
  final SemanticGate _semanticGate;

  List<Map<String, dynamic>> _history = [];
  final List<String> _recentToolKeys = [];
  bool _cancelled = false;
  int _stepsSinceReminder = 0;
  String _latestUserInput = '';

  AgentLoop({
    required this.engine,
    required this.todos,
    required this.memory,
    required this.tools,
    required this.assembler,
    this.compactor,
    SemanticGate? semanticGate,
    // Lane A's 20-step eval showed Gemma 4 E4B INT4 degrades past ~turn 11
    // without set_tool_constraints. 10 leaves headroom for the plan phase.
    this.maxSteps = 10,
  }) : _semanticGate = semanticGate ?? SemanticGate() {
    _registerCoreTools();
    registerMemoryTools(tools, memory);
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

  int get gateTriggerCount => _semanticGate.triggerCount;

  @override
  Stream<AgentEvent> run(String userInput) async* {
    _cancelled = false;
    _latestUserInput = userInput;
    final bool isNewGoal = _history.isEmpty || _looksLikeNewGoal(userInput);
    _history.add({'role': 'user', 'content': userInput});

    await _maybeCompact();

    if (isNewGoal) {
      yield const AgentThinking(activeTodo: 'planning');
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

      await _maybeCompact();
      yield AgentThinking(activeTodo: todos.active?.content);
      final calls = await _nextCalls(reminder: reminder);
      if (calls.isEmpty) {
        yield const AgentFinished('Model returned no tool call.');
        await _logSession(userInput, 'no tool call');
        return;
      }

      // Gap 3: execute every function_call cactus parsed, not just the first.
      // Gemma 4 emits multi-call turns ("set timer AND text Alice") in one
      // wrapped response — silently dropping calls[1..] loses user intent.
      // Stop early on finish / request_user_input / loop-guard trip.
      var endRun = false;
      for (final rawCall in calls) {
        if (_cancelled) return;

        final extracted = _extractCall(rawCall);
        if (extracted == null) {
          _history.add({
            'role': 'system',
            'content':
                '[parse-guard] last response had no usable tool name. Reply with: {"name": "<tool>", "arguments": {...}}.',
          });
          continue;
        }
        final name = extracted.$1;
        final args = extracted.$2;

        // Gap 4: schema-validate args before executing. On fail, surface the
        // exact mismatch back to the model so the next turn can fix it.
        final schemaError = validateArgsAgainstSchema(
          toolName: name, args: args, tools: tools.toSchemas(),
        );
        if (schemaError != null) {
          _history.add({
            'role': 'system',
            'content':
                '[schema-guard] tool "$name" args invalid: $schemaError. Retry with corrected args.',
          });
          yield AgentError('schema: $name args invalid: $schemaError');
          continue;
        }

        final key = _canonicalKey(name, args);
        _recentToolKeys.add(key);
        if (_recentToolKeys.length > 5) _recentToolKeys.removeAt(0);
        if (_isStuckLoop()) {
          _history.add({
            'role': 'system',
            'content':
                '[loop-guard] the last 3 tool calls were identical. Replan: pick a different tool, mark the current todo completed, or call finish.',
          });
          _recentToolKeys.clear();
          break;
        }

        if (!_gateSkipTools.contains(name) &&
            !_memoryToolPattern.hasMatch(name)) {
          final availableToolNames = tools.all.map((t) => t.name).toList();
          if (!_semanticGate.check(
            toolName: name,
            query: _latestUserInput,
            availableTools: availableToolNames,
          )) {
            _history.add({
              'role': 'system',
              'content':
                  '[semantic-gate] "$name" does not seem to match the query. Pick a different tool or call finish.',
            });
            continue;
          }
        }

        yield AgentToolCall(name, args);
        final raw = await tools.call(name, args);
        final rawStr = jsonEncode(raw);
        final compact = assembler.compactToolResult(name, rawStr);
        final summary = compact['content'] as String;
        _history.add({'role': 'tool', 'name': name, 'content': summary});
        yield AgentToolResult(name, _shortSummary(summary));

        if (name == 'write_todos') yield AgentTodoUpdate(todos.items);
        if (name == 'finish') {
          final sum = (args['summary'] as String?) ?? '';
          yield AgentFinished(sum);
          await _logSession(userInput, 'finished: $sum');
          return;
        }
        if (name == 'request_user_input') {
          final q = (args['question'] as String?) ?? '';
          yield AgentToolResult('request_user_input', q);
          endRun = true;
          break;
        }
      }
      if (endRun) return;
    }

    yield const AgentFinished('Step limit reached.');
    await _logSession(userInput, 'step limit');
  }

  // ---- internals ----

  Future<void> _maybeCompact() async {
    final c = compactor;
    if (c == null) return;
    try {
      _history = await c.maybeCompact(_history);
    } catch (_) {
      // Never crash the caller on compactor failure.
    }
  }

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

  /// Returns ALL function calls cactus parsed for this turn. Retries once
  /// with a sharpening reminder if the first call comes back empty —
  /// gives the model a second chance with force_tools=true before the
  /// loop bails to AgentFinished.
  Future<List<Map<String, dynamic>>> _nextCalls({String? reminder}) async {
    Future<List<Map<String, dynamic>>> attempt(String? r) async {
      final messages = assembler.build(history: _history, reminder: r);
      try {
        return await engine.completeToolCalls(
          messages: messages,
          tools: tools.toSchemas(),
          forceTools: true,
        );
      } catch (_) {
        return const [];
      }
    }

    final first = await attempt(reminder);
    if (first.isNotEmpty) return first;

    // Gap 2: empty result on the first try means the constrainer either
    // didn't fire or the model emitted text only. Push the reminder
    // harder and try once more before giving up.
    return attempt(
      'You MUST emit a tool call this turn. Pick from the AVAILABLE TOOLS '
      'list above. Do not respond with text. Format: {"name": "<tool>", '
      '"arguments": {...}}.${reminder == null ? '' : ' $reminder'}',
    );
  }

  /// Pull (name, args) out of whatever shape the model emitted. Returns
  /// null if no recognizable tool name can be found.
  (String, Map<String, dynamic>)? _extractCall(Map<String, dynamic> raw) {
    Map<String, dynamic>? unwrap(Object? v) {
      if (v is Map) return v.cast<String, dynamic>();
      return null;
    }

    final candidates = <Map<String, dynamic>>[
      raw,
      if (unwrap(raw['tool_call']) != null) unwrap(raw['tool_call'])!,
      if (unwrap(raw['function']) != null) unwrap(raw['function'])!,
      if (unwrap(raw['call']) != null) unwrap(raw['call'])!,
    ];

    for (final c in candidates) {
      final name = c['name'] ?? c['tool'] ?? c['function_name'];
      if (name is String && name.trim().isNotEmpty) {
        final args = unwrap(c['arguments']) ??
            unwrap(c['args']) ??
            unwrap(c['parameters']) ??
            <String, dynamic>{};
        return (name, args);
      }
    }
    return null;
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
      await memory.append('Notes.md', line);
      await memory.refreshInjectedCache();
    } catch (_) {}
  }
}

TodoStatus _parseStatus(String s) => switch (s) {
      'inProgress' => TodoStatus.inProgress,
      'in_progress' => TodoStatus.inProgress,
      'completed' => TodoStatus.completed,
      _ => TodoStatus.pending,
    };
