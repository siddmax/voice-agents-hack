// Output processor for Gemma 4 tool-call JSON.
//
// Patterns ported from Rayhanpatel/functiongemma-hackathon (Cactus x DeepMind
// Feb 2026 hackathon submission, LocalHost Router, 80.9% score). The
// algorithms are re-implemented in Dart; no verbatim source was copied.
//
// The pipeline is the only structural safety net we have for JSON tool calls
// on Gemma 4 E4B INT4 — the Cactus C FFI does not expose GBNF constraints.
// It repairs common failure modes (misspelled tool names, bad int coercion,
// natural-language numbers in string args) before the JSON reaches the tool
// executor.

import 'dart:convert';

/// Iterative two-row DP Levenshtein edit distance. Fails gracefully on
/// empty strings.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final m = a.length;
  final n = b.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var curr = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      var min = del < ins ? del : ins;
      if (sub < min) min = sub;
      curr[j] = min;
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

/// Depth-tracking brace parser. Strips markdown code fences, scans for the
/// first `{`, tracks brace depth honoring quoted strings and escapes, and
/// returns the JSON object as `Map<String, dynamic>`. Returns null on total
/// failure.
Map<String, dynamic>? extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // Strip markdown code fences.
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) {
    text = fence.group(1)!.trim();
  }

  final start = text.indexOf('{');
  if (start == -1) {
    // Fallback: maybe the whole thing parses.
    try {
      final v = jsonDecode(text);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    return null;
  }

  var depth = 0;
  var inString = false;
  var escape = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch == r'\') {
      if (inString) escape = true;
      continue;
    }
    if (ch == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        final candidate = text.substring(start, i + 1);
        try {
          final v = jsonDecode(candidate);
          if (v is Map<String, dynamic>) return v;
        } catch (_) {
          return null;
        }
      }
    }
  }
  // Unterminated — try whole-text as last resort.
  try {
    final v = jsonDecode(text);
    if (v is Map<String, dynamic>) return v;
  } catch (_) {}
  return null;
}

