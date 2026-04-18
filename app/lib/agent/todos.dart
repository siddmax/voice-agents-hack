import 'package:flutter/foundation.dart';

import 'agent_service.dart';

class TodoStore extends ChangeNotifier {
  final List<TodoItem> _items = [];

  List<TodoItem> get items => List.unmodifiable(_items);

  TodoItem? get active {
    for (final t in _items) {
      if (t.status == TodoStatus.inProgress) return t;
    }
    return null;
  }

  bool get allDone =>
      _items.isNotEmpty && _items.every((t) => t.status == TodoStatus.completed);

  void replaceAll(List<TodoItem> next) {
    _items
      ..clear()
      ..addAll(_enforceSingleInProgress(next));
    notifyListeners();
  }

  void markInProgress(String id) {
    var found = false;
    for (var i = 0; i < _items.length; i++) {
      final t = _items[i];
      if (t.id == id) {
        _items[i] = TodoItem(t.id, t.content, TodoStatus.inProgress);
        found = true;
      } else if (t.status == TodoStatus.inProgress) {
        // Demote — single in_progress invariant.
        _items[i] = TodoItem(t.id, t.content, TodoStatus.pending);
      }
    }
    if (found) notifyListeners();
  }

  void markCompleted(String id) {
    for (var i = 0; i < _items.length; i++) {
      final t = _items[i];
      if (t.id == id) {
        _items[i] = TodoItem(t.id, t.content, TodoStatus.completed);
        notifyListeners();
        return;
      }
    }
  }

  String renderLedger() {
    if (_items.isEmpty) return '(no todos yet)';
    final buf = StringBuffer();
    for (final t in _items) {
      final mark = switch (t.status) {
        TodoStatus.completed => '[x]',
        TodoStatus.inProgress => '[~]',
        TodoStatus.pending => '[ ]',
      };
      buf.writeln('$mark ${t.id} ${t.content}');
    }
    return buf.toString().trimRight();
  }

  List<TodoItem> _enforceSingleInProgress(List<TodoItem> input) {
    var seen = false;
    final out = <TodoItem>[];
    for (final t in input) {
      if (t.status == TodoStatus.inProgress) {
        if (seen) {
          out.add(TodoItem(t.id, t.content, TodoStatus.pending));
        } else {
          seen = true;
          out.add(t);
        }
      } else {
        out.add(t);
      }
    }
    return out;
  }
}
