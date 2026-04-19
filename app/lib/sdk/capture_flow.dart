import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../cactus/engine.dart';
import '../voice/audio_recorder.dart';
import '../voice/stt.dart';
import 'device_metadata.dart';
import 'feedback_analyzer.dart';
import 'github_client.dart';
import 'github_issue_service.dart';
import 'screen_analyzer.dart';
import 'screenshot_capture.dart';

enum CaptureState {
  idle,
  choosing,
  listening,
  transcribing,
  transcriptPreview,
  analyzingFeedback,
  feedbackResult,
  couponOffer,
  recording,
  analyzingBugRepro,
  bugReproPreview,
  submitting,
  done,
  error,
}

enum CaptureMode { feedback, bugRepro }

class CaptureFlowController extends ChangeNotifier {
  final CactusEngine engine;
  final SpeechToTextService stt;
  final GitHubClient github;
  final GitHubIssueService issueService;
  final ScreenshotCapture screenshot;
  final ScreenAnalyzer analyzer;
  final FeedbackAnalyzer feedbackAnalyzer;
  final PcmCapture _recorder;

  CaptureState _state = CaptureState.idle;
  CaptureState get state => _state;

  CaptureMode? _mode;
  CaptureMode? get mode => _mode;

  BugReport? _report;
  BugReport? get report => _report;

  FeedbackReport? _feedbackReport;
  FeedbackReport? get feedbackReport => _feedbackReport;

  BugReproReport? _bugReproReport;
  BugReproReport? get bugReproReport => _bugReproReport;

  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  Uint8List? _pcmData;

  DeviceMetadata? _metadata;
  DeviceMetadata? get metadata => _metadata;

  String? _issueUrl;
  String? get issueUrl => _issueUrl;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _agentActivity = 'Agent thinking';
  String get agentActivity => _agentActivity;

  String _partialTranscript = '';
  String get partialTranscript => _partialTranscript;

  String _transcript = '';
  String get transcript => _transcript;

  bool _screenshotFailed = false;
  bool get screenshotFailed => _screenshotFailed;

  StreamSubscription<double>? _levelSub;
  double _soundLevel = 0.0;
  double get soundLevel => _soundLevel;

  DateTime? _recordingStart;
  Duration get recordingDuration => _recordingStart != null
      ? DateTime.now().difference(_recordingStart!)
      : Duration.zero;

  CaptureFlowController({
    required this.engine,
    required this.stt,
    required this.github,
    GitHubIssueService? issueService,
    required this.screenshot,
    PcmCapture? recorder,
  }) : issueService = issueService ?? GitHubIssueService(client: github),
       analyzer = ScreenAnalyzer(engine),
       feedbackAnalyzer = FeedbackAnalyzer(engine),
       _recorder = recorder ?? PcmRecorder();

  void showChooser() {
    if (_state != CaptureState.idle) return;
    _resetFields();
    _state = CaptureState.choosing;
    notifyListeners();
  }

  void chooseMode(CaptureMode mode) {
    if (_state != CaptureState.choosing) return;
    _mode = mode;
    if (mode == CaptureMode.feedback) {
      _startFeedbackFlow();
    } else {
      _startBugReproFlow();
    }
  }

  // ── Feedback flow (voice only) ──────────────────────────────────────────

  Future<void> _startFeedbackFlow() async {
    _state = CaptureState.listening;
    _pcmData = null;
    notifyListeners();

    unawaited(_recorder.startRecording().catchError((_) => false));

    _levelSub = stt.soundLevel.listen((level) {
      _soundLevel = level;
      notifyListeners();
    });

    final result = await stt.startListening(
      onPartial: (partial) {
        _partialTranscript = partial;
        notifyListeners();
      },
    );

    if (result != SttStartResult.started) {
      _levelSub?.cancel();
      _levelSub = null;
      _state = CaptureState.error;
      _errorMessage = result == SttStartResult.permissionDenied
          ? 'Microphone permission denied'
          : 'Speech recognition unavailable';
      notifyListeners();
    }
  }

  Future<void> stopListeningAndShowTranscript() async {
    if (_state != CaptureState.listening) return;

    _state = CaptureState.transcribing;
    notifyListeners();

    final results = await Future.wait([
      stt.stopListening(),
      _recorder.stopAndGetPcm().catchError((_) => null),
    ]);
    _transcript = results[0] as String;
    _pcmData = results[1] as Uint8List?;
    _levelSub?.cancel();
    _levelSub = null;
    _soundLevel = 0.0;

    if (_transcript.trim().isEmpty) {
      _state = CaptureState.error;
      _errorMessage = 'No speech detected. Try again.';
      notifyListeners();
      return;
    }

    _state = CaptureState.transcriptPreview;
    notifyListeners();
  }

  void retakeRecording() {
    _transcript = '';
    _partialTranscript = '';
    _pcmData = null;
    if (_mode == CaptureMode.feedback) {
      _startFeedbackFlow();
    } else {
      _startBugReproFlow();
    }
  }

