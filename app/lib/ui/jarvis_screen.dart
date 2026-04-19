import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../agent/agent_service.dart';
import '../sdk/device_metadata.dart';
import '../sdk/feedback_analyzer.dart';
import '../sdk/github_issue_service.dart';
import '../sdk/screen_recording_capture.dart';
import '../sdk/view_capture_recorder.dart';
import '../voice/audio_recorder.dart';
import '../voice/tts.dart';
import 'activity_feed.dart';
import 'app_settings.dart';
import 'chat_controller.dart';
import 'jarvis_orb.dart';
import 'report_flow_controller.dart';
import 'report_flow_overlay.dart';
import 'settings_sheet.dart';

const _demoTranscript =
    "The checkout isn't loading for Section 105. It just stays on the spinner.";
const _demoDeviceInfoTable =
    '| Field | Value |\n'
    '|---|---|\n'
    '| os | Simulator |\n'
    '| device | iPhone 17 Pro |\n'
    '| app_version | 1.0.0 |\n'
    '| screen_resolution | unknown |\n'
    '| locale | unknown |';

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
  final GitHubIssueService? githubIssueService;
  final PcmCapture? recorder;
  final ScreenRecordingCapture? screenRecorder;

  const JarvisScreen({
    super.key,
    this.startupError,
    this.githubIssueService,
    this.recorder,
    this.screenRecorder,
  });

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
  bool _submittingIssue = false;
  String? _issueUrl;
  bool _showSuccess = false;
  bool _completingListening = false;
  bool _deviceMetadataRequested = false;
  String _deviceInfoMarkdown = _demoDeviceInfoTable;
  final DateTime _sessionStartedAt = DateTime.now().toUtc();
  late final GitHubIssueService _githubIssueService;
  late final PcmCapture _recorder;
  late final ReportFlowController _reportFlow;

  @override
  void initState() {
    super.initState();
    _githubIssueService = widget.githubIssueService ?? GitHubIssueService();
    _recorder = widget.recorder ?? PcmRecorder();
    _reportFlow = ReportFlowController(
      recorder: _recorder,
      screenRecorder: widget.screenRecorder ?? ViewCaptureRecorder(),
      issueService: _githubIssueService,
      transcribe: (pcm) {
        final chat = _chatRef;
        if (chat != null) return chat.transcribe(pcm);
        if (!mounted) return Future.value(null);
        return context.read<ChatController>().transcribe(pcm);
      },
      analyzeFeedback: (transcript, pcmData, onProgress) {
        final chat = _chatRef;
        if (chat != null) {
          return chat.analyzeFeedback(
            transcript,
            pcmData: pcmData,
            onProgress: onProgress,
          );
        }
        if (!mounted) {
          onProgress?.call('Agent summarizing');
          return Future.value(FeedbackReport.fromTranscript(transcript));
        }
        return context.read<ChatController>().analyzeFeedback(
          transcript,
          pcmData: pcmData,
          onProgress: onProgress,
        );
      },
      reproContext: () => ReproContext(
        selectedSeat: _selectedSeatLabel(),
        deviceInfo: _deviceInfoMarkdown,
        log: _buildReproLog(),
        sessionSummary:
            'Ticket checkout repro for ${_selectedSeatLabel()} in the Warriors listing.',
        evidence: BugReproEvidence(
          selectedSeat: _selectedSeatLabel(),
          screen: 'Checkout',
          route: '/checkout/seat/select',
          userActions: [
            'Select ${_selectedSeatLabel()} from the ticket list.',
            'Tap Buy Now.',
          ],
          expectedOutcome:
              'Tapping Buy Now should complete the purchase flow or advance to the next checkout step.',
          observedOutcome:
              'An error alert is shown and checkout does not complete.',
          observedSignals: const [
            'Buy Now action was attempted',
            'Error alert or error state appeared',
            'Purchase flow did not complete',
            'Network request checkout.createIntent timed out with LIST_TO_VOID',
          ],
        ),
      ),
    );
    unawaited(_reportFlow.screenRecorder.warmUp());
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
    _collectDeviceMetadata();
    final chat = context.read<ChatController>();
    if (!identical(_chatRef, chat)) {
      _chatRef?.removeListener(_onChatChanged);
      _chatRef = chat;
      chat.addListener(_onChatChanged);
    }
  }

  void _collectDeviceMetadata() {
    if (_deviceMetadataRequested) return;
    _deviceMetadataRequested = true;
    unawaited(
      DeviceMetadata.collect(context).then((metadata) {
        if (!mounted) return;
        setState(() => _deviceInfoMarkdown = metadata.toMarkdownTable());
      }),
    );
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
          !_submittingIssue &&
          _issueUrl == null &&
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
    unawaited(HapticFeedback.heavyImpact());
    unawaited(SystemSound.play(SystemSoundType.click));
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
    if (_issueUrl != null) return 1;
    if (_submittingIssue) return 0.94;
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
    if (_issueUrl != null) return 'GitHub issue created successfully.';
    if (_submittingIssue) return 'Generating GitHub Issue...';
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
      return "I'm listening. Tell me what happened, then tap Finish Capture.";
    }
    return 'Tap the mic to start talking to the agent.';
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
    _reportFlow.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _onAgentTap() async {
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
    chat.clearSession();
    _autoSubmitting = false;
    setState(() {
      _orb = OrbState.idle;
      _showWaveform = false;
      _captureGranted = false;
      _showSuccess = false;
      _transcriptDraft = '';
    });
    _reportFlow.openChooser();
  }

  Future<void> _completeListeningAndAnalyze([String? _]) async {
    if (_completingListening) return;
    _completingListening = true;
    try {
      await _levelSub?.cancel();
      _levelSub = null;
      final pcm = await _recorder.stopAndGetPcm();
      if (!mounted) return;

      if (pcm == null || pcm.isEmpty) {
        setState(() {
          _amplitude = 0;
          _orb = OrbState.idle;
          _showWaveform = false;
          _captureGranted = false;
          _showSuccess = false;
          _transcriptDraft = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No speech captured. Try again when you are ready.'),
          ),
        );
        return;
      }

      final chat = context.read<ChatController>();
      final transcript = (await chat.transcribe(pcm))?.trim() ?? '';
      if (!mounted) return;

      if (transcript.isEmpty) {
        setState(() {
          _amplitude = 0;
          _orb = OrbState.idle;
          _showWaveform = false;
          _captureGranted = false;
          _showSuccess = false;
          _transcriptDraft = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not transcribe that. Try again and speak a bit longer.',
            ),
          ),
        );
        return;
      }

      setState(() {
        _amplitude = 0;
        _orb = OrbState.thinking;
        _showWaveform = false;
        _captureGranted = false;
        _showSuccess = false;
        _transcriptDraft = transcript;
      });
      await _runAgentAnalysis(transcript);
    } finally {
      _completingListening = false;
    }
  }

  Future<void> _cancelListening() async {
    await _recorder.cancel();
    await _levelSub?.cancel();
    _levelSub = null;
    if (!mounted) return;
    setState(() {
      _amplitude = 0;
      _orb = OrbState.idle;
      _showWaveform = false;
      _transcriptDraft = '';
    });
  }

  Future<void> _runAgentAnalysis(String transcript) async {
    final chat = context.read<ChatController>();
    _wasRunning = true;
    if (mounted) {
      setState(() {
        _captureGranted = true;
        _orb = OrbState.thinking;
      });
    }
    await chat.send(
      'Analyze this Ticketmaster checkout failure and prepare a GitHub-ready bug report.\n'
      'Transcript: $transcript\n'
      'Device Info: $_deviceInfoMarkdown\n'
      'The Log: ${_buildReproLog()}\n'
      'Selected Seat: ${_selectedSeatLabel()}\n'
      'Observed Behavior: The list item enters a spinner state and never transitions into checkout.\n'
      'Expected Behavior: Selecting the ticket should open checkout immediately.',
    );
  }

  Future<void> _onSeatTap(_SeatOption seat) async {
    setState(() {
      _selectedSeatId = seat.id;
    });

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CheckoutPage(
          seat: seat,
          reportFlow: _reportFlow,
          onAgentActivate: () async {
            Navigator.of(context).pop();
            await Future<void>.delayed(const Duration(milliseconds: 120));
            if (mounted) await _onAgentTap();
          },
        ),
      ),
    );
  }

  Future<void> _submitIssue() async {
    final chat = context.read<ChatController>();
    if (chat.running || _issueSubmitted(chat.events) || _submittingIssue) {
      return;
    }

    if (!_githubIssueService.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_githubIssueService.readinessMessage)),
      );
      return;
    }

    setState(() {
      _submittingIssue = true;
      _orb = OrbState.thinking;
    });

    final title = 'Warriors checkout hangs for ${_selectedSeatLabel()}';
    final body = _buildGitHubIssueBody();
    final labels = ['bug', 'demo', 'warriors-checkout'];

    try {
      final submission = await _githubIssueService.submit(
        GitHubIssueRequest(title: title, body: body, labels: labels),
      );
      if (!mounted) return;
      setState(() {
        _issueUrl = submission.url;
        _issueId = submission.issueNumber ?? _issueId;
        _submittingIssue = false;
      });
      await _triggerSuccessState();
    } on GitHubIssueFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _submittingIssue = false;
        _orb = OrbState.idle;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submittingIssue = false;
        _orb = OrbState.idle;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('GitHub issue creation failed: $e')),
      );
    }
  }

  @visibleForTesting
  Future<void> submitIssueForTest() => _submitIssue();

  @visibleForTesting
  Future<void> finishCaptureForTest() => _completeListeningAndAnalyze();

  String _buildGitHubIssueBody() {
    final transcript = _transcriptDraft.isEmpty
        ? _demoTranscript
        : _transcriptDraft;
    return '''
## Syndai Bug Report

**Title context:** Warriors checkout hang for ${_selectedSeatLabel()}

**Transcript:**  
$transcript

**Device Info:**  
$_deviceInfoMarkdown

**The Log:**  
```json
${_buildReproLog()}
```

**Selected Seat:**  
${_selectedSeatLabel()}

**Observed Behavior:**  
The list item enters a spinner state and never transitions into checkout.

**Expected Behavior:**  
Selecting the ticket should open checkout immediately.
''';
  }

  String _buildReproLog() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'session': {
        'started_at_utc': _sessionStartedAt.toIso8601String(),
        'reporting_surface': 'voicebug_repro_flow',
        'app_route': '/checkout/seat/select',
      },
      'selected_seat': {'id': _selectedSeatId, 'label': _selectedSeatLabel()},
      'user_actions': [
        'open_report_picker',
        'choose_reproduce_bug',
        'select_ticket:${_selectedSeatLabel()}',
        'tap_buy_now',
      ],
      'ui_state': {
        'screen': 'checkout',
        'primary_cta': 'Buy Now',
        'expected_transition': 'checkout completes or advances',
        'observed_transition': 'error alert shown',
      },
      'network': {
        'operation': 'checkout.createIntent',
        'route': '/checkout/seat/select',
        'seat': _selectedSeatLabel(),
        'status': 'timeout',
        'code': 'LIST_TO_VOID',
      },
      'diagnostics': {
        'capture_mode': 'screen_recording_and_voice_narration',
        'raw_audio_stored': false,
        'screen_recording_expected': true,
      },
    });
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
      _submittingIssue = false;
      _issueUrl = null;
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
                      _VenueMapStrip(selectedSeat: _selectedSeatLabel()),
                      const _FilterRail(),
                      if (!_githubIssueService.isReady)
                        _GitHubReadinessBanner(
                          message: _githubIssueService.readinessMessage,
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
              onFinish: _completeListeningAndAnalyze,
              onCancel: _cancelListening,
            ),
            if (_showSuccess)
              Positioned.fill(
                child: _SuccessOverlay(
                  issueId: _issueId,
                  onDismiss: _resetDemo,
                ),
              ),
            ReportFlowOverlay(controller: _reportFlow),
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

