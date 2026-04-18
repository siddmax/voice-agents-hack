import 'dart:async';

import 'agent_service.dart';

class MockAgentService implements AgentService {
  StreamController<AgentEvent>? _controller;
  bool _cancelled = false;

  @override
  Stream<AgentEvent> run(String userInput) {
    _cancelled = false;
    final controller = StreamController<AgentEvent>();
    _controller = controller;
    _drive(userInput, controller);
    return controller.stream;
  }

  Future<void> _drive(
      String userInput, StreamController<AgentEvent> controller) async {
    try {
      final opener =
          'Looking into "${userInput.trim().isEmpty ? "that" : userInput.trim()}" '
          'for you. ';
      for (final tok in _tokenize(opener)) {
        if (_cancelled) return;
        await Future.delayed(const Duration(milliseconds: 380));
        controller.add(AgentToken(tok));
      }

      if (_cancelled) return;
      await Future.delayed(const Duration(milliseconds: 250));
      controller.add(const AgentToolCall(
        'search_linear_issues',
        {'query': 'open bugs assigned to me', 'limit': 5},
      ));

      await Future.delayed(const Duration(milliseconds: 700));
      if (_cancelled) return;
      controller.add(const AgentToolResult(
        'search_linear_issues',
        '3 open issues found: LIN-412, LIN-418, LIN-421.',
      ));

      if (_cancelled) return;
      controller.add(const AgentTodoUpdate([
        TodoItem('t1', 'Review LIN-412 repro steps', TodoStatus.completed),
        TodoItem('t2', 'Draft fix plan for LIN-418', TodoStatus.inProgress),
        TodoItem('t3', 'Ping design on LIN-421', TodoStatus.pending),
      ]));

      const tail =
          'Found three open issues. Drafting a fix plan for LIN-418 now.';
      for (final tok in _tokenize(tail)) {
        if (_cancelled) return;
        await Future.delayed(const Duration(milliseconds: 380));
        controller.add(AgentToken(tok));
      }

      if (_cancelled) return;
      controller.add(const AgentFinished(
        'Found 3 open Linear issues. Starting on LIN-418.',
      ));
    } catch (e, st) {
      controller.addError(e, st);
    } finally {
      await controller.close();
    }
  }

  Iterable<String> _tokenize(String text) sync* {
    final parts = text.split(RegExp(r'(?<=\s)'));
    for (final p in parts) {
      if (p.isEmpty) continue;
      yield p;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _controller?.close();
    _controller = null;
  }
}
