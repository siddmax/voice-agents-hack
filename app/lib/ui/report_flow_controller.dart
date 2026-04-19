import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sdk/feedback_analyzer.dart';
import '../sdk/github_issue_service.dart';
import '../sdk/screen_recording_capture.dart';
import '../voice/audio_recorder.dart';

enum ReportFlowState {
  idle,
  choosingMode,
  recordingFeedback,
  analyzingFeedback,
  feedbackPreview,
  recordingRepro,
  analyzingRepro,
  reproPreview,
  submitting,
  done,
  error,
}

enum ReportMode { feedback, bugRepro }

class ReproContext {
  final String selectedSeat;
  final String deviceInfo;
  final String log;
  final String sessionSummary;
  final BugReproEvidence? evidence;

  const ReproContext({
    required this.selectedSeat,
    required this.deviceInfo,
    required this.log,
    this.sessionSummary = '',
    this.evidence,
  });
}

class ReportFlowController extends ChangeNotifier {
  ReportFlowController({
    required PcmCapture recorder,
    required ScreenRecordingCapture screenRecorder,
    required GitHubIssueService issueService,
    required Future<String?> Function(Uint8List pcm) transcribe,
    required Future<FeedbackReport> Function(
      String transcript,
      Uint8List? pcmData,
      void Function(String activity)? onProgress,
    )
    analyzeFeedback,
    required ReproContext Function() reproContext,
  }) : _recorder = recorder,
       _screenRecorder = screenRecorder,
       _issueService = issueService,
       _transcribe = transcribe,
       _analyzeFeedback = analyzeFeedback,
       _reproContext = reproContext;

  final PcmCapture _recorder;
  final ScreenRecordingCapture _screenRecorder;
  ScreenRecordingCapture get screenRecorder => _screenRecorder;
  final GitHubIssueService _issueService;
  final Future<String?> Function(Uint8List pcm) _transcribe;
  final Future<FeedbackReport> Function(
    String transcript,
    Uint8List? pcmData,
    void Function(String activity)? onProgress,
  )
  _analyzeFeedback;
  final ReproContext Function() _reproContext;

  ReportFlowState _state = ReportFlowState.idle;
  ReportFlowState get state => _state;

  ReportMode? _mode;
  ReportMode? get mode => _mode;

  String _transcript = '';
  String get transcript => _transcript;

  double _amplitude = 0;
  double get amplitude => _amplitude;

  FeedbackReport? _feedbackReport;
  FeedbackReport? get feedbackReport => _feedbackReport;

  BugReproReport? _bugReport;
  BugReproReport? get bugReport => _bugReport;

  String? _videoPath;
  String? get videoPath => _videoPath;

  String? _videoCaptureNote;
  String? get videoCaptureNote => _videoCaptureNote;

  String? _issueUrl;
  String? get issueUrl => _issueUrl;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _agentActivity = 'Agent thinking';
  String get agentActivity => _agentActivity;

  StreamSubscription<double>? _levelSub;
  Timer? _maxTimer;
  DateTime? _recordingStartedAt;
  DateTime? _recordingFinishedAt;

  void openChooser() {
    if (_state != ReportFlowState.idle) return;
    _resetPayload();
    _state = ReportFlowState.choosingMode;
    notifyListeners();
  }

  Future<void> chooseFeedback() async {
    if (_state != ReportFlowState.choosingMode) return;
    _mode = ReportMode.feedback;
    await _startAudioOnly();
  }

  Future<void> chooseBugRepro() async {
    if (_state != ReportFlowState.choosingMode) return;
    _mode = ReportMode.bugRepro;
    _state = ReportFlowState.recordingRepro;
    _recordingStartedAt = DateTime.now().toUtc();
    _recordingFinishedAt = null;
    notifyListeners();

    final screenStarted = await _screenRecorder.start();
    final audioStarted = await _startRecorderOnly();
    if (!audioStarted) {
      await _screenRecorder.cancel();
      _fail('Microphone permission is disabled or unavailable.');
      return;
    }
    if (!screenStarted) {
      await _recorder.cancel();
      await _levelSub?.cancel();
      _levelSub = null;
      _fail('Screen recording permission was not granted.');
      return;
    }
    _maxTimer = Timer(const Duration(seconds: 60), () {
      unawaited(finishBugRepro());
    });
  }

