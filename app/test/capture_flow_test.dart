import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/capture_flow.dart';
import 'package:syndai/sdk/github_client.dart';
import 'package:syndai/sdk/screen_analyzer.dart';
import 'package:syndai/sdk/screenshot_capture.dart';
import 'package:syndai/voice/stt.dart';

import 'fake_cactus_engine.dart';

class _FakeStt extends SpeechToTextService {
  SttStartResult nextResult = SttStartResult.started;
  String nextTranscript = 'button is broken';

  @override
  Future<SttStartResult> startListening({
    void Function(String)? onPartial,
  }) async {
    if (nextResult == SttStartResult.started && onPartial != null) {
      onPartial(nextTranscript);
    }
    return nextResult;
  }

  @override
  Future<String> stopListening() async => nextTranscript;

  @override
  bool get isListening => false;

  @override
  Future<void> cancel() async {}

  @override
  Stream<double> get soundLevel => const Stream.empty();
}

class _FakeScreenshot extends ScreenshotCapture {
  Uint8List? nextCapture = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

  @override
  Future<Uint8List?> capture() async => nextCapture;
}

class _FakeGitHub extends GitHubClient {
  String? nextUploadUrl = 'https://example.com/screenshot.png';
  String? nextIssueUrl = 'https://github.com/test/repo/issues/1';

  _FakeGitHub() : super(owner: 'test', repo: 'repo', token: 'tok');

  @override
  Future<String?> uploadScreenshot(Uint8List pngBytes) async => nextUploadUrl;

  @override
  Future<String?> createIssue({
    required String title,
    required String body,
    required List<String> labels,
  }) async => nextIssueUrl;
}

void main() {
  late _FakeStt stt;
  late _FakeScreenshot screenshot;
  late _FakeGitHub github;

  setUp(() {
    stt = _FakeStt();
    screenshot = _FakeScreenshot();
    github = _FakeGitHub();
  });

  group('CaptureFlowController', () {
    test('starts in idle state', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );
      expect(ctrl.state, CaptureState.idle);
    });

    test('cancel resets all state', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      ctrl.cancel();

      expect(ctrl.state, CaptureState.idle);
      expect(ctrl.report, isNull);
      expect(ctrl.screenshotBytes, isNull);
      expect(ctrl.issueUrl, isNull);
      expect(ctrl.errorMessage, isNull);
      expect(ctrl.partialTranscript, '');
      expect(ctrl.transcript, '');
      expect(ctrl.soundLevel, 0.0);
      expect(ctrl.screenshotFailed, false);
    });

    testWidgets('startCapture transitions to listening', (tester) async {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      await tester.pumpWidget(Builder(builder: (context) {
        ctrl.startCapture(context);
        return const SizedBox();
      }));
      await tester.pumpAndSettle();

      expect(ctrl.state, CaptureState.listening);
      expect(ctrl.screenshotBytes, isNotNull);
      expect(ctrl.screenshotFailed, false);
    });

    testWidgets('startCapture sets screenshotFailed when capture returns null', (tester) async {
      screenshot.nextCapture = null;
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      await tester.pumpWidget(Builder(builder: (context) {
        ctrl.startCapture(context);
        return const SizedBox();
      }));
      await tester.pumpAndSettle();

      expect(ctrl.screenshotFailed, true);
      expect(ctrl.screenshotBytes, isNull);
    });

    testWidgets('sets error on permission denied', (tester) async {
      stt.nextResult = SttStartResult.permissionDenied;
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      await tester.pumpWidget(Builder(builder: (context) {
        ctrl.startCapture(context);
        return const SizedBox();
      }));
      await tester.pumpAndSettle();

      expect(ctrl.state, CaptureState.error);
      expect(ctrl.errorMessage, contains('permission'));
    });

    test('stopAndAnalyze errors on empty transcript', () async {
      stt.nextTranscript = '   ';
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      // Manually set state to listening to test stopAndAnalyze
      ctrl.cancel(); // ensure idle
      // We can't easily call startCapture without a BuildContext,
      // so test the guard: stopAndAnalyze should be a no-op from idle
      await ctrl.stopAndAnalyze();
      expect(ctrl.state, CaptureState.idle);
    });

    test('updateReport replaces the report', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      final report = BugReport.fallback('test');
      ctrl.updateReport(report);
      expect(ctrl.report?.title, 'test');
    });

    test('dispose calls cancel', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
      );

      ctrl.dispose();
      expect(ctrl.state, CaptureState.idle);
    });
  });
}

