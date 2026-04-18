import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../voice/stt.dart';
import '../voice/tts.dart';
import 'app_settings.dart';
import 'chat_controller.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _listening = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final chat = context.read<ChatController>();
    await chat.send(text);
  }

  Future<void> _micPressed() async {
    final stt = context.read<SpeechToTextService>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await stt.startListening(
      onPartial: (p) => setState(() => _input.text = p),
    );
    switch (result) {
      case SttStartResult.started:
        setState(() => _listening = true);
      case SttStartResult.permissionDenied:
        messenger.showSnackBar(const SnackBar(
            content: Text('Microphone permission denied.')));
      case SttStartResult.unavailable:
        messenger.showSnackBar(const SnackBar(
            content: Text('Speech recognition unavailable.')));
    }
  }

  Future<void> _micReleased() async {
    if (!_listening) return;
    final stt = context.read<SpeechToTextService>();
    final text = await stt.stopListening();
    setState(() {
      _listening = false;
      _input.text = text;
    });
    if (text.trim().isNotEmpty) {
      await _send();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final settings = context.watch<AppSettings>();

    final finished = chat.consumeFinishedSummary();
    if (finished != null && settings.voiceOutput) {
      context.read<TextToSpeechService>().speak(finished);
    }

    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(title: const Text('Syndai')),
      body: Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: chat.messages.length,
                    itemBuilder: (_, i) =>
                        _MessageView(message: chat.messages[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: _listening
                            ? 'Listening…'
                            : 'Ask Syndai anything',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTapDown: (_) => _micPressed(),
                    onTapUp: (_) => _micReleased(),
                    onTapCancel: _micReleased,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _listening
                            ? Theme.of(context).colorScheme.errorContainer
                            : Theme.of(context).colorScheme.secondaryContainer,
                      ),
                      child: Icon(
                        _listening ? Icons.mic : Icons.mic_none,
                        color: _listening
                            ? Theme.of(context).colorScheme.onErrorContainer
                            : Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: chat.running ? null : _send,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    child: chat.running
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq,
                size: 48,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Say hi to Syndai',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Hold the mic to talk, or type below. Syndai uses your configured MCP servers to get things done.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  final ChatMessage message;
  const _MessageView({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final cs = Theme.of(context).colorScheme;
    final bg = isUser ? cs.primary : cs.surfaceContainerHighest;
    final fg = isUser ? cs.onPrimary : cs.onSurface;

    final children = <Widget>[];
    for (final p in message.parts) {
      if (p is String) {
        if (p.isNotEmpty) {
          children.add(Text(p, style: TextStyle(color: fg)));
        }
      } else if (p is ToolCallBubble) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _ToolChip(call: p),
        ));
      }
    }

    if (children.isEmpty) {
      children.add(SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: fg.withValues(alpha: 0.6)),
      ));
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _ToolChip extends StatelessWidget {
  final ToolCallBubble call;
  const _ToolChip({required this.call});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final done = call.resultSummary != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 14,
            width: 14,
            child: done
                ? Icon(Icons.check, size: 14, color: cs.primary)
                : const CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              done
                  ? '${call.toolName}: ${call.resultSummary}'
                  : 'Calling ${call.toolName}…',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