/// Snap each call's `name` to the nearest valid tool name by Levenshtein,
/// if within [maxDistance]. Otherwise leave unchanged.
List<Map<String, dynamic>> fuzzyMatchNames(
  List<Map<String, dynamic>> calls,
  List<Map<String, dynamic>> tools, {
  int maxDistance = 4,
}) {
  if (tools.isEmpty) return calls;
  final toolNames = <String>[
    for (final t in tools)
      if (t['name'] is String) t['name'] as String,
  ];
  if (toolNames.isEmpty) return calls;
  final result = <Map<String, dynamic>>[];
  for (final call in calls) {
    final name = call['name'];
    if (name is! String || toolNames.contains(name)) {
      result.add(call);
      continue;
    }
    String? best;
    var bestDist = maxDistance + 1;
    for (final candidate in toolNames) {
      final d = levenshtein(name, candidate);
      if (d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }
    if (best != null && bestDist <= maxDistance) {
      result.add({...call, 'name': best});
    } else {
      result.add(call);
    }
  }
  return result;
}

Map<String, dynamic>? _findTool(
  List<Map<String, dynamic>> tools,
  String name,
) {
  for (final t in tools) {
    if (t['name'] == name) return t;
  }
  return null;
}

Map<String, dynamic>? _schemaProperties(Map<String, dynamic> tool) {
  final input = tool['inputSchema'] ?? tool['input_schema'] ?? tool['parameters'];
  if (input is Map && input['properties'] is Map) {
    return Map<String, dynamic>.from(input['properties'] as Map);
  }
  return null;
}

/// Coerce arg types according to each tool's input schema.
///  - integer fields: double -> int via toInt().
///  - integer fields where schema has `minimum: 0` (or omits negatives
///    explicitly via `exclusiveMinimum: -1`): abs() any negative.
///  - string fields with `enum`: snap to nearest enum value if Levenshtein <= 3.
List<Map<String, dynamic>> coerceTypes(
  List<Map<String, dynamic>> calls,
  List<Map<String, dynamic>> tools,
) {
  final result = <Map<String, dynamic>>[];
  for (final call in calls) {
    final name = call['name'];
    final args = call['arguments'];
    if (name is! String || args is! Map) {
      result.add(call);
      continue;
    }
    final tool = _findTool(tools, name);
    if (tool == null) {
      result.add(call);
      continue;
    }
    final props = _schemaProperties(tool);
    if (props == null) {
      result.add(call);
      continue;
    }
    final newArgs = Map<String, dynamic>.from(args);
    for (final entry in props.entries) {
      final key = entry.key;
      final spec = entry.value;
      if (spec is! Map) continue;
      if (!newArgs.containsKey(key)) continue;
      final type = spec['type'];
      final value = newArgs[key];
      if (type == 'integer' || type == 'int') {
        var coerced = value;
        if (coerced is double) coerced = coerced.toInt();
        if (coerced is String) {
          final parsed = int.tryParse(coerced);
          if (parsed != null) coerced = parsed;
        }
        if (coerced is int) {
          final minimum = spec['minimum'];
          final disallowsNeg = minimum is num && minimum >= 0;
          if (disallowsNeg && coerced < 0) {
            coerced = coerced.abs();
          }
        }
        newArgs[key] = coerced;
      } else if (type == 'string' && spec['enum'] is List) {
        final enumVals = <String>[
          for (final e in spec['enum'] as List)
            if (e is String) e,
        ];
        if (value is String && enumVals.isNotEmpty && !enumVals.contains(value)) {
          String? best;
          var bestDist = 4;
          for (final candidate in enumVals) {
            final d = levenshtein(value, candidate);
            if (d < bestDist) {
              bestDist = d;
              best = candidate;
            }
          }
          if (best != null && bestDist <= 3) {
            newArgs[key] = best;
          }
        }
      }
    }
    result.add({...call, 'arguments': newArgs});
  }
  return result;
}

final _trailingPunct = RegExp(r'[\.,!\?;:]+$');
final _leadingArticle = RegExp(r'^(?:the|a|an)\s+', caseSensitive: false);

/// For every string arg: trim, strip trailing `.,!?;:`, strip leading
/// `the /a /an ` (case-insensitive), strip surrounding matched quotes.
List<Map<String, dynamic>> cleanStringArgs(List<Map<String, dynamic>> calls) {
  final result = <Map<String, dynamic>>[];
  for (final call in calls) {
    final args = call['arguments'];
    if (args is! Map) {
      result.add(call);
      continue;
    }
    final newArgs = <String, dynamic>{};
    args.forEach((k, v) {
      if (v is String) {
        var s = v.trim();
        // Strip matched surrounding quotes.
        if (s.length >= 2) {
          final first = s[0];
          final last = s[s.length - 1];
          if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
            s = s.substring(1, s.length - 1).trim();
          }
        }
        s = s.replaceFirst(_trailingPunct, '');
        s = s.replaceFirst(_leadingArticle, '');
        s = s.trim();
        newArgs[k as String] = s;
      } else {
        newArgs[k as String] = v;
      }
    });
    result.add({...call, 'arguments': newArgs});
  }
  return result;
}

final _amPmRe = RegExp(r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)', caseSensitive: false);
final _minutesRe = RegExp(r'(\d+)\s*(?:minutes?|mins?)\b', caseSensitive: false);
final _hoursRe = RegExp(r'(\d+)\s*hours?\b', caseSensitive: false);
final _secondsRe = RegExp(r'(\d+)\s*(?:seconds?|secs?)\b', caseSensitive: false);

bool _isBadInt(dynamic v) {
  if (v == null) return true;
  if (v is int) return false;
  if (v is double) return false;
  return true; // strings, bools, etc. are suspicious
}

