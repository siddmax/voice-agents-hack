// Shared interface so Lane B can ship a UI against a mock while Lane C
// builds the real loop. Lane C implements RealAgentService and it swaps
// in at integration time.
import 'dart:async';
import 'dart:typed_data';

/// A single streamed event from the agent loop. The UI renders these in order.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentToken extends AgentEvent {
  final String text;
  const AgentToken(this.text);
}

class AgentToolCall extends AgentEvent {
  final String toolName;
  final Map<String, dynamic> args;
  const AgentToolCall(this.toolName, this.args);
}

class AgentToolResult extends AgentEvent {
  final String toolName;
  final String summary;
  const AgentToolResult(this.toolName, this.summary);
}

class AgentTodoUpdate extends AgentEvent {
  final List<TodoItem> todos;
  const AgentTodoUpdate(this.todos);
}

/// Emitted while the model is generating the next call. The UI renders this
/// as a transient "thinking" indicator that disappears as soon as any other
/// event arrives. Carries the active TODO content plus generation progress
/// (token count + elapsed time) so the user sees forward motion during the
/// 10–30 s inference stalls on slow devices.
class AgentThinking extends AgentEvent {
  final String? activeTodo;
  final int tokens;
  final int elapsedMs;
  const AgentThinking({this.activeTodo, this.tokens = 0, this.elapsedMs = 0});
}

class AgentFinished extends AgentEvent {
  final String summary;
  const AgentFinished(this.summary);
}

/// Surfaced when the agent's underlying stream errors out (e.g. the LLM
/// engine threw or hung). Renders in the UI so the user sees what went
/// wrong instead of a silent forever-spinner.
class AgentError extends AgentEvent {
  final String message;
  const AgentError(this.message);
}

class TodoItem {
  final String id;
  final String content;
  final TodoStatus status;
  const TodoItem(this.id, this.content, this.status);
}

enum TodoStatus { pending, inProgress, completed }

abstract class AgentService {
  Stream<AgentEvent> run(String userInput);
  Future<void> cancel();
  Future<String?> transcribe(Uint8List pcm);
}