  Future<void> finishFeedback() async {
    if (_state != ReportFlowState.recordingFeedback) return;
    _state = ReportFlowState.analyzingFeedback;
    _agentActivity = 'Agent transcribing';
    notifyListeners();

    final pcm = await _stopAudio();
    final transcript = await _transcribePcm(pcm);
    if (transcript.isEmpty) {
      _fail('Could not transcribe that. Try again and speak a bit longer.');
      return;
    }

    _transcript = transcript;
    try {
      _setAgentActivity('Agent thinking');
      _feedbackReport = await _analyzeFeedback(
        transcript,
        pcm,
        _setAgentActivity,
      );
    } catch (_) {
      _setAgentActivity('Agent summarizing');
      _feedbackReport = FeedbackReport.fallback(transcript);
    }
    _state = ReportFlowState.feedbackPreview;
    notifyListeners();
  }

  Future<void> finishBugRepro() async {
    if (_state != ReportFlowState.recordingRepro) return;
    _state = ReportFlowState.analyzingRepro;
    _agentActivity = 'Agent transcribing';
    notifyListeners();

    _maxTimer?.cancel();
    _maxTimer = null;
    _recordingFinishedAt = DateTime.now().toUtc();
    final results = await Future.wait<Object?>([_stopAudio(), _stopScreen()]);
    final pcm = results[0] as Uint8List?;
    _videoPath = results[1] as String?;
    final transcript = await _transcribePcm(pcm);
    if (transcript.isEmpty) {
      _fail(
        'Could not transcribe the reproduction. Try again and narrate each step.',
      );
      return;
    }

    final ctx = _reproContext();
    _transcript = transcript;
    _setAgentActivity('Agent using screen recording');
    _bugReport = BugReproReport.fromEvidence(
      ctx.evidence ??
          BugReproEvidence(
            selectedSeat: ctx.selectedSeat,
            userActions: [
              if (ctx.selectedSeat.trim().isNotEmpty)
                'Select ${ctx.selectedSeat} from the ticket list.',
            ],
          ),
      narrationTranscript: transcript,
      videoPath: _videoPath,
      videoUploadNote: _videoCaptureNote,
    );
    _state = ReportFlowState.reproPreview;
    notifyListeners();
  }

  Future<void> retake() async {
    await _cleanupRecording();
    _transcript = '';
    _feedbackReport = null;
    _bugReport = null;
    _videoPath = null;
    _videoCaptureNote = null;
    if (_mode == ReportMode.feedback) {
      await _startAudioOnly();
    } else if (_mode == ReportMode.bugRepro) {
      _state = ReportFlowState.choosingMode;
      await chooseBugRepro();
    } else {
      _state = ReportFlowState.choosingMode;
      notifyListeners();
    }
  }

