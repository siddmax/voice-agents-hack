import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/agent/todos.dart';

void main() {
  group('TodoStore', () {
    test('replaceAll swaps the list and notifies', () {
      final store = TodoStore();
      var notified = 0;
      store.addListener(() => notified++);
      store.replaceAll([
        const TodoItem('t1', 'a', TodoStatus.pending),
        const TodoItem('t2', 'b', TodoStatus.pending),
      ]);
      expect(store.items.length, 2);
      expect(notified, 1);
    });

    test('markInProgress demotes any prior in_progress', () {
      final store = TodoStore()
        ..replaceAll([
          const TodoItem('t1', 'a', TodoStatus.inProgress),
          const TodoItem('t2', 'b', TodoStatus.pending),
        ]);
      store.markInProgress('t2');
      final byId = {for (final t in store.items) t.id: t};
      expect(byId['t1']!.status, TodoStatus.pending);
      expect(byId['t2']!.status, TodoStatus.inProgress);
      expect(store.active!.id, 't2');
    });

    test('replaceAll enforces single in_progress', () {
      final store = TodoStore()
        ..replaceAll([
          const TodoItem('t1', 'a', TodoStatus.inProgress),
          const TodoItem('t2', 'b', TodoStatus.inProgress),
        ]);
      final inProg =
          store.items.where((t) => t.status == TodoStatus.inProgress).toList();
      expect(inProg.length, 1);
      expect(inProg.first.id, 't1');
    });

    test('markCompleted transitions status', () {
      final store = TodoStore()
        ..replaceAll([const TodoItem('t1', 'a', TodoStatus.inProgress)]);
      store.markCompleted('t1');
      expect(store.items.first.status, TodoStatus.completed);
      expect(store.active, isNull);
      expect(store.allDone, isTrue);
    });
  });
}
