import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import 'chat_controller.dart';

class TaskLedgerScreen extends StatelessWidget {
  const TaskLedgerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final todos = chat.todos;
    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      body: todos.isEmpty
          ? const _EmptyLedger()
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: todos.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) => TodoTile(todo: todos[i]),
            ),
    );
  }
}

class TodoTile extends StatelessWidget {
  final TodoItem todo;
  const TodoTile({super.key, required this.todo});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = todo.status == TodoStatus.inProgress;
    final done = todo.status == TodoStatus.completed;
    final bg = active
        ? cs.primaryContainer
        : done
            ? cs.surfaceContainerHighest
            : cs.surface;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: _statusIcon(todo.status, cs),
        title: Text(
          todo.content,
          style: TextStyle(
            decoration: done ? TextDecoration.lineThrough : null,
            color: active ? cs.onPrimaryContainer : cs.onSurface,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        subtitle: Text(
          _statusLabel(todo.status),
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _statusIcon(TodoStatus status, ColorScheme cs) {
    switch (status) {
      case TodoStatus.completed:
        return Icon(Icons.check_circle, color: cs.primary);
      case TodoStatus.inProgress:
        return Icon(Icons.play_circle_fill, color: cs.primary);
      case TodoStatus.pending:
        return Icon(Icons.radio_button_unchecked, color: cs.outline);
    }
  }

  String _statusLabel(TodoStatus s) => switch (s) {
        TodoStatus.completed => 'Done',
        TodoStatus.inProgress => 'In progress',
        TodoStatus.pending => 'Pending',
      };
}

class _EmptyLedger extends StatelessWidget {
  const _EmptyLedger();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist,
                size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('No active tasks',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Syndai builds a TODO list as it works. Start a conversation on the Chat tab.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