  Future<void> submitFeedback() async {
    if (_state != CaptureState.transcriptPreview ||
        _mode != CaptureMode.feedback) {
      return;
    }

    _state = CaptureState.analyzingFeedback;
    _agentActivity = 'Agent thinking';
    notifyListeners();

    _feedbackReport = await feedbackAnalyzer
        .analyzeFeedback(
          transcript: _transcript,
          pcmData: _pcmData,
          onProgress: _setAgentActivity,
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => FeedbackReport.fallback(_transcript),
        );

    if (_feedbackReport!.offerCoupon) {
      _state = CaptureState.couponOffer;
    } else {
      _state = CaptureState.feedbackResult;
    }
    notifyListeners();
  }

  void dismissCoupon() {
    _state = CaptureState.feedbackResult;
    notifyListeners();
  }

  Future<void> submitFeedbackToGitHub() async {
    if (_state != CaptureState.feedbackResult) return;

    _state = CaptureState.submitting;
    _agentActivity = 'Agent using GitHub';
    notifyListeners();

    try {
      final fb = _feedbackReport!;
      final body = _formatFeedbackBody(fb);

      final submission = await issueService.submit(
        GitHubIssueRequest(
          title:
              '\u{1F4AC} Feedback: ${fb.summary.length > 60 ? '${fb.summary.substring(0, 57)}...' : fb.summary}',
          body: body,
          labels: [
            'feedback',
            'sentiment:${fb.sentiment.label}',
            'category:${fb.category}',
          ],
        ),
      );
      _issueUrl = submission.url;
      _state = CaptureState.done;
    } on GitHubIssueFailure catch (e) {
      _state = CaptureState.error;
      _errorMessage = e.message;
    } catch (e) {
      _state = CaptureState.error;
      _errorMessage = 'Submission failed: $e';
    }
    notifyListeners();
  }

  // ── Bug reproduction flow (record + voice) ──────────────────────────────

  Future<void> _startBugReproFlow() async {
    _state = CaptureState.recording;
    _recordingStart = DateTime.now();
    _pcmData = null;
    notifyListeners();

    unawaited(_recorder.startRecording().catchError((_) => false));

    _levelSub = stt.soundLevel.listen((level) {
      _soundLevel = level;
      notifyListeners();
    });

    final result = await stt.startListening(
      onPartial: (partial) {
        _partialTranscript = partial;
        notifyListeners();
      },
    );

    if (result != SttStartResult.started) {
      _levelSub?.cancel();
      _levelSub = null;
      _state = CaptureState.error;
      _errorMessage = result == SttStartResult.permissionDenied
          ? 'Microphone permission denied'
          : 'Speech recognition unavailable';
      notifyListeners();
    }

    _screenshotBytes = await screenshot.capture();
    _screenshotFailed = _screenshotBytes == null;
  }

  Future<void> stopRecordingAndAnalyze() async {
    if (_state != CaptureState.recording) return;

    _state = CaptureState.analyzingBugRepro;
    _agentActivity = 'Agent transcribing';
    _recordingStart = null;
    notifyListeners();

    final results = await Future.wait([
      stt.stopListening(),
      _recorder.stopAndGetPcm().catchError((_) => null),
    ]);
    _transcript = results[0] as String;
    _pcmData = results[1] as Uint8List?;
    _levelSub?.cancel();
    _levelSub = null;
    _soundLevel = 0.0;

    if (_transcript.trim().isEmpty) {
      _state = CaptureState.error;
      _errorMessage = 'No speech detected during recording. Try again.';
      notifyListeners();
      return;
    }

    _setAgentActivity('Agent summarizing');
    _bugReproReport = await feedbackAnalyzer
        .analyzeBugRepro(transcript: _transcript, pcmData: _pcmData)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => BugReproReport.fallback(_transcript),
        );