/// Schema-driven query extractor. For each call's tool schema, look for
/// integer parameters named hour/hours/minute/minutes/second/seconds. If
/// the arg is missing or clearly-wrong, regex-extract a value from [query].
/// Does NOT stomp valid model output.
List<Map<String, dynamic>> extractArgsFromQuery(
  List<Map<String, dynamic>> calls,
  String query,
  List<Map<String, dynamic>> tools,
) {
  if (query.isEmpty) return calls;
  final result = <Map<String, dynamic>>[];

  final amPm = _amPmRe.firstMatch(query);
  int? amPmHour;
  int? amPmMinute;
  if (amPm != null) {
    var h = int.tryParse(amPm.group(1) ?? '') ?? 0;
    final m = int.tryParse(amPm.group(2) ?? '') ?? 0;
    final period = (amPm.group(3) ?? '').toLowerCase();
    if (period == 'pm' && h < 12) h += 12;
    if (period == 'am' && h == 12) h = 0;
    amPmHour = h;
    amPmMinute = m;
  }
  final minutesMatch = _minutesRe.firstMatch(query);
  final hoursMatch = _hoursRe.firstMatch(query);
  final secondsMatch = _secondsRe.firstMatch(query);

  for (final call in calls) {
    final name = call['name'];
    final args = call['arguments'];
    if (name is! String || args is! Map) {
      result.add(call);
      continue;
    }
    final tool = _findTool(tools, name);
    if (tool == null) {
      result.add(call);
      continue;
    }
    final props = _schemaProperties(tool);
    if (props == null) {
      result.add(call);
      continue;
    }
    final newArgs = Map<String, dynamic>.from(args);

    void maybeSet(String key, int? value) {
      if (value == null) return;
      if (!props.containsKey(key)) return;
      final spec = props[key];
      if (spec is! Map) return;
      final t = spec['type'];
      if (t != 'integer' && t != 'int') return;
      final existing = newArgs[key];
      if (!newArgs.containsKey(key) || _isBadInt(existing)) {
        newArgs[key] = value;
      }
    }

    // AM/PM populates `hour` and `minute` (singular, per spec).
    maybeSet('hour', amPmHour);
    maybeSet('minute', amPmMinute);

    if (minutesMatch != null) {
      final v = int.tryParse(minutesMatch.group(1) ?? '');
      maybeSet('minutes', v);
    }
    if (hoursMatch != null) {
      final v = int.tryParse(hoursMatch.group(1) ?? '');
      maybeSet('hours', v);
    }
    if (secondsMatch != null) {
      final v = int.tryParse(secondsMatch.group(1) ?? '');
      maybeSet('seconds', v);
    }

    result.add({...call, 'arguments': newArgs});
  }
  return result;
}

final _refusalRe = RegExp(
  r"i cannot|i(?:\s+am|'m)\s+sorry|i apologize|which (?:song|artist|one)|could you please|let me know which",
  caseSensitive: false,
);

/// Detect common Gemma refusal / clarification phrasings. Returns false on
/// empty input.
bool looksLikeRefusal(String responseText) {
  if (responseText.isEmpty) return false;
  return _refusalRe.hasMatch(responseText);
}

/// Single-call pipeline entry. Runs fuzzyMatchNames -> coerceTypes ->
/// cleanStringArgs -> extractArgsFromQuery (if query) on one call wrapped
/// in a `calls: [call]` list. This is what `CactusEngine.completeJson` uses.
class OutputProcessor {
  static Map<String, dynamic> process({
    required Map<String, dynamic> call,
    required List<Map<String, dynamic>> tools,
    String? query,
  }) {
    var calls = <Map<String, dynamic>>[call];
    calls = fuzzyMatchNames(calls, tools);
    calls = coerceTypes(calls, tools);
    calls = cleanStringArgs(calls);
    if (query != null && query.isNotEmpty) {
      calls = extractArgsFromQuery(calls, query, tools);
    }
    return calls.first;
  }
}
