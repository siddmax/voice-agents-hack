import 'package:flutter/material.dart';

import '../agent/agent_service.dart';

class ActivityFeed extends StatefulWidget {
  final List<AgentEvent> events;
  const ActivityFeed({super.key, required this.events});

  @override
  State<ActivityFeed> createState() => _ActivityFeedState();
}

class _ActivityFeedState extends State<ActivityFeed> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant ActivityFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events.length != widget.events.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<_FeedRow> _compile() {
    final rows = <_FeedRow>[];
    final buf = StringBuffer();
    List<TodoItem>? latestTodos;
    String? thinkingHint;

    void flushTokens() {
      if (buf.isEmpty) return;
      rows.add(_TokenRow(buf.toString()));
      buf.clear();
    }

    // Resolve tool call -> matching result by index order.
    final resultQueue = <String, List<String>>{};
    for (final e in widget.events) {
      if (e is AgentToolResult) {
        resultQueue.putIfAbsent(e.toolName, () => []).add(e.summary);
      }
    }
    final consumed = <String, int>{};

    for (final e in widget.events) {
      switch (e) {
        case AgentToken(:final text):
          thinkingHint = null;
          buf.write(text);
        case AgentToolCall(:final toolName, :final args):
          thinkingHint = null;
          flushTokens();
          final idx = consumed[toolName] ?? 0;
          final results = resultQueue[toolName] ?? const [];
          String? summary;
          if (idx < results.length) {
            summary = results[idx];
            consumed[toolName] = idx + 1;
          }
          rows.add(_ToolRow(toolName, args, summary));
        case AgentToolResult():
          // Consumed above.
          break;
        case AgentTodoUpdate(:final todos):
          thinkingHint = null;
          latestTodos = todos;
        case AgentThinking(:final activeTodo):
          // Transient: only the latest one is shown, replaced by any later event.
          thinkingHint = activeTodo ?? 'thinking';
        case AgentFinished(:final summary):
          thinkingHint = null;
          flushTokens();
          rows.add(_FinishedRow(summary));
      }
    }
    flushTokens();
    if (thinkingHint != null) rows.add(_ThinkingRow(thinkingHint));

    return [
      if (latestTodos != null && latestTodos.isNotEmpty)
        _TodoHeaderRow(latestTodos),
      ...rows,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _compile();
    if (rows.isEmpty) {
      return Center(
        child: Text(
          'Tap the orb to speak.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i].build(context),
    );
  }
}

sealed class _FeedRow {
  Widget build(BuildContext context);
}

class _TokenRow extends _FeedRow {
  final String text;
  _TokenRow(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _ToolRow extends _FeedRow {
  final String toolName;
  final Map<String, dynamic> args;
  final String? summary;
  _ToolRow(this.toolName, this.args, this.summary);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = summary != null;
    final isError = done && summary!.toLowerCase().startsWith('error');
    final bg = !done
        ? scheme.surfaceContainerHighest
        : isError
            ? scheme.errorContainer
            : scheme.tertiaryContainer;
    final fg = !done
        ? scheme.onSurfaceVariant
        : isError
            ? scheme.onErrorContainer
            : scheme.onTertiaryContainer;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          backgroundColor: bg,
          side: BorderSide(color: fg.withValues(alpha: 0.2)),
          avatar: Icon(
            done
                ? (isError ? Icons.error_outline : Icons.check_circle_outline)
                : Icons.pending_outlined,
            size: 16,
            color: fg,
          ),
          label: Text(
            done ? '$toolName · ${_short(summary!)}' : '$toolName …',
            style: TextStyle(color: fg, fontSize: 12),
          ),
        ),
      ),
    );
  }

  String _short(String s) {
    final one = s.replaceAll('\n', ' ').trim();
    return one.length > 48 ? '${one.substring(0, 48)}…' : one;
  }
}

class _TodoHeaderRow extends _FeedRow {
  final List<TodoItem> todos;
  _TodoHeaderRow(this.todos);

  @override
  Widget build(BuildContext context) => _TodoHeaderWidget(todos: todos);
}

class _TodoHeaderWidget extends StatefulWidget {
  final List<TodoItem> todos;
  const _TodoHeaderWidget({required this.todos});

  @override
  State<_TodoHeaderWidget> createState() => _TodoHeaderWidgetState();
}

class _TodoHeaderWidgetState extends State<_TodoHeaderWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final todos = widget.todos;
    final active = todos.firstWhere(
      (t) => t.status == TodoStatus.inProgress,
      orElse: () => todos.first,
    );
    final scheme = Theme.of(context).colorScheme;
    final doneCount = todos.where((t) => t.status == TodoStatus.completed).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.task_alt,
                      size: 18, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      active.content,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$doneCount / ${todos.length}',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 8),
                Divider(
                    height: 1,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.2)),
                const SizedBox(height: 8),
                for (final t in todos) _todoRow(context, t, scheme, active),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _todoRow(BuildContext context, TodoItem t, ColorScheme scheme,
      TodoItem active) {
    final isActive = identical(t, active);
    final done = t.status == TodoStatus.completed;
    final IconData icon;
    switch (t.status) {
      case TodoStatus.completed:
        icon = Icons.check_box_outlined;
      case TodoStatus.inProgress:
        icon = Icons.radio_button_checked;
      case TodoStatus.pending:
        icon = Icons.radio_button_unchecked;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.content,
              style: TextStyle(
                color: scheme.onPrimaryContainer
                    .withValues(alpha: done ? 0.55 : 1.0),
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingRow extends _FeedRow {
  final String hint;
  _ThinkingRow(this.hint);
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            hint == 'thinking' ? 'thinking…' : 'thinking · $hint',
            style: TextStyle(
              color: scheme.outline,
              fontStyle: FontStyle.italic,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _FinishedRow extends _FeedRow {
  final String summary;
  _FinishedRow(this.summary);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.flag_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              summary,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
