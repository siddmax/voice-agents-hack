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
      controller.add(const AgentThinking(activeTodo: 'capturing repro context'));
      await _emitTokens(
        'I heard a checkout failure in Section 102. '
        'Drop-Guard is correlating your voice report with the live seat-lock path now.',
        controller,
      );

      if (_cancelled) return;
      controller.add(const AgentToolCall(
        'prepare_bug_intake',
        {'product_area': 'Checkout', 'surface': 'Seat map'},
      ));
      await _wait(420);
      controller.add(const AgentToolResult(
        'prepare_bug_intake',
        'Intent mapped to checkout hang in Section 102 with repeated Add to Cart attempts.',
      ));

      controller.add(const AgentToolCall(
        'start_repro_capture',
        {'surface': 'seat_map', 'mode': 'screen+logs'},
      ));
      await _wait(380);
      controller.add(const AgentToolResult(
        'start_repro_capture',
        'Screen recording, narration transcript, and session markers are live.',
      ));

      controller.add(const AgentToolCall(
        'inspect_network_failures',
        {'client': 'dio', 'focus': 'seat lock'},
      ));
      await _wait(640);
      controller.add(const AgentToolResult(
        'inspect_network_failures',
        '[DioError] 409: Conflict - Seat_Lock_Timeout',
      ));

      controller.add(const AgentToolCall(
        'map_trace_location',
        {'signal': 'Seat_Lock_Timeout'},
      ));
      await _wait(300);
      controller.add(const AgentToolResult(
        'map_trace_location',
        'lib/logic/cart_provider.dart:88',
      ));

      controller.add(const AgentTodoUpdate([
        TodoItem('t1', 'Correlate transcript with spinner evidence', TodoStatus.completed),
        TodoItem('t2', 'Assemble GitHub-ready issue payload', TodoStatus.inProgress),
        TodoItem('t3', 'Submit issue for engineering review', TodoStatus.pending),
      ]));

      controller.add(const AgentToolCall(
        'generate_bug_report',
        {'target': 'github_issue'},
      ));
      await _wait(520);
      controller.add(const AgentToolResult(
        'generate_bug_report',
        'Structured report assembled with transcript, trace, repro steps, and 5-second spinner evidence.',
      ));

      await _emitTokens(
        'The issue is isolated. I found a seat lock timeout and built the GitHub issue body for engineering. '
        'Tap Submit to open the issue flow.',
        controller,
      );
      controller.add(const AgentFinished(
        'The GitHub issue draft is ready with transcript, trace, and evidence.',
      ));
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
      controller.add(const AgentToolCall(
        'create_github_issue',
        {'repo': 'demo/reliability-lab', 'labels': ['bug', 'demo', 'seat-lock']},
      ));
      await _wait(600);
      controller.add(const AgentToolResult(
        'create_github_issue',
        '#142',
      ));
      await _emitTokens(
        'Bug report submitted successfully. Sent to GitHub Issues as number 142.',
        controller,
      );
      controller.add(const AgentFinished(
        'Bug report submitted successfully. Sent to GitHub Issues as #142.',
      ));
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
