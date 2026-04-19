import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../voice/stt.dart';
import '../voice/tts.dart';
import 'activity_feed.dart';
import 'app_settings.dart';
import 'chat_controller.dart';
import 'drop_guard_dashboard.dart';
import 'jarvis_orb.dart';
import 'settings_sheet.dart';

const _demoTranscript =
    "The seat map is frozen on Section 102. I've clicked Add to Cart three times and nothing is happening.";

class JarvisScreen extends StatefulWidget {
  final String? startupError;
  const JarvisScreen({super.key, this.startupError});

  @override
  State<JarvisScreen> createState() => _JarvisScreenState();
}

class _JarvisScreenState extends State<JarvisScreen> {
  OrbState _orb = OrbState.idle;
  double _amplitude = 0.0;
  StreamSubscription<double>? _levelSub;
  bool _wasRunning = false;
  ChatController? _chatRef;
  String _transcriptDraft = '';
  bool _captureGranted = false;
  bool _spinnerStuck = false;
  int _addToCartAttempts = 0;
  bool _showSuccess = false;

  @override
  void initState() {
    super.initState();
    if (widget.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.startupError!),
          duration: const Duration(seconds: 6),
        ));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chat = context.read<ChatController>();
    if (!identical(_chatRef, chat)) {
      _chatRef?.removeListener(_onChatChanged);
      _chatRef = chat;
      chat.addListener(_onChatChanged);
    }
  }

  void _onChatChanged() {
    final chat = _chatRef;
    if (chat == null || !mounted) return;
    if (_wasRunning && !chat.running) {
      final summary = chat.consumeFinishedSummary();
      final wantsVoice = context.read<AppSettings>().voiceOutput;
      if (summary != null && wantsVoice) {
        context.read<TextToSpeechService>().speak(summary);
      }
      setState(() => _orb = OrbState.idle);
    }
    if (!_showSuccess && _issueSubmitted(chat.events)) {
      _triggerSuccessState();
    }
    _wasRunning = chat.running;
  }

  Future<void> _triggerSuccessState() async {
    setState(() => _showSuccess = true);
    await HapticFeedback.heavyImpact();
    await SystemSound.play(SystemSoundType.click);
  }

  bool _issueSubmitted(List<AgentEvent> events) {
    for (final event in events.reversed) {
      if (event is AgentToolResult && event.toolName == 'create_github_issue') {
        return true;
      }
    }
    return false;
  }

  bool _reportReady(List<AgentEvent> events) {
    for (final event in events.reversed) {
      if (event is AgentToolResult && event.toolName == 'generate_bug_report') {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _chatRef?.removeListener(_onChatChanged);
    super.dispose();
  }

  Future<void> _onAgentTap() async {
    final stt = context.read<SpeechToTextService>();
    final chat = context.read<ChatController>();

    if (chat.running) {
      await chat.cancel();
      if (!mounted) return;
      setState(() => _orb = OrbState.idle);
      return;
    }

    if (_orb == OrbState.listening) {
      await _stopListeningAndPrompt();
      return;
    }

    _levelSub = stt.soundLevel.listen((level) {
      if (mounted) {
        setState(() => _amplitude = level);
      }
    });
    final messenger = ScaffoldMessenger.of(context);
    final result = await stt.startListening(
      onPartial: (partial) {
        if (!mounted) return;
        setState(() => _transcriptDraft = partial);
      },
    );
    if (!mounted) return;
    if (result == SttStartResult.started) {
      setState(() => _orb = OrbState.listening);
      return;
    }

    await _levelSub?.cancel();
    _levelSub = null;
    setState(() {
      _amplitude = 0;
      _transcriptDraft = _demoTranscript;
    });
    messenger.showSnackBar(const SnackBar(
      content: Text(
        'Speech recognition unavailable in this environment. Using the scripted demo report.',
      ),
    ));
    await _promptForConsent(_demoTranscript);
  }

  Future<void> _stopListeningAndPrompt() async {
    final stt = context.read<SpeechToTextService>();
    final text = await stt.stopListening();
    await _levelSub?.cancel();
    _levelSub = null;
    if (!mounted) return;
    final transcript = text.trim().isEmpty ? _demoTranscript : text.trim();
    setState(() {
      _amplitude = 0;
      _orb = OrbState.idle;
      _transcriptDraft = transcript;
    });
    await _promptForConsent(transcript);
  }

  Future<void> _promptForConsent(String transcript) async {
    final approved = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Grant Drop-Guard access to System Logs & Screen?'),
            content: const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Drop-Guard will capture the repro flow, session logs, and spinner evidence for engineering.',
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not Now'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Grant'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) return;

    final chat = context.read<ChatController>();
    setState(() {
      _captureGranted = true;
      _orb = OrbState.thinking;
      _showSuccess = false;
    });
    _wasRunning = true;
    await chat.send(transcript);
  }

  Future<void> _submitIssue() async {
    final chat = context.read<ChatController>();
    if (chat.running) return;
    _wasRunning = true;
    setState(() => _orb = OrbState.thinking);
    await chat.send('Submit this bug report directly to GitHub Issues.');
  }

  void _triggerSeatLock() {
    setState(() {
      _spinnerStuck = true;
      _addToCartAttempts += 1;
    });
  }

  void _resetDemo() {
    final chat = context.read<ChatController>();
    chat.clearSession();
    setState(() {
      _orb = OrbState.idle;
      _amplitude = 0;
      _transcriptDraft = '';
      _captureGranted = false;
      _spinnerStuck = false;
      _addToCartAttempts = 0;
      _showSuccess = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final reportReady = _reportReady(chat.events);
    final submitted = _issueSubmitted(chat.events);
    final wide = MediaQuery.of(context).size.width >= 1120;
    final dashboard = DropGuardDashboard(
      events: chat.events,
      transcript: _transcriptDraft,
      captureGranted: _captureGranted,
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            wide
                ? Row(
                    children: [
                      Expanded(flex: 11, child: _buildSimulatorPane(chat, reportReady, submitted)),
                      const VerticalDivider(width: 1),
                      Expanded(flex: 8, child: dashboard),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(flex: 10, child: _buildSimulatorPane(chat, reportReady, submitted)),
                      const Divider(height: 1),
                      SizedBox(height: 260, child: dashboard),
                    ],
                  ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => SettingsSheet.show(context),
              ),
            ),
            if (_showSuccess)
              Positioned.fill(
                child: _SuccessOverlay(
                  onDismiss: _resetDemo,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimulatorPane(
    ChatController chat,
    bool reportReady,
    bool submitted,
  ) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF111827), Color(0xFF1E293B)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Drop-Guard',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Ticketing simulator · voice-first incident capture for GitHub Issues',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 18),
            _TicketmasterSurface(
              spinnerStuck: _spinnerStuck,
              attempts: _addToCartAttempts,
              onActivateFailure: _triggerSeatLock,
            ),
            const SizedBox(height: 16),
            _buildVoicePanel(chat, reportReady, submitted),
            const SizedBox(height: 16),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Live agent feed',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(child: ActivityFeed(events: chat.events)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoicePanel(
    ChatController chat,
    bool reportReady,
    bool submitted,
  ) {
    final theme = Theme.of(context);
    final accent = switch (_orb) {
      OrbState.idle => const Color(0xFF38BDF8),
      OrbState.listening => const Color(0xFF67E8F9),
      OrbState.thinking => const Color(0xFFF59E0B),
    };
    final hint = chat.running
        ? 'Agent is analyzing the checkout failure'
        : _orb == OrbState.listening
            ? 'Speak now, then tap the mic again to stop'
            : reportReady && !submitted
                ? 'The report is ready. Submit it directly to GitHub Issues.'
                : 'Tap the Agent button and describe what went wrong';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF020617).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 18,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                JarvisOrb(
                  state: _orb,
                  amplitude: _amplitude,
                  size: 64,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Agent command center',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                _transcriptDraft.isEmpty
                    ? _demoTranscript
                    : _transcriptDraft,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: Colors.white,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _onAgentTap,
                  icon: Icon(_orb == OrbState.listening ? Icons.stop : Icons.mic),
                  label: Text(_orb == OrbState.listening ? 'Stop Voice Intake' : 'Activate Agent'),
                ),
                OutlinedButton.icon(
                  onPressed: reportReady && !submitted ? _submitIssue : null,
                  icon: const Icon(Icons.bug_report_outlined),
                  label: const Text('Submit to GitHub'),
                ),
                if (submitted)
                  Chip(
                    avatar: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('GitHub Issue #142 created'),
                    backgroundColor: const Color(0xFF052E16),
                    side: BorderSide.none,
                    labelStyle: const TextStyle(color: Color(0xFFBBF7D0)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketmasterSurface extends StatelessWidget {
  final bool spinnerStuck;
  final int attempts;
  final VoidCallback onActivateFailure;

  const _TicketmasterSurface({
    required this.spinnerStuck,
    required this.attempts,
    required this.onActivateFailure,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF020617).withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ticketmaster Checkout',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Biggest drop of the year · Section 102 seat lock flow',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1D4ED8).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF60A5FA).withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'Section 102',
                    style: TextStyle(
                      color: Color(0xFFBFDBFE),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            AspectRatio(
              aspectRatio: 1.55,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF111827), Color(0xFF1F2937)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          children: List.generate(5, (row) {
                            return Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: List.generate(8, (column) {
                                  final isTarget = row == 2 && column == 4;
                                  return _SeatDot(
                                    selected: isTarget,
                                    stuck: isTarget && spinnerStuck,
                                    onTap: isTarget ? onActivateFailure : null,
                                  );
                                }),
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 18,
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: spinnerStuck
                                ? const Color(0xFFF87171).withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    spinnerStuck
                                        ? 'Seat lock is hanging at checkout'
                                        : 'Select the blue seat to trigger the checkout hang',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    spinnerStuck
                                        ? 'Add to Cart pressed ${math.max(attempts, 1)} times · user is stuck in purchase flow'
                                        : 'The blue seat simulates a high-demand checkout conflict.',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton(
                              onPressed: onActivateFailure,
                              style: FilledButton.styleFrom(
                                backgroundColor: spinnerStuck
                                    ? const Color(0xFFF97316)
                                    : const Color(0xFF2563EB),
                              ),
                              child: Text(
                                spinnerStuck ? 'Add to Cart x${attempts + 1}' : 'Add to Cart',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeatDot extends StatelessWidget {
  final bool selected;
  final bool stuck;
  final VoidCallback? onTap;

  const _SeatDot({
    required this.selected,
    required this.stuck,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF3B82F6) : const Color(0xFF334155);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.5),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: stuck
            ? const Padding(
                padding: EdgeInsets.all(5),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : null,
      ),
    );
  }
}

class _SuccessOverlay extends StatefulWidget {
  final VoidCallback onDismiss;

  const _SuccessOverlay({required this.onDismiss});

  @override
  State<_SuccessOverlay> createState() => _SuccessOverlayState();
}

class _SuccessOverlayState extends State<_SuccessOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pulse = 0.7 + (_controller.value * 0.3);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.05,
              colors: [
                const Color(0xFF00FF7F).withValues(alpha: 0.28 * pulse),
                const Color(0xFF052E16),
                Colors.black,
              ],
            ),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: CustomPaint(
                      painter: _CheckPainter(
                        color: const Color(0xFF4ADE80),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Bug report submitted successfully',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Sent to GitHub Issues as #142',
                    style: TextStyle(
                      color: Color(0xFFBBF7D0),
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Engineering received the transcript, trace, repro steps, and spinner evidence.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: widget.onDismiss,
                    icon: const Icon(Icons.replay),
                    label: const Text('Report Another Bug'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  final Color color;

  _CheckPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(size.width * 0.18, size.height * 0.55)
      ..lineTo(size.width * 0.42, size.height * 0.76)
      ..lineTo(size.width * 0.82, size.height * 0.24);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter oldDelegate) =>
      oldDelegate.color != color;
}
