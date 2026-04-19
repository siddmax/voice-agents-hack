import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_service.dart';
import '../sdk/feedback_analyzer.dart';

enum MessageRole { user, agent }

class ToolCallBubble {
  final String toolName;
  final Map<String, dynamic> args;
  String? resultSummary;
  ToolCallBubble(this.toolName, this.args);
}

class ChatMessage {
  final MessageRole role;
  final List<Object> parts = [];
  ChatMessage(this.role, [String? initial]) {
    if (initial != null && initial.isNotEmpty) parts.add(initial);
  }

  String get text => parts.whereType<String>().join();
}

class ChatController extends ChangeNotifier {
  final AgentService agent;
  ChatController(this.agent);

  final List<ChatMessage> messages = [];
  List<TodoItem> todos = const [];

  /// Raw ordered event stream for the current session. New consumers (Jarvis)
  /// render directly from this; legacy [messages] rendering remains for the
  /// old chat screen (now deleted but tests may still exercise the shape).
  final List<AgentEvent> events = [];

  void clearSession() {
    messages.clear();
    events.clear();
    todos = const [];
    _lastFinishedSummary = null;
    notifyListeners();
  }

  /// Injects a greeting as an agent token so it shows in the activity feed.
  void greet(String text) {
    events.add(AgentToken(text));
    notifyListeners();
  }

  StreamSubscription<AgentEvent>? _sub;
  bool _running = false;
  String? _lastFinishedSummary;

  bool get running => _running;
  String? consumeFinishedSummary() {
    final s = _lastFinishedSummary;
    _lastFinishedSummary = null;
    return s;
  }

  Future<void> send(String userText) async {
    final trimmed = userText.trim();
    if (trimmed.isEmpty || _running) return;
    _running = true;
    messages.add(ChatMessage(MessageRole.user, trimmed));
    final agentMsg = ChatMessage(MessageRole.agent);
    messages.add(agentMsg);
    notifyListeners();

    _sub = agent
        .run(trimmed)
        .listen(
          (evt) {
            events.add(evt);
            switch (evt) {
              case AgentToken(:final text):
                if (agentMsg.parts.isNotEmpty &&
                    agentMsg.parts.last is String) {
                  agentMsg.parts[agentMsg.parts.length - 1] =
                      (agentMsg.parts.last as String) + text;
                } else {
                  agentMsg.parts.add(text);
                }
              case AgentToolCall(:final toolName, :final args):
                agentMsg.parts.add(ToolCallBubble(toolName, args));
              case AgentToolResult(:final toolName, :final summary):
                for (var i = agentMsg.parts.length - 1; i >= 0; i--) {
                  final p = agentMsg.parts[i];
                  if (p is ToolCallBubble &&
                      p.toolName == toolName &&
                      p.resultSummary == null) {
                    p.resultSummary = summary;
                    break;
                  }
                }
              case AgentTodoUpdate(:final todos):
                this.todos = todos;
              case AgentThinking():
                // Transient — UI renders from the events list; no controller state.
                break;
              case AgentFinished(:final summary):
                _lastFinishedSummary = summary;
              case AgentError():
                // Surfaces in the activity feed via events; nothing else to track.
                break;
            }
            notifyListeners();
          },
          onDone: () {
            _running = false;
            notifyListeners();
          },
          onError: (e, st) {
            agentMsg.parts.add('\n\n[error: $e]');
            events.add(AgentError(e.toString()));
            _running = false;
            notifyListeners();
          },
        );
  }

  Future<void> cancel() async {
    if (!_running) return;
    await _sub?.cancel();
    _sub = null;
    await agent.cancel();
    _running = false;
    notifyListeners();
  }

  Future<String?> transcribe(Uint8List pcm) => agent.transcribe(pcm);

  Future<FeedbackReport> analyzeFeedback(
    String transcript, {
    Uint8List? pcmData,
  }) {
    return agent.analyzeFeedback(transcript, pcmData: pcmData);
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await agent.cancel();
    super.dispose();
  }
}