    _state = CaptureState.bugReproPreview;
    notifyListeners();
  }

  Future<void> submitBugRepro() async {
    if (_state != CaptureState.bugReproPreview || _bugReproReport == null) {
      return;
    }

    _state = CaptureState.submitting;
    _agentActivity = 'Agent using GitHub';
    notifyListeners();

    try {
      String? screenshotUrl;
      if (_screenshotBytes != null) {
        _setAgentActivity('Agent using screenshot upload');
        screenshotUrl = await github.uploadScreenshot(_screenshotBytes!);
      }

      final br = _bugReproReport!;
      final body = _formatBugReproBody(br, screenshotUrl);

      _setAgentActivity('Agent using GitHub');
      final submission = await issueService.submit(
        GitHubIssueRequest(
          title: '\u{1F41B} ${br.title}',
          body: body,
          labels: ['bug', 'voicebug', 'severity:${br.severity}'],
        ),
      );
      _issueUrl = submission.url;
      _state = CaptureState.done;
    } on GitHubIssueFailure catch (e) {
      _state = CaptureState.error;
      _errorMessage = e.message;
    } catch (e) {
      _state = CaptureState.error;
      _errorMessage = 'Submission failed: $e';
    }
    notifyListeners();
  }

  // ── Shared ──────────────────────────────────────────────────────────────

  void _setAgentActivity(String activity) {
    if (_agentActivity == activity) return;
    _agentActivity = activity;
    notifyListeners();
  }

  void updateReport(BugReport updated) {
    _report = updated;
    notifyListeners();
  }

  void cancel() {
    _levelSub?.cancel();
    _levelSub = null;
    if (stt.isListening) stt.cancel();
    _recorder.cancel();
    _resetFields();
    _state = CaptureState.idle;
    notifyListeners();
  }

  void reset() => cancel();

  void _resetFields() {
    _report = null;
    _feedbackReport = null;
    _bugReproReport = null;
    _screenshotBytes = null;
    _pcmData = null;
    _issueUrl = null;
    _errorMessage = null;
    _partialTranscript = '';
    _transcript = '';
    _agentActivity = 'Agent thinking';
    _soundLevel = 0.0;
    _screenshotFailed = false;
    _mode = null;
    _recordingStart = null;
  }

  @override
  void dispose() {
    cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Formatting ──────────────────────────────────────────────────────────

  String _formatFeedbackBody(FeedbackReport fb) {
    final themesStr = fb.themes.isNotEmpty
        ? fb.themes.map((t) => '- $t').join('\n')
        : '- No specific themes extracted';
    final evidenceStr = fb.evidence.isNotEmpty
        ? fb.evidence
              .map((e) => '- ${e.polarity} (${e.strength}): "${e.quote}"')
              .join('\n')
        : '- No transcript-bound evidence extracted';
    final resolutionStr = _formatFeedbackResolution(fb);

    return '''## User Feedback (Voice Capture)

**Sentiment:** ${_sentimentEmoji(fb.sentiment)} ${fb.sentiment.label.toUpperCase()} (${(fb.sentimentScore * 100).round()}%)
**Emotional Tone:** ${fb.emotionalTone}
**Category:** ${fb.category}
**Praise present:** ${fb.praisePresent ? 'yes' : 'no'}
**Complaints present:** ${fb.complaintsPresent ? 'yes' : 'no'}
**Request present:** ${fb.requestPresent ? 'yes' : 'no'}

---

### Summary
${fb.summary}

### Key Themes
$themesStr

### Evidence
$evidenceStr

### Actionable Insight
${fb.actionableInsight.isNotEmpty ? fb.actionableInsight : 'No specific action recommended.'}

$resolutionStr

---

<details>
<summary>Raw voice transcript</summary>

$_transcript

</details>

${fb.offerCoupon ? '\n> \u{1F3AB} **Coupon offered:** 10% off next ticket purchase (negative or mixed-negative sentiment detected)\n' : ''}
---
*Feedback captured via voice and analyzed on-device. No raw audio stored.*''';
  }

  String _formatFeedbackResolution(FeedbackReport fb) {
    final resolution = fb.resolution;
    if (resolution == null || !resolution.isNotEmpty) return '';
    final articles = resolution.matches.isEmpty
        ? '- None'
        : resolution.matches
              .map(
                (match) =>
                    '- ${match.article.title} (${match.article.sourcePath})',
              )
              .join('\n');
    final customerSteps = resolution.customerSteps.isEmpty
        ? '- None'
        : resolution.customerSteps.map((step) => '- $step').join('\n');
    final teamActions = resolution.teamActions.isEmpty
        ? '- None'
        : resolution.teamActions.map((action) => '- $action').join('\n');
    return '''### Local KB Resolution
${resolution.summary}

**Matched articles**
$articles

**Customer next steps**
$customerSteps

**Team next steps**
$teamActions''';
  }

  String _formatBugReproBody(BugReproReport br, String? screenshotUrl) {
    final stepsStr = br.steps
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value}')
        .join('\n');

    final screenshotSection = screenshotUrl != null
        ? '![screenshot]($screenshotUrl)'
        : '*No screenshot captured*';

    return '''## Bug Report (Voice + Screen Capture)

**Severity:** ${br.severity.toUpperCase()}

---

### Steps to Reproduce
$stepsStr

### Expected Behavior
${br.expectedBehavior.isNotEmpty ? br.expectedBehavior : 'Not specified'}

### Actual Behavior
${br.actualBehavior.isNotEmpty ? br.actualBehavior : 'Not specified'}

### Screenshot
$screenshotSection

---

<details>
<summary>Raw voice narration</summary>

$_transcript

</details>

---
*Bug report compiled from voice narration and screen capture. Analyzed on-device.*''';
  }

  static String _sentimentEmoji(Sentiment s) => switch (s) {
    Sentiment.positive => '\u{1F60A}',
    Sentiment.neutral => '\u{1F610}',
    Sentiment.mixedNegative => '\u{1F615}',
    Sentiment.negative => '\u{1F61E}',
  };
}