  Future<void> submit() async {
    if (_state != ReportFlowState.feedbackPreview &&
        _state != ReportFlowState.reproPreview) {
      return;
    }
    if (!_issueService.isReady) {
      _fail(_issueService.readinessMessage);
      return;
    }

    _state = ReportFlowState.submitting;
    _agentActivity = 'Agent using GitHub';
    notifyListeners();

    try {
      final mode = _mode;
      if (mode == ReportMode.feedback) {
        final report = _feedbackReport!;
        final submission = await _issueService.submit(
          GitHubIssueRequest(
            title: 'Feedback: ${_titleFrom(report.summary)}',
            body: _formatFeedbackBody(report),
            labels: [
              'feedback',
              'voicebug',
              'sentiment:${report.sentiment.label}',
            ],
          ),
        );
        _issueUrl = submission.url;
      } else {
        final report = _bugReport!;
        String? videoUrl;
        String? uploadNote;
        if (report.videoPath != null) {
          _setAgentActivity('Agent using video upload');
          videoUrl = await _issueService.uploadVideoFile(report.videoPath!);
          if (videoUrl == null) {
            uploadNote =
                _issueService.lastUploadError ??
                'Video upload unavailable. The local recording was captured but could not be attached.';
          }
        } else {
          uploadNote =
              report.videoUploadNote ??
              _videoCaptureNote ??
              'ReplayKit did not return a local recording path.';
        }
        final hydrated = BugReproReport(
          title: report.title,
          summary: report.summary,
          steps: report.steps,
          expectedBehavior: report.expectedBehavior,
          actualBehavior: report.actualBehavior,
          severity: report.severity,
          observedSignals: report.observedSignals,
          narrationTranscript: report.narrationTranscript,
          videoPath: report.videoPath,
          videoUrl: videoUrl,
          videoUploadNote: uploadNote,
        );
        _bugReport = hydrated;
        _setAgentActivity('Agent using GitHub');
        final submission = await _issueService.submit(
          GitHubIssueRequest(
            title: 'Bug: ${hydrated.title}',
            body: _formatBugBody(hydrated, _reproContext()),
            labels: ['bug', 'voicebug', 'severity:${hydrated.severity}'],
          ),
        );
        _issueUrl = submission.url;
      }
      _state = ReportFlowState.done;
    } on GitHubIssueFailure catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('Submission failed: $e');
    }
    notifyListeners();
  }

  void _setAgentActivity(String activity) {
    if (_agentActivity == activity) return;
    _agentActivity = activity;
    notifyListeners();
  }

  Future<void> cancel() async {
    await _cleanupRecording();
    _resetPayload();
    _state = ReportFlowState.idle;
    notifyListeners();
  }

  Future<void> _startAudioOnly() async {
    _state = ReportFlowState.recordingFeedback;
    notifyListeners();
    final started = await _startRecorderOnly();
    if (!started) {
      _fail('Microphone permission is disabled or unavailable.');
    }
  }

  Future<bool> _startRecorderOnly() async {
    final started = await _recorder.startRecording();
    if (!started) return false;
    _levelSub = _recorder.amplitude.listen((level) {
      _amplitude = level;
      notifyListeners();
    });
    return true;
  }

  Future<Uint8List?> _stopAudio() async {
    final sub = _levelSub;
    _levelSub = null;
    if (sub != null) unawaited(sub.cancel());
    _amplitude = 0;
    return _recorder.stopAndGetPcm().catchError((_) => null);
  }

  Future<String> _transcribePcm(Uint8List? pcm) async {
    if (pcm == null || pcm.isEmpty) return '';
    try {
      final transcript = (await _transcribe(pcm))?.trim();
      if (transcript != null && transcript.isNotEmpty) return transcript;
    } catch (_) {
      return '';
    }
    return '';
  }

  Future<String?> _stopScreen() async {
    String? path;
    try {
      path = await _screenRecorder.stop();
    } catch (error) {
      _videoCaptureNote = error.toString();
      return null;
    }
    if (path == null || path.trim().isEmpty) {
      _videoCaptureNote =
          _screenRecorder.lastError ??
          'Screen recording stopped without returning a local file path.';
      return null;
    }
    _videoCaptureNote = null;
    return path;
  }

  Future<void> _cleanupRecording() async {
    _maxTimer?.cancel();
    _maxTimer = null;
    await _levelSub?.cancel();
    _levelSub = null;
    await _recorder.cancel();
    await _screenRecorder.cancel();
    _amplitude = 0;
  }

  void _fail(String message) {
    _errorMessage = message;
    _state = ReportFlowState.error;
    notifyListeners();
  }

  void _resetPayload() {
    _mode = null;
    _transcript = '';
    _feedbackReport = null;
    _bugReport = null;
    _videoPath = null;
    _videoCaptureNote = null;
    _recordingStartedAt = null;
    _recordingFinishedAt = null;
    _issueUrl = null;
    _errorMessage = null;
    _agentActivity = 'Agent thinking';
    _amplitude = 0;
  }

  String _formatFeedbackBody(FeedbackReport report) {
    final offer = report.offer == null ? '' : '\n**Offer:** ${report.offer}\n';
    final themes = report.themes.isEmpty
        ? 'None extracted'
        : report.themes.map((theme) => '- $theme').join('\n');
    final painPoints = report.painPoints.isEmpty
        ? 'None extracted'
        : report.painPoints.map((point) => '- $point').join('\n');
    final evidence = report.evidence.isEmpty
        ? 'None extracted'
        : report.evidence
              .map(
                (item) =>
                    '- ${item.polarity} (${item.strength}): "${item.quote}"',
              )
              .join('\n');
    final resolution = _formatFeedbackResolution(report);
    return '''## Voice Feedback

**Sentiment:** ${report.sentiment.label}
**Sentiment score:** ${report.sentimentScore.toStringAsFixed(2)}
**Confidence:** ${report.sentimentConfidence.toStringAsFixed(2)}
**Category:** ${report.category}
**Praise present:** ${report.praisePresent ? 'yes' : 'no'}
**Complaints present:** ${report.complaintsPresent ? 'yes' : 'no'}
**Request present:** ${report.requestPresent ? 'yes' : 'no'}
$offer
### Summary
${report.summary}

### Themes
$themes

### Pain Points
$painPoints

### Evidence
$evidence

### Requested Outcome
${report.requestedOutcome.isEmpty ? 'Not specified' : report.requestedOutcome}

### Actionable Insight
${report.actionableInsight}

$resolution

<details>
<summary>Plain voice transcript</summary>

${report.plainTranscript}

</details>

---
*Feedback captured by voice. Transcript and structured feedback sent to GitHub. No raw audio stored.*''';
  }

  String _formatFeedbackResolution(FeedbackReport report) {
    final resolution = report.resolution;
    if (resolution == null || !resolution.isNotEmpty) return '';
    final articles = resolution.matches.isEmpty
        ? 'None'
        : resolution.matches
              .map(
                (match) =>
                    '- ${match.article.title} (${match.article.sourcePath})',
              )
              .join('\n');
    final customerSteps = resolution.customerSteps.isEmpty
        ? 'None'
        : resolution.customerSteps.map((step) => '- $step').join('\n');
    final teamActions = resolution.teamActions.isEmpty
        ? 'None'
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

  String _formatBugBody(BugReproReport report, ReproContext context) {
    final video = _formatVideoEvidence(report);
    final signals = report.observedSignals.isEmpty
        ? 'None extracted'
        : report.observedSignals.map((signal) => '- $signal').join('\n');
    final steps = report.steps
        .asMap()
        .entries
        .map((entry) => '${entry.key + 1}. ${entry.value}')
        .join('\n');
    return '''## Bug Reproduction

**Severity:** ${report.severity}
**Selected seat:** ${context.selectedSeat}
${context.sessionSummary.isEmpty ? '' : '**Session:** ${context.sessionSummary}\n'}

### Summary
${report.summary}

### Steps To Reproduce
$steps

### Expected
${report.expectedBehavior}

### Actual
${report.actualBehavior}

### Observed Signals
$signals

### Video Evidence
$video

### Capture Timeline
${_formatCaptureTimeline(report.videoPath)}

### Device & App Context
${context.deviceInfo}

### Session Evidence
```json
${context.log}
```

<details>
<summary>Voice narration transcript</summary>

${report.narrationTranscript}

</details>

---
*Bug report compiled from voice narration and screen recording. No raw standalone audio stored.*''';
  }

  String _formatVideoEvidence(BugReproReport report) {
    final lines = <String>[];
    if (report.videoUrl != null) {
      lines.add('- Status: uploaded');
      lines.add('- Recording: [screen recording](${report.videoUrl})');
    } else {
      lines.add('- Status: upload unavailable');
      lines.add('- Reason: ${report.videoUploadNote ?? 'No video attached.'}');
    }
    if (report.videoPath != null && report.videoPath!.isNotEmpty) {
      lines.add('- Local path captured by app: `${report.videoPath}`');
    }
    return lines.join('\n');
  }

  String _formatCaptureTimeline(String? videoPath) {
    final started = _recordingStartedAt?.toIso8601String() ?? 'unknown';
    final finished = _recordingFinishedAt?.toIso8601String() ?? 'unknown';
    final duration = _recordingStartedAt != null && _recordingFinishedAt != null
        ? '${_recordingFinishedAt!.difference(_recordingStartedAt!).inMilliseconds} ms'
        : 'unknown';
    return '''| Field | Value |
|---|---|
| started_at_utc | $started |
| finished_at_utc | $finished |
| duration | $duration |
| video_path_returned | ${videoPath == null || videoPath.isEmpty ? 'no' : 'yes'} |''';
  }

  String _titleFrom(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return 'Voice feedback';
    return cleaned.length > 72 ? '${cleaned.substring(0, 69)}...' : cleaned;
  }

  @override
  void dispose() {
    unawaited(_cleanupRecording());
    super.dispose();
  }
}
