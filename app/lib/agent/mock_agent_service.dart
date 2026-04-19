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
    if (userInput.toLowerCase().contains('github')) {
      _driveSubmission(controller);
    } else {
      _driveDiagnosis(userInput, controller);
    }
    return controller.stream;
  }

  Future<void> _driveDiagnosis(
    String userInput,
    StreamController<AgentEvent> controller,
  ) async {
    try {
      controller.add(
        const AgentThinking(activeTodo: 'capturing repro context'),
      );
      await _emitTokens(
        'I heard a checkout failure for Golden State Warriors seats in Section 105. '
        'The Syndai agent is correlating your voice report with the live list-to-void loop now.',
        controller,
      );

      if (_cancelled) return;
      controller.add(
        const AgentToolCall('prepare_bug_intake', {
          'product_area': 'Ticketing',
          'surface': 'Seat list',
        }),
      );
      await _wait(420);
      controller.add(
        const AgentToolResult(
          'prepare_bug_intake',
          'Intent mapped to a checkout hang in Section 105 after repeated seat selection attempts.',
        ),
      );

      controller.add(
        const AgentToolCall('capture_widget_state', {
          'surface': 'seat_list',
          'mode': 'screen+logs',
        }),
      );
      await _wait(380);
      controller.add(
        const AgentToolResult(
          'capture_widget_state',
          'Failure window captured with widget tree snapshot, narration transcript, and retry marker.',
        ),
      );

      controller.add(
        const AgentToolCall('analyze_network_logs', {
          'client': 'dio',
          'focus': 'seat selection timeout',
        }),
      );
      await _wait(640);
      controller.add(
        const AgentToolResult(
          'analyze_network_logs',
          '{"error":"Timeout","code":"LIST_TO_VOID","seat":"Section 105 Row 10","retryable":true}',
        ),
      );

      controller.add(
        const AgentToolCall('map_trace_location', {'signal': 'LIST_TO_VOID'}),
      );
      await _wait(300);
      controller.add(
        const AgentToolResult(
          'map_trace_location',
          'lib/checkout/seat_list_controller.dart:118',
        ),
      );

      controller.add(
        const AgentTodoUpdate([
          TodoItem(
            't1',
            'Correlate transcript with spinner evidence',
            TodoStatus.completed,
          ),
          TodoItem(
            't2',
            'Assemble GitHub-ready issue payload',
            TodoStatus.inProgress,
          ),
          TodoItem(
            't3',
            'Submit issue for engineering review',
            TodoStatus.pending,
          ),
        ]),
      );

      controller.add(
        const AgentToolCall('generate_bug_report', {'target': 'github_issue'}),
      );
      await _wait(520);
      controller.add(
        const AgentToolResult(
          'generate_bug_report',
          'Structured report assembled with transcript, device info, timeout log, and widget-state evidence.',
        ),
      );

      await _emitTokens(
        'The issue is isolated. I found the ticket-selection timeout and assembled the GitHub issue package for engineering. '
        'The Syndai agent is pushing it now.',
        controller,
      );
      controller.add(
        const AgentFinished(
          'The GitHub issue payload is ready with transcript, device info, timeout log, and evidence.',
        ),
      );
    } catch (e, st) {
      controller.addError(e, st);
    } finally {
      await controller.close();
    }
  }

  Future<void> _driveSubmission(StreamController<AgentEvent> controller) async {
    try {
      controller.add(const AgentThinking(activeTodo: 'creating GitHub issue'));
      await _emitTokens(
        'Submitting the repro package directly to GitHub Issues now.',
        controller,
      );
      controller.add(
        const AgentToolCall('create_github_issue', {
          'repo': 'demo/reliability-lab',
          'labels': ['bug', 'demo', 'warriors-checkout'],
        }),
      );
      await _wait(600);
      controller.add(const AgentToolResult('create_github_issue', '#GSU-882'));
      await _emitTokens(
        'Issue pushed to engineering successfully. The queue reservation is active and the GitHub issue is live as GSU-882.',
        controller,
      );
      controller.add(
        const AgentFinished(
          'Issue pushed to engineering successfully as #GSU-882.',
        ),
      );
    } catch (e, st) {
      controller.addError(e, st);
    } finally {
      await controller.close();
    }
  }

  Future<void> _emitTokens(
    String text,
    StreamController<AgentEvent> controller,
  ) async {
    for (final token in _tokenize(text)) {
      if (_cancelled) return;
      await _wait(110);
      controller.add(AgentToken(token));
    }
  }

  Future<void> _wait(int milliseconds) async {
    if (_cancelled) return;
    await Future.delayed(Duration(milliseconds: milliseconds));
  }

  Iterable<String> _tokenize(String text) sync* {
    final parts = text.split(RegExp(r'(?<=\s)'));
    for (final part in parts) {
      if (part.isEmpty) continue;
      yield part;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _controller?.close();
    _controller = null;
  }
}
