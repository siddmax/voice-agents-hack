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

  const ReproContext({
    required this.selectedSeat,
    required this.deviceInfo,
    required this.log,
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
  final GitHubIssueService _issueService;
  final Future<String?> Function(Uint8List pcm) _transcribe;
  final Future<FeedbackReport> Function(String transcript, Uint8List? pcmData)
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

  String? _issueUrl;
  String? get issueUrl => _issueUrl;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  StreamSubscription<double>? _levelSub;
  Timer? _maxTimer;

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
    notifyListeners();

    final pcm = await _stopAudio();
    final transcript = await _transcribePcm(pcm);
    if (transcript.isEmpty) {
      _fail('Could not transcribe that. Try again and speak a bit longer.');
      return;
    }

    _transcript = transcript;
    try {
      _feedbackReport = await _analyzeFeedback(transcript, pcm);
    } catch (_) {
      _feedbackReport = FeedbackReport.fallback(transcript);
    }
    _state = ReportFlowState.feedbackPreview;
    notifyListeners();
  }

  Future<void> finishBugRepro() async {
    if (_state != ReportFlowState.recordingRepro) return;
    _state = ReportFlowState.analyzingRepro;
    notifyListeners();

    _maxTimer?.cancel();
    _maxTimer = null;
    final results = await Future.wait<Object?>([
      _stopAudio(),
      _screenRecorder.stop().catchError((_) => null),
    ]);
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
    _bugReport = BugReproReport.fromNarration(
      transcript,
      videoPath: _videoPath,
      selectedSeat: ctx.selectedSeat,
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
          videoUrl = await _issueService.uploadVideoFile(report.videoPath!);
          if (videoUrl == null) {
            uploadNote =
                'Video upload unavailable. The local recording was captured but could not be attached.';
          }
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
    _issueUrl = null;
    _errorMessage = null;
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

<details>
<summary>Plain voice transcript</summary>

${report.plainTranscript}

</details>

---
*Feedback captured by voice. Transcript and structured feedback sent to GitHub. No raw audio stored.*''';
  }

  String _formatBugBody(BugReproReport report, ReproContext context) {
    final video = report.videoUrl != null
        ? '[Screen recording](${report.videoUrl})'
        : report.videoUploadNote ?? 'No video attached.';
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

### Device
${context.deviceInfo}

### Log
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
