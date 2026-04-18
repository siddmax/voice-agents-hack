import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/agent/prompt_assembler.dart';
import 'package:syndai/agent/todos.dart';

void main() {
  group('PromptAssembler', () {
    test('truncates memory above 1500 tokens', () {
      final huge = 'x' * (1500 * 4 + 4000); // well over 1500 tokens
      final todos = TodoStore();
      final store = ToolResultStore();
      final pa = PromptAssembler(
        todos: todos,
        readMemory: () => huge,
        toolResults: store,
      );
      final msgs = pa.build(history: []);
      final system = msgs.first['content'] as String;
      expect(system.contains('[truncated middle]'), isTrue);
      // System message chars should be bounded: identity + overhead + ~8000 chars.
      expect(system.length, lessThan(12000));
    });

    test('goal re-injection includes active todo content', () {
      final todos = TodoStore()
        ..replaceAll([
          const TodoItem('t1', 'draft the email', TodoStatus.inProgress),
        ]);
      final pa = PromptAssembler(
        todos: todos,
        readMemory: () => '',
        toolResults: ToolResultStore(),
      );
      final msgs = pa.build(history: []);
      expect((msgs.first['content'] as String).contains('draft the email'),
          isTrue);
    });

    test('tool-result handle replacement above 500 tokens', () {
      final store = ToolResultStore();
      final pa = PromptAssembler(
        todos: TodoStore(),
        readMemory: () => '',
        toolResults: store,
      );
      final big = 'y' * (501 * 4);
      final r = pa.compactToolResult('search_web', big);
      expect(r['handle'], isNotNull);
      expect((r['content'] as String).contains('tool_result: name=search_web'),
          isTrue);
      expect(store.get(r['handle'] as String), big);
    });

    test('small tool results pass through', () {
      final pa = PromptAssembler(
        todos: TodoStore(),
        readMemory: () => '',
        toolResults: ToolResultStore(),
      );
      final r = pa.compactToolResult('ping', 'pong');
      expect(r['handle'], isNull);
      expect(r['content'], 'pong');
    });
  });
}
