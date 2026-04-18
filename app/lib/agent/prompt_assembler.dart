import 'dart:convert';

import 'todos.dart';

const _identity = '''
You are Syndai — an on-device voice cowork agent. You run locally on the user's
phone via Gemma 4 E4B on the Cactus runtime. You are honest, warm, concise.
You help the user make progress on real work by planning with a TODO ledger,
calling tools (local + any MCP servers the user has connected), and explaining
what you are doing in short spoken sentences. You do not invent tool results,
you do not pretend to have access you don't have, and you don't pad answers.
When a task is genuinely done, call the finish tool. If you need info from the
user, call request_user_input. Keep responses short — this is voice. Prefer
action over commentary.
''';

// Approx 4 chars per token. Used for memory truncation + tool-result preview.
int _approxTokens(String s) => (s.length / 4).ceil();

String _truncateMiddle(String s, int maxTokens) {
  if (_approxTokens(s) <= maxTokens) return s;
  final budget = maxTokens * 4;
  final half = (budget / 2).floor() - 20;
  if (half <= 0) return s.substring(0, budget);
  final head = s.substring(0, half);
  final tail = s.substring(s.length - half);
  return '$head\n... [truncated middle] ...\n$tail';
}

class ToolResultStore {
  final Map<String, String> _store = {};
  int _seq = 0;

  String put(String toolName, String full) {
    _seq += 1;
    final h = 'tr_${_seq.toString().padLeft(4, '0')}';
    _store[h] = full;
    return h;
  }

  String? get(String handle) => _store[handle];
}

class PromptAssembler {
  final TodoStore todos;
  final String Function() readMemory;
  final ToolResultStore toolResults;

  PromptAssembler({
    required this.todos,
    required this.readMemory,
    required this.toolResults,
  });

  String _buildSystem() {
    // Injected memory is now AGENT.md + INDEX.md + identity + prefs only.
    // Cap at 1500 tokens; the agent pulls detail via memory_view.
    final mem = _truncateMiddle(readMemory(), 1500);
    final ledger = todos.renderLedger();
    final active = todos.active;
    final goal = active == null
        ? ''
        : '\n\nCURRENT GOAL (stay focused on this): ${active.content}';
    return '''
$_identity

--- MEMORY ---
$mem

--- TODOS ---
$ledger$goal
''';
  }

  /// Replace large tool outputs with a handle + preview. Returns the
  /// rewritten message plus (if replaced) a handle. >500 tokens triggers.
  Map<String, dynamic> compactToolResult(String toolName, String full) {
    if (_approxTokens(full) <= 500) {
      return {'content': full, 'handle': null};
    }
    final handle = toolResults.put(toolName, full);
    final preview = full.length > 160 ? full.substring(0, 160) : full;
    final stub =
        '[tool_result: name=$toolName, handle=$handle, ~${full.length}chars, preview="${preview.replaceAll('\n', ' ')}"]';
    return {'content': stub, 'handle': handle};
  }

  /// Build the messages array for the model. `history` is the turn log
  /// in OpenAI-style ({role, content}). `reminder` is optional text to
  /// inject as a system-reminder turn (e.g. current goal every 3 steps).
  List<Map<String, dynamic>> build({
    required List<Map<String, dynamic>> history,
    String? reminder,
    int maxTurns = 10,
  }) {
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': _buildSystem()},
    ];
    final tail = history.length > maxTurns
        ? history.sublist(history.length - maxTurns)
        : history;
    out.addAll(tail);
    if (reminder != null && reminder.isNotEmpty) {
      out.add({'role': 'system', 'content': '[reminder] $reminder'});
    }
    return out;
  }

  String encode(Object o) => jsonEncode(o);
}
