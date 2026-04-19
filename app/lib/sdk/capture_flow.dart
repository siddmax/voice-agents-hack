import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../cactus/engine.dart';
import '../voice/audio_recorder.dart';
import '../voice/stt.dart';
import 'device_metadata.dart';
import 'github_client.dart';
import 'screen_analyzer.dart';
import 'screenshot_capture.dart';

enum CaptureState { idle, listening, analyzing, previewing, submitting, done, error }

class CaptureFlowController extends ChangeNotifier {
  final CactusEngine engine;
  final SpeechToTextService stt;
  final GitHubClient github;
  final ScreenshotCapture screenshot;
  final ScreenAnalyzer analyzer;
  final PcmRecorder _recorder;

  CaptureState _state = CaptureState.idle;
  CaptureState get state => _state;

  BugReport? _report;
  BugReport? get report => _report;

  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  Uint8List? _pcmData;

  DeviceMetadata? _metadata;
  DeviceMetadata? get metadata => _metadata;

  String? _issueUrl;
  String? get issueUrl => _issueUrl;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _partialTranscript = '';
  String get partialTranscript => _partialTranscript;

  String _transcript = '';
  String get transcript => _transcript;

  bool _screenshotFailed = false;
  bool get screenshotFailed => _screenshotFailed;

  StreamSubscription<double>? _levelSub;
  double _soundLevel = 0.0;
  double get soundLevel => _soundLevel;

  CaptureFlowController({
    required this.engine,
    required this.stt,
    required this.github,
    required this.screenshot,
    PcmRecorder? recorder,
  })  : _recorder = recorder ?? PcmRecorder(),
        analyzer = ScreenAnalyzer(engine);

  Future<void> startCapture(BuildContext context) async {
    if (_state != CaptureState.idle) return;

    _report = null;
    _issueUrl = null;
    _errorMessage = null;
    _partialTranscript = '';
    _transcript = '';
    _screenshotFailed = false;

    // Capture screen resolution before any async gap.
    final mq = MediaQuery.of(context);
    final size = mq.size * mq.devicePixelRatio;
    final screenRes = '${size.width.toInt()}x${size.height.toInt()}';

    _screenshotBytes = await screenshot.capture();
    _screenshotFailed = _screenshotBytes == null;

    _state = CaptureState.listening;
    _pcmData = null;
    notifyListeners();

    // Start PCM recording in parallel (best-effort, don't block STT)
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
      return;
    }

    try {
      _metadata = await DeviceMetadata.collectWithScreen(screenRes);
    } catch (_) {}
  }

  Future<void> stopAndAnalyze() async {
    if (_state != CaptureState.listening) return;

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

    _state = CaptureState.analyzing;
    notifyListeners();

    _report = await analyzer
        .analyze(
          transcript: _transcript,
          screenshotPng: _screenshotBytes,
          pcmData: _pcmData,
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => BugReport.fallback(_transcript),
        );

    _state = CaptureState.previewing;
    notifyListeners();
  }

  void updateReport(BugReport updated) {
    _report = updated;
    notifyListeners();
  }

  Future<void> submit() async {
    if (_state != CaptureState.previewing || _report == null) return;

    _state = CaptureState.submitting;
    notifyListeners();

    try {
      String? screenshotUrl;
      if (_screenshotBytes != null) {
        screenshotUrl = await github.uploadScreenshot(_screenshotBytes!);
      }

      final body = GitHubClient.formatIssueBody(
        severity: _report!.severity,
        description: _report!.description,
        stepsContext: _report!.stepsContext,
        expected: _report!.expected,
        actual: _report!.actual,
        uiState: _report!.uiState,
        deviceTable: _metadata?.toMarkdownTable() ?? 'Not available',
        screenshotUrl: screenshotUrl,
        rawTranscript: _transcript,
      );

      _issueUrl = await github.createIssue(
        title: '\u{1F41B} ${_report!.title}',
        body: body,
        labels: ['bug', 'voicebug', 'severity:${_report!.severity}'],
      );

      if (_issueUrl != null) {
        _state = CaptureState.done;
      } else {
        _state = CaptureState.error;
        _errorMessage = 'Failed to create GitHub Issue. Check your token and repo settings.';
      }
    } catch (e) {
      _state = CaptureState.error;
      _errorMessage = 'GitHub API error: $e';
    }
    notifyListeners();
  }

  void cancel() {
    _levelSub?.cancel();
    _levelSub = null;
    if (stt.isListening) stt.cancel();
    _recorder.cancel();
    _state = CaptureState.idle;
    _report = null;
    _screenshotBytes = null;
    _pcmData = null;
    _issueUrl = null;
    _errorMessage = null;
    _partialTranscript = '';
    _transcript = '';
    _soundLevel = 0.0;
    _screenshotFailed = false;
    notifyListeners();
  }

  void reset() => cancel();

  @override
  void dispose() {
    cancel();
    _recorder.dispose();
    super.dispose();
  }
}
