import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../cactus/engine.dart';
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

  CaptureState _state = CaptureState.idle;
  CaptureState get state => _state;

  BugReport? _report;
  BugReport? get report => _report;

  Uint8List? _screenshotBytes;
  Uint8List? get screenshotBytes => _screenshotBytes;

  DeviceMetadata? _metadata;
  DeviceMetadata? get metadata => _metadata;

  String? _issueUrl;
  String? get issueUrl => _issueUrl;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _partialTranscript = '';
  String get partialTranscript => _partialTranscript;

  StreamSubscription<double>? _levelSub;
  double _soundLevel = 0.0;
  double get soundLevel => _soundLevel;

  CaptureFlowController({
    required this.engine,
    required this.stt,
    required this.github,
    required this.screenshot,
  }) : analyzer = ScreenAnalyzer(engine);

  Future<void> startCapture(BuildContext context) async {
    if (_state != CaptureState.idle) return;

    _state = CaptureState.listening;
    _report = null;
    _screenshotBytes = null;
    _issueUrl = null;
    _errorMessage = null;
    _partialTranscript = '';
    notifyListeners();

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
      _state = CaptureState.error;
      _errorMessage = result == SttStartResult.permissionDenied
          ? 'Microphone permission denied'
          : 'Speech recognition unavailable';
      notifyListeners();
      return;
    }

    try {
      _metadata = await DeviceMetadata.collect(context);
    } catch (_) {}
  }

  Future<void> stopAndAnalyze() async {
    if (_state != CaptureState.listening) return;

    final transcript = await stt.stopListening();
    _levelSub?.cancel();
    _levelSub = null;
    _soundLevel = 0.0;

    if (transcript.trim().isEmpty) {
      _state = CaptureState.error;
      _errorMessage = 'No speech detected. Try again.';
      notifyListeners();
      return;
    }

    _state = CaptureState.analyzing;
    notifyListeners();

    _screenshotBytes = await screenshot.capture();

    _report = await analyzer.analyze(
      transcript: transcript,
      screenshotPng: _screenshotBytes,
    );

    _state = CaptureState.previewing;
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
    _state = CaptureState.idle;
    _report = null;
    _screenshotBytes = null;
    _issueUrl = null;
    _errorMessage = null;
    _partialTranscript = '';
    _soundLevel = 0.0;
    notifyListeners();
  }

  void reset() => cancel();
}
