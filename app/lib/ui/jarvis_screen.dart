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
import 'jarvis_orb.dart';
import 'settings_sheet.dart';

const _demoTranscript =
    "The checkout isn't loading for Section 105. It just stays on the spinner.";
const _demoDeviceInfo = 'Simulator - iPhone 17 Pro.';
const _demoLog =
    '{"error":"Timeout","code":"LIST_TO_VOID","seat":"Section 105 Row 10","route":"/checkout/seat/select"}';

const _seatOptions = <_SeatOption>[
  _SeatOption('s105-r10', 'Section 105, Row 10', '\$350', highlighted: true),
  _SeatOption('s105-r11', 'Section 105, Row 11', '\$335'),
  _SeatOption('s106-r04', 'Section 106, Row 4', '\$310'),
  _SeatOption('s107-r02', 'Section 107, Row 2', '\$295'),
  _SeatOption('club-r01', 'Club Level, Row 1', '\$480'),
  _SeatOption('lower-r18', 'Lower Bowl, Row 18', '\$260'),
];

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
  bool _autoSubmitting = false;
  ChatController? _chatRef;

  String _transcriptDraft = '';
  String _issueId = 'GSU-882';
  String _selectedSeatId = _seatOptions.first.id;
  bool _captureGranted = false;
  bool _showWaveform = false;
  bool _spinnerStuck = false;
  int _selectionAttempts = 0;
  bool _showSuccess = false;

  @override
  void initState() {
    super.initState();
    if (widget.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.startupError!),
            duration: const Duration(seconds: 6),
          ),
        );
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

    final latestIssueId = _latestIssueId(chat.events);
    if (latestIssueId != null && latestIssueId != _issueId) {
      setState(() => _issueId = latestIssueId);
    }

    if (_wasRunning && !chat.running) {
      final summary = chat.consumeFinishedSummary();
      final wantsVoice = context.read<AppSettings>().voiceOutput;
      if (summary != null && wantsVoice) {
        context.read<TextToSpeechService>().speak(summary);
      }

      if (_captureGranted &&
          _reportReady(chat.events) &&
          !_issueSubmitted(chat.events) &&
          !_autoSubmitting) {
        _autoSubmitting = true;
        Future<void>.microtask(_submitIssue);
      } else {
        setState(() {
          _orb = OrbState.idle;
          if (_issueSubmitted(chat.events)) _showWaveform = false;
        });
      }
    }

    if (!_showSuccess && _issueSubmitted(chat.events)) {
      _triggerSuccessState();
    }
    _wasRunning = chat.running;
  }

  Future<void> _triggerSuccessState() async {
    setState(() {
      _showSuccess = true;
      _showWaveform = false;
      _orb = OrbState.idle;
    });
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

  String? _latestIssueId(List<AgentEvent> events) {
    final issuePattern = RegExp(r'#?[A-Z]{2,}-\d+|#\d+');
    for (final event in events.reversed) {
      if (event is! AgentToolResult ||
          event.toolName != 'create_github_issue') {
        continue;
      }
      final match = issuePattern.firstMatch(event.summary);
      if (match != null) return match.group(0);
    }
    return null;
  }

  bool _hasToolResult(List<AgentEvent> events, String toolName) {
    return events.any(
      (event) => event is AgentToolResult && event.toolName == toolName,
    );
  }

  double _progressValue(ChatController chat) {
    if (_issueSubmitted(chat.events)) return 1;
    if (_hasToolResult(chat.events, 'create_github_issue')) return 0.94;
    if (_reportReady(chat.events)) return 0.76;
    if (_hasToolResult(chat.events, 'analyze_network_logs')) return 0.56;
    if (_hasToolResult(chat.events, 'capture_widget_state')) return 0.36;
    if (_captureGranted) return 0.18;
    if (_orb == OrbState.listening) return 0.08;
    return 0;
  }

  String _progressLabel(ChatController chat) {
    if (_issueSubmitted(chat.events) ||
        _hasToolResult(chat.events, 'create_github_issue')) {
      return 'Generating GitHub Issue...';
    }
    if (_reportReady(chat.events)) return 'Generating GitHub Issue...';
    if (_hasToolResult(chat.events, 'analyze_network_logs')) {
      return 'Capturing Widget State...';
    }
    if (_hasToolResult(chat.events, 'capture_widget_state')) {
      return 'Analysing Network Logs...';
    }
    if (_captureGranted || chat.running) return 'Analysing Network Logs...';
    if (_orb == OrbState.listening) {
      return "I'm listening. Please retry the action now so I can capture the system state.";
    }
    return 'Tap Activate Syndai Agent to capture the failure window.';
  }

  String _selectedSeatLabel() {
    return _seatOptions
        .firstWhere(
          (seat) => seat.id == _selectedSeatId,
          orElse: () => _seatOptions.first,
        )
        .label;
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
      setState(() {
        _orb = OrbState.idle;
        _showWaveform = false;
      });
      return;
    }

    if (_orb == OrbState.listening) {
      await _stopListening();
      if (!mounted) return;
      setState(() {
        _orb = OrbState.idle;
        _showWaveform = false;
      });
      return;
    }

    chat.clearSession();
    _autoSubmitting = false;

    const greeting = 'Hello! How can I help you today?';
    chat.greet(greeting);

    final tts = context.read<TextToSpeechService>();
    unawaited(tts.speak(greeting));

    // Small delay so TTS can start before the mic opens.
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    _levelSub = stt.soundLevel.listen((level) {
      if (!mounted) return;
      setState(() => _amplitude = level);
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
      setState(() {
        _orb = OrbState.listening;
        _showWaveform = true;
        _captureGranted = false;
        _showSuccess = false;
      });
      return;
    }

    await _levelSub?.cancel();
    _levelSub = null;
    setState(() {
      _amplitude = 0;
      _orb = OrbState.listening;
      _showWaveform = true;
      _captureGranted = false;
      _showSuccess = false;
      _transcriptDraft = _demoTranscript;
    });
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Speech recognition is unavailable here. Using the scripted Warriors checkout report.',
        ),
      ),
    );
  }

  Future<String> _stopListening() async {
    final stt = context.read<SpeechToTextService>();
    final text = await stt.stopListening();
    await _levelSub?.cancel();
    _levelSub = null;
    if (!mounted) return _demoTranscript;
    final transcript = text.trim().isEmpty ? _demoTranscript : text.trim();
    setState(() {
      _amplitude = 0;
      _transcriptDraft = transcript;
    });
    return transcript;
  }

  Future<void> _onSeatTap(_SeatOption seat) async {
    setState(() {
      _selectedSeatId = seat.id;
      _spinnerStuck = seat.highlighted;
      _selectionAttempts += 1;
    });

    if (!seat.highlighted) return;
    if (_orb != OrbState.listening || _captureGranted) return;

    final transcript = await _stopListening();
    if (!mounted) return;
    await _promptForConsent(transcript);
  }

  Future<void> _promptForConsent(String transcript) async {
    final approved =
        await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text(
              'Allow Agent to record screen and network logs for this session?',
            ),
            content: const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'We only record the failure window so engineering can diagnose the checkout hang.',
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
                child: const Text('Allow & Record'),
              ),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) {
      setState(() {
        _orb = OrbState.idle;
        _showWaveform = false;
      });
      return;
    }

    final chat = context.read<ChatController>();
    chat.clearSession();
    _autoSubmitting = false;
    _wasRunning = true;
    setState(() {
      _captureGranted = true;
      _showWaveform = true;
      _showSuccess = false;
      _issueId = 'GSU-882';
      _orb = OrbState.thinking;
      _transcriptDraft = transcript.trim().isEmpty
          ? _demoTranscript
          : transcript;
    });
    await chat.send(_buildDiagnosisPrompt(_transcriptDraft));
  }

  String _buildDiagnosisPrompt(String transcript) {
    return 'Customer is trying to buy Golden State Warriors vs. LA Lakers tickets. '
        'The highlighted seat is ${_selectedSeatLabel()} and the list item shimmers forever instead of navigating to checkout. '
        'Transcript: "$transcript". '
        'Please capture the failure, analyze the network timeout, generate the bug report, and prepare to push the issue to GitHub.';
  }

  Future<void> _submitIssue() async {
    final chat = context.read<ChatController>();
    if (chat.running || _issueSubmitted(chat.events)) return;
    _wasRunning = true;
    setState(() => _orb = OrbState.thinking);
    await chat.send(
      'Push the GitHub issue now. '
      'Issue title should mention the Warriors checkout hang for ${_selectedSeatLabel()}. '
      'The GitHub Issue body must include:\n'
      'Transcript: ${_transcriptDraft.isEmpty ? _demoTranscript : _transcriptDraft}\n'
      'Device Info: $_demoDeviceInfo\n'
      'The Log: $_demoLog',
    );
  }

  void _resetDemo() {
    final chat = context.read<ChatController>();
    chat.clearSession();
    _autoSubmitting = false;
    setState(() {
      _orb = OrbState.idle;
      _amplitude = 0;
      _transcriptDraft = '';
      _issueId = 'GSU-882';
      _selectedSeatId = _seatOptions.first.id;
      _captureGranted = false;
      _showWaveform = false;
      _spinnerStuck = false;
      _selectionAttempts = 0;
      _showSuccess = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final progressValue = _progressValue(chat);

    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _ReferenceTopBar(
                  onOpenSettings: () => SettingsSheet.show(context),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _VenueMapStrip(
                        selectedSeat: _selectedSeatLabel(),
                        spinnerStuck: _spinnerStuck,
                      ),
                      _FilterRail(
                        attempts: _selectionAttempts,
                        spinnerStuck: _spinnerStuck,
                      ),
                      Container(
                        width: double.infinity,
                        color: Colors.white,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: const Text(
                          "We're All In: Prices include fees (before taxes).",
                          style: TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: _SeatListCard(
                          seats: _seatOptions,
                          selectedSeatId: _selectedSeatId,
                          spinnerStuck: _spinnerStuck,
                          onSeatTap: _onSeatTap,
                        ),
                      ),
                      if (_captureGranted ||
                          chat.events.isNotEmpty ||
                          _orb == OrbState.listening)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: _StatusCard(
                            progress: progressValue,
                            label: _progressLabel(chat),
                            transcript: _transcriptDraft,
                            events: chat.events,
                            listening: _orb == OrbState.listening,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              bottom: 24,
              right: 16,
              child: _ActivateBar(
                listening: _orb == OrbState.listening,
                running: chat.running,
                onTap: _onAgentTap,
              ),
            ),
            _WaveformSheet(
              visible: _showWaveform && !_captureGranted && !_showSuccess,
              amplitude: _amplitude,
            ),
            if (_showSuccess)
              Positioned.fill(
                child: _SuccessOverlay(
                  issueId: _issueId,
                  onDismiss: _resetDemo,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeatOption {
  final String id;
  final String label;
  final String price;
  final bool highlighted;

  const _SeatOption(
    this.id,
    this.label,
    this.price, {
    this.highlighted = false,
  });
}

class _ReferenceTopBar extends StatelessWidget {
  final VoidCallback onOpenSettings;

  const _ReferenceTopBar({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                RichText(
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: 'ticket',
                        style: TextStyle(
                          color: Color(0xFF026CDF),
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                      TextSpan(
                        text: 'master',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF026CDF),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    'TM',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              const CircleAvatar(
                radius: 17,
                backgroundColor: Color(0xFF232323),
                child: Icon(Icons.arrow_back, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Golden State Warriors vs. LA Lakers',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Sat • 8:00 PM • Chase Center',
                      style: TextStyle(
                        color: Color(0xFFD1D5DB),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.favorite_border, color: Colors.white),
              ),
              const Icon(Icons.more_vert, color: Colors.white),
            ],
          ),
          const SizedBox(height: 12),
          const Row(
            children: [
              _TopTab(label: 'TICKETS', selected: true),
              _TopTab(label: 'INFO'),
              _TopTab(label: 'MAP'),
              _TopTab(label: 'DETAILS'),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopTab extends StatelessWidget {
  final String label;
  final bool selected;

  const _TopTab({required this.label, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xFF2563EB) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFFD1D5DB),
            fontWeight: FontWeight.w700,
            fontSize: 12,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

class _VenueMapStrip extends StatelessWidget {
  final String selectedSeat;
  final bool spinnerStuck;

  const _VenueMapStrip({
    required this.selectedSeat,
    required this.spinnerStuck,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFE5E7EB),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFD1D5DB)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_horiz, size: 18, color: Color(0xFF374151)),
                    SizedBox(width: 6),
                    Text(
                      'Switch to Map',
                      style: TextStyle(
                        color: Color(0xFF374151),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 110,
            child: AspectRatio(
              aspectRatio: 1.35,
              child: CustomPaint(
                painter: _MiniArenaPainter(highlighted: spinnerStuck),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            spinnerStuck
                ? '$selectedSeat is hanging before checkout completes.'
                : '$selectedSeat is selected for the scripted checkout path.',
            style: const TextStyle(
              color: Color(0xFF4B5563),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniArenaPainter extends CustomPainter {
  final bool highlighted;

  _MiniArenaPainter({required this.highlighted});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final basePaint = Paint()..color = const Color(0xFFD1D5DB);
    final accentPaint = Paint()
      ..color = highlighted ? const Color(0xFF2563EB) : const Color(0xFF93C5FD);
    final stagePaint = Paint()..color = const Color(0xFF111111);

    final rect = Rect.fromCenter(
      center: center,
      width: size.width * 0.82,
      height: size.height * 0.8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      basePaint,
    );

    final inner = Rect.fromCenter(
      center: center,
      width: size.width * 0.38,
      height: size.height * 0.26,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(inner, const Radius.circular(6)),
      Paint()..color = Colors.white,
    );
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 18, center.dy - 16, 12, 32),
      stagePaint,
    );

    for (var i = 0; i < 4; i++) {
      final width = (rect.width - 70) / 4;
      final left = rect.left + 18 + (i * ((rect.width - 54) / 4));
      canvas.drawRect(
        Rect.fromLTWH(left, rect.top + 10, width, 18),
        accentPaint,
      );
      canvas.drawRect(
        Rect.fromLTWH(left, rect.bottom - 28, width, 18),
        accentPaint,
      );
    }

    canvas.drawRect(
      Rect.fromCenter(center: center.translate(10, 4), width: 28, height: 8),
      accentPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniArenaPainter oldDelegate) =>
      oldDelegate.highlighted != highlighted;
}

class _FilterRail extends StatelessWidget {
  final int attempts;
  final bool spinnerStuck;

  const _FilterRail({
    required this.attempts,
    required this.spinnerStuck,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFD1D5DB)),
              ),
              child: Row(
                children: [
                  Text(
                    spinnerStuck
                        ? '2 Tickets · Retry ${math.max(attempts, 1)}'
                        : '2 Tickets',
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.keyboard_arrow_down,
                    color: Color(0xFF6B7280),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFD1D5DB)),
            ),
            child: const Row(
              children: [
                Icon(Icons.tune, color: Color(0xFF374151), size: 18),
                SizedBox(width: 8),
                Text(
                  'Filters',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatListCard extends StatelessWidget {
  final List<_SeatOption> seats;
  final String selectedSeatId;
  final bool spinnerStuck;
  final ValueChanged<_SeatOption> onSeatTap;

  const _SeatListCard({
    required this.seats,
    required this.selectedSeatId,
    required this.spinnerStuck,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: const Color(0xFFE5E7EB)),
          bottom: BorderSide(color: const Color(0xFFE5E7EB)),
        ),
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: seats.length,
        itemBuilder: (context, index) {
          final seat = seats[index];
          return _SeatTile(
            seat: seat,
            selected: seat.id == selectedSeatId,
            loading: seat.highlighted && spinnerStuck,
            onTap: () => onSeatTap(seat),
          );
        },
      ),
    );
  }
}

class _SeatTile extends StatelessWidget {
  final _SeatOption seat;
  final bool selected;
  final bool loading;
  final VoidCallback onTap;

  const _SeatTile({
    required this.seat,
    required this.selected,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFF8FBFF) : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: const Color(0xFFE5E7EB)),
              left: selected
                  ? const BorderSide(color: Color(0xFF2563EB), width: 4)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFD1D5DB)),
                ),
                child: const Icon(
                  Icons.location_on_outlined,
                  size: 20,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (seat.highlighted && !loading)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFFD1D5DB)),
                        ),
                        child: const Text(
                          'FEATURED',
                          style: TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    Text(
                      seat.label,
                      style: const TextStyle(
                        color: Color(0xFF111827),
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      loading
                          ? 'Checkout is stuck on a spinner after seat selection.'
                          : (seat.highlighted
                              ? 'VIP LOUNGE PACKAGE'
                              : 'Verified Resale Ticket'),
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              loading
                  ? const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Text(
                      seat.price,
                      style: const TextStyle(
                        color: Color(0xFF2563EB),
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final double progress;
  final String label;
  final String transcript;
  final List<AgentEvent> events;
  final bool listening;

  const _StatusCard({
    required this.progress,
    required this.label,
    required this.transcript,
    required this.events,
    required this.listening,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                JarvisOrb(
                  state: listening ? OrbState.listening : OrbState.thinking,
                  amplitude: listening ? 0.85 : 0,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF111827),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: progress == 0 ? null : progress,
                backgroundColor: const Color(0xFFE5E7EB),
                color: const Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 12),
            if (transcript.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  'Transcript: $transcript',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    height: 1.4,
                  ),
                ),
              ),
            if (events.isNotEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(height: 140, child: ActivityFeed(events: events)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivateBar extends StatelessWidget {
  final bool listening;
  final bool running;
  final VoidCallback onTap;

  const _ActivateBar({
    required this.listening,
    required this.running,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = listening ? const Color(0xFF22C55E) : const Color(0xFF16A34A);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 14,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          listening
              ? Icons.stop_rounded
              : running
              ? Icons.auto_awesome
              : Icons.graphic_eq_rounded,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }
}

class _WaveformSheet extends StatelessWidget {
  final bool visible;
  final double amplitude;

  const _WaveformSheet({required this.visible, required this.amplitude});

  @override
  Widget build(BuildContext context) {
    final height = math.max(180.0, MediaQuery.of(context).size.height * 0.2);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 280),
          offset: visible ? Offset.zero : const Offset(0, 1.05),
          curve: Curves.easeOutCubic,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xE6111827),
                  const Color(0xE60F172A),
                  const Color(0xF0020617),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(32),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 56,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    "I'm listening. Please retry the action now so I can capture the system state.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Center(child: _WaveformBars(amplitude: amplitude)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformBars extends StatefulWidget {
  final double amplitude;

  const _WaveformBars({required this.amplitude});

  @override
  State<_WaveformBars> createState() => _WaveformBarsState();
}

class _WaveformBarsState extends State<_WaveformBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
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
        final bars = List.generate(18, (index) {
          final phase = (_controller.value * math.pi * 2) + index * 0.42;
          final swing = (math.sin(phase) + 1) / 2;
          final amp = widget.amplitude.clamp(0.08, 1.0);
          final height = 16 + (swing * 44) + (amp * 26);
          return Container(
            width: 8,
            height: height,
            decoration: BoxDecoration(
              color: Color.lerp(
                const Color(0xFF38BDF8),
                const Color(0xFF67E8F9),
                swing,
              ),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF67E8F9).withValues(alpha: 0.35),
                  blurRadius: 12,
                ),
              ],
            ),
          );
        });
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final bar in bars) ...[bar, const SizedBox(width: 6)],
          ],
        );
      },
    );
  }
}

class _SuccessOverlay extends StatefulWidget {
  final String issueId;
  final VoidCallback onDismiss;

  const _SuccessOverlay({required this.issueId, required this.onDismiss});

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
                const Color(0xFF38BDF8).withValues(alpha: 0.24 * pulse),
                const Color(0xFF082F49),
                const Color(0xFF020617),
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
                      painter: _CheckPainter(color: const Color(0xFF38BDF8)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Issue Pushed to Engineering!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'ID: ${widget.issueId}',
                    style: const TextStyle(
                      color: Color(0xFFBAE6FD),
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Status: Our team is on it. We've reserved your place in the queue.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "The GitHub issue is live. No typing, no screenshots, just a 15-second interaction.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFE0F2FE), height: 1.45),
                  ),
                  const SizedBox(height: 26),
                  FilledButton.icon(
                    onPressed: widget.onDismiss,
                    icon: const Icon(Icons.replay),
                    label: const Text('Run The Demo Again'),
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
