import 'dart:convert';

import 'tool_registry.dart';
import 'todos.dart';

// Welfare framing throughout — directive language ("you MUST") gets ignored
// by small models surprisingly often; user-impact language ("if you skip this,
// the user loses X") taps RLHF training and lands more reliably. See
// the empirical write-up at https://www.reddit.com/r/ClaudeAI/ on hook
// directives, and the Control Illusion paper (arXiv 2502, Feb 2025) showing
// instruction-hierarchy compliance ≈47.5% even on frontier models.
const _identity = '''
You are Syndai — the user's on-device voice cowork agent. You run locally on
their phone (Gemma 4 on the Cactus runtime). The user trusts you with real
work and is listening for a short spoken reply, so:

- Be honest, warm, concise. Padding wastes their time and battery.
- Call tools to make progress. Inventing tool results breaks their trust and
  the rest of the run depends on the result being real.
- When the task is genuinely done, call the finish tool — otherwise the user
  is left waiting on an orb that never resolves.
- When you need info only the user has, call request_user_input — otherwise
  you'll guess wrong and ship the wrong action.
- Keep replies short. This is voice; long answers are painful to listen to.
- Prefer action over commentary. The user opened the app to get something
  done, not to chat.
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
  final ToolRegistry? toolRegistry;

  PromptAssembler({
    required this.todos,
    required this.readMemory,
    required this.toolResults,
    this.toolRegistry,
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

--- OUTPUT FORMAT ---
Every reply needs to be one JSON object that parses cleanly:
  {"name": "<tool_name>", "arguments": {<args>}}

If you reply with prose, code fences, or a wrapper like {"function": {...}}
or {"tool_call": {...}}, the user's tap silently does nothing — their
intended action is lost. The runtime can only execute what it can parse.

Pick the tool name from the AVAILABLE TOOLS list. A name not in the list
fails silently for the same reason.

Example: {"name": "finish", "arguments": {"summary": "Done."}}

--- AVAILABLE TOOLS (passive context — always loaded) ---
${_renderToolList()}

--- MEMORY ---
$mem

--- TODOS ---
$ledger$goal
''';
  }

  // Tool list as passive context, AGENTS.md style: name + one-line purpose +
  // required arg names. Compressed enough to live in every turn's prompt
  // (~50 tokens per tool). Full input schemas still travel to cactus via
  // toolsJson — this is the human-readable index the model selects from.
  // Empirically (Vercel Next.js docs eval, Jan 2026) AGENTS.md-style passive
  // context outperforms on-demand skill retrieval because there's no
  // decision point about whether to look something up.
  String _renderToolList() {
    final reg = toolRegistry;
    if (reg == null) return '(tool list unavailable — pick from the tools the host passed.)';
    final tools = reg.all;
    if (tools.isEmpty) return '(no tools registered.)';
    return tools.map((t) {
      final desc = t.description.length > 100
          ? '${t.description.substring(0, 100)}…'
          : t.description;
      final required = _requiredArgNames(t.inputSchema);
      final reqStr = required.isEmpty ? '' : ' · args: ${required.join(", ")}';
      return '- ${t.name}: $desc$reqStr';
    }).join('\n');
  }

  List<String> _requiredArgNames(Map<String, dynamic> schema) {
    final r = schema['required'];
    if (r is! List) return const [];
    return r.whereType<String>().toList();
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
