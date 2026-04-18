// Shared interface so Lane B can ship a UI against a mock while Lane C
// builds the real loop. Lane C implements RealAgentService and it swaps
// in at integration time.
import 'dart:async';

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
/// event arrives. Carries the active TODO content so the user can see what
/// the agent is currently working on.
class AgentThinking extends AgentEvent {
  final String? activeTodo;
  const AgentThinking({this.activeTodo});
}

class AgentFinished extends AgentEvent {
  final String summary;
  const AgentFinished(this.summary);
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
}
