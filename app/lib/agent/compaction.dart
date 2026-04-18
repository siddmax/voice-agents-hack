import 'dart:convert';

import '../cactus/engine.dart';

/// Rough token proxy: chars / 4, rounded up. Adequate for budget decisions;
/// do NOT use for billing or hard limits.
class TokenCounter {
  static int estimate(String s) => (s.length / 4).ceil();

  /// Total estimated tokens across a serialized message list.
  static int estimateMessages(List<Map<String, dynamic>> messages) {
    final encoded = jsonEncode(messages);
    return estimate(encoded);
  }
}

/// Compacts a running message history by summarizing the oldest half
/// into a single synthetic assistant message when the list exceeds
/// [thresholdTokens]. Preserves `tr_NNNN` tool-result handles.
class MessageListCompactor {
  final CactusEngine engine;
  final int thresholdTokens;
  final int targetTokens;

  MessageListCompactor({
    required this.engine,
    this.thresholdTokens = 8000,
    this.targetTokens = 4000,
  });

  static final RegExp _handleRe = RegExp(r'tr_\d+');

  static const _summarizeSystem =
      'Summarize this conversation in 300 tokens or fewer. '
      'Preserve every decision made and every tool-result handle mentioned '
      '(handles look like `tr_1234`). Output plain prose, no bullet points, '
      'no preamble.';

  /// Returns the (possibly compacted) message list. If the input is under
  /// threshold, the same reference is returned (identity-preserving).
  Future<List<Map<String, dynamic>>> maybeCompact(
      List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return messages;
    final total = TokenCounter.estimateMessages(messages);
    if (total <= thresholdTokens) return messages;

    // Identify system prefix (if messages[0] is system).
    final bool hasSystem =
        messages.first['role'] == 'system';
    final int systemEnd = hasSystem ? 1 : 0;

    // Protected tail start: min(last3-boundary, latest-write_todos-boundary).
    final int n = messages.length;
    int tailStart = n - 3;
    if (tailStart < systemEnd) tailStart = systemEnd;

    // Every message newer than the most recent write_todos tool call is
    // protected. Find the latest index where role==tool and name==write_todos,
    // or where the content mentions a write_todos invocation.
    int latestWriteTodos = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m['role'] == 'tool' && m['name'] == 'write_todos') {
        latestWriteTodos = i;
        break;
      }
    }
    if (latestWriteTodos >= 0) {
      // Everything AFTER the write_todos call is protected; include the call
      // itself in the protected tail to keep ledger coherent.
      final int writeTodosBoundary = latestWriteTodos;
      if (writeTodosBoundary < tailStart) tailStart = writeTodosBoundary;
    }

    if (tailStart <= systemEnd) {
      // Nothing compactable between system and tail.
      return messages;
    }

    final head = messages.sublist(systemEnd, tailStart);
    final tail = messages.sublist(tailStart);
    final systemMsgs =
        hasSystem ? [messages.first] : <Map<String, dynamic>>[];

    // Extract handles from the compactable head.
    final headText = jsonEncode(head);
    final handles = _handleRe
        .allMatches(headText)
        .map((m) => m.group(0)!)
        .toSet()
        .toList()
      ..sort();

    // Build the summarize request.
    final headAsUser = <Map<String, dynamic>>[
      {'role': 'system', 'content': _summarizeSystem},
      {
        'role': 'user',
        'content':
            'Conversation to summarize (JSON message list follows):\n$headText',
      },
    ];

    String summaryBody;
    try {
      final raw = await engine.completeText(
        messages: headAsUser,
        maxTokens: 400,
        temperature: 0.2,
      );
      summaryBody = raw.trim();
      if (summaryBody.isEmpty) {
        summaryBody = '[compacted: elided ${head.length} earlier messages]';
      }
    } catch (_) {
      return [
        ...systemMsgs,
        {
          'role': 'assistant',
          'content': '[compacted: elided ${head.length} earlier messages]',
        },
        ...tail,
      ];
    }

    final handleLine = handles.isEmpty
        ? ''
        : '\n\nHandles still valid: ${handles.join(", ")}';
    final synthetic = {
      'role': 'assistant',
      'content': '[compacted]\n$summaryBody$handleLine',
    };

    return [
      ...systemMsgs,
      synthetic,
      ...tail,
    ];
  }
}