class _GitHubReadinessBanner extends StatelessWidget {
  final String message;

  const _GitHubReadinessBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFDE68A),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFF92400E)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF78350F),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
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

  const _VenueMapStrip({required this.selectedSeat});

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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
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
              child: CustomPaint(painter: _MiniArenaPainter()),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$selectedSeat is selected for the scripted checkout path.',
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
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final basePaint = Paint()..color = const Color(0xFFD1D5DB);
    final accentPaint = Paint()..color = const Color(0xFF93C5FD);
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
  bool shouldRepaint(covariant _MiniArenaPainter oldDelegate) => false;
}

class _FilterRail extends StatelessWidget {
  const _FilterRail();

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
                  const Text(
                    '2 Tickets',
                    style: TextStyle(
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
  final ValueChanged<_SeatOption> onSeatTap;

  const _SeatListCard({
    required this.seats,
    required this.selectedSeatId,
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
  final VoidCallback onTap;

  const _SeatTile({
    required this.seat,
    required this.selected,
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (seat.highlighted)
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
                      seat.highlighted
                          ? 'VIP LOUNGE PACKAGE'
                          : 'Verified Resale Ticket',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
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
                  style: const TextStyle(color: Color(0xFF374151), height: 1.4),
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

// ---------------------------------------------------------------------------
// Checkout page
// ---------------------------------------------------------------------------

class _CheckoutPage extends StatefulWidget {
  final _SeatOption seat;
  final ReportFlowController reportFlow;
  final VoidCallback onAgentActivate;

  const _CheckoutPage({
    required this.seat,
    required this.reportFlow,
    required this.onAgentActivate,
  });

  @override
  State<_CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<_CheckoutPage> {
  bool _buying = false;

  // ── Buy flow ──────────────────────────────────────────────────────────────

  Future<void> _onBuyTap() async {
    if (_buying) return;
    setState(() => _buying = true);
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    setState(() => _buying = false);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Error',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: const Text('Something went wrong. Please try again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final seat = widget.seat;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      body: SafeArea(
        child: Stack(
          children: [
            // ── Main checkout content ────────────────────────────────────
            Column(
              children: [
                _CheckoutTopBar(onBack: () => Navigator.of(context).pop()),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Event card
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Golden State Warriors vs. LA Lakers',
                                style: TextStyle(
                                  color: Color(0xFF111827),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Sat • 8:00 PM • Chase Center',
                                style: TextStyle(
                                  color: Color(0xFF6B7280),
                                  fontSize: 13,
                                ),
                              ),
                              const Divider(height: 24),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.location_on_outlined,
                                    size: 18,
                                    color: Color(0xFF6B7280),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    seat.label,
                                    style: const TextStyle(
                                      color: Color(0xFF111827),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    seat.price,
                                    style: const TextStyle(
                                      color: Color(0xFF2563EB),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Order summary
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Order Summary',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 14),
                              _OrderRow(
                                label: '1x Ticket (${seat.label})',
                                value: seat.price,
                              ),
                              const _OrderRow(
                                label: 'Service fee',
                                value: '\$18.50',
                              ),
                              const _OrderRow(
                                label: 'Facility charge',
                                value: '\$5.00',
                              ),
                              const Divider(height: 20),
                              _OrderRow(
                                label: 'Total',
                                value: _totalPrice(seat.price),
                                bold: true,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Buy button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _buying ? null : _onBuyTap,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF026CDF),
                              disabledBackgroundColor: const Color(0xFF026CDF),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            child: _buying
                                ? const SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: Colors.white54,
                                    ),
                                  )
                                : const Text(
                                    'Buy Now',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // ── Syndai Agent FAB (hidden while panel is open) ────────────
            Positioned(
              bottom: 24,
              right: 16,
              child: _ActivateBar(
                listening: false,
                running: false,
                onTap: widget.onAgentActivate,
              ),
            ),
            ReportFlowOverlay(controller: widget.reportFlow),
          ],
        ),
      ),
    );
  }

  String _totalPrice(String price) {
    final raw =
        double.tryParse(price.replaceAll('\$', '').replaceAll(',', '')) ?? 0;
    return '\$${(raw + 23.50).toStringAsFixed(2)}';
  }
}

class _CheckoutTopBar extends StatelessWidget {
  final VoidCallback onBack;
  const _CheckoutTopBar({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            child: const CircleAvatar(
              radius: 17,
              backgroundColor: Color(0xFF232323),
              child: Icon(Icons.arrow_back, color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 12),
          RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'ticket',
                  style: TextStyle(
                    color: Color(0xFF026CDF),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                TextSpan(
                  text: 'master',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
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

class _OrderRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const _OrderRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: bold ? const Color(0xFF111827) : const Color(0xFF6B7280),
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
              fontSize: bold ? 15 : 14,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: bold ? const Color(0xFF111827) : const Color(0xFF374151),
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              fontSize: bold ? 15 : 14,
            ),
          ),
        ],
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
  final Future<void> Function() onFinish;
  final Future<void> Function() onCancel;

  const _WaveformSheet({
    required this.visible,
    required this.amplitude,
    required this.onFinish,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final height = math.min(
      math.max(260.0, screenHeight * 0.28),
      screenHeight * 0.42,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
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
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 18, 24, 24 + bottomInset),
                child: Column(
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
                      "I'm listening. Tell me what happened, then tap Finish Capture.",
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
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: onCancel,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.28),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: onFinish,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF38BDF8),
                              foregroundColor: const Color(0xFF082F49),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text('Finish Capture'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
