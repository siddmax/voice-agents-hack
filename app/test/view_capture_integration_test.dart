import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/feedback_analyzer.dart';
import 'package:syndai/sdk/github_issue_service.dart';
import 'package:syndai/sdk/view_capture_recorder.dart';
import 'package:syndai/ui/report_flow_controller.dart';
import 'package:syndai/voice/audio_recorder.dart';

class _FakeRecorder implements PcmCapture {
  bool _recording = false;

  @override
  Stream<double> get amplitude => const Stream.empty();

  @override
  bool get isRecording => _recording;

  @override
  Future<void> cancel() async => _recording = false;

  @override
  void dispose() => _recording = false;

  @override
  Future<bool> startRecording() async {
    _recording = true;
    return true;
  }

  @override
  Future<Uint8List?> stopAndGetPcm() async {
    _recording = false;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<String?> stopRecording() async {
    _recording = false;
    return '/tmp/fake.wav';
  }
}

class _FakeIssueService extends GitHubIssueService {
  GitHubIssueRequest? lastRequest;
  String? nextVideoUrl = 'https://example.com/repro.mp4';

  @override
  bool get isReady => true;

  @override
  String? get lastUploadError => null;

  @override
  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    lastRequest = request;
    return const GitHubIssueSubmission(
      url: 'https://github.com/acme/app/issues/42',
      issueNumber: '#42',
    );
  }

  @override
  Future<String?> uploadVideoFile(String path) async => nextVideoUrl;
}

void main() {
  test('full bug report flow attaches video when view capture is warmed',
      () async {
    final screenRecorder = FakeViewCaptureRecorder()
      ..nextPath = '/tmp/view_capture.mp4';
    await screenRecorder.warmUp();

    final issueService = _FakeIssueService();

    final ctrl = ReportFlowController(
      recorder: _FakeRecorder(),
      screenRecorder: screenRecorder,
      issueService: issueService,
      transcribe: (_) async => 'Tap buy now. The checkout is stuck.',
      analyzeFeedback: (t, _) async => FeedbackReport.fromTranscript(t),
      reproContext: () => const ReproContext(
        selectedSeat: 'Section 105',
        deviceInfo: '| os | iOS |',
        log: '{}',
      ),
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(ctrl.state, ReportFlowState.reproPreview);
    expect(ctrl.videoPath, '/tmp/view_capture.mp4');
    expect(ctrl.bugReport?.videoPath, '/tmp/view_capture.mp4');

    await ctrl.submit();

    expect(ctrl.state, ReportFlowState.done);
    expect(issueService.lastRequest?.body, contains('Status: uploaded'));
    expect(
      issueService.lastRequest?.body,
      contains('https://example.com/repro.mp4'),
    );
  });

  test('bug report still submits when view capture is not warmed', () async {
    final screenRecorder = FakeViewCaptureRecorder()..nextWarmUp = false;

    final issueService = _FakeIssueService();

    final ctrl = ReportFlowController(
      recorder: _FakeRecorder(),
      screenRecorder: screenRecorder,
      issueService: issueService,
      transcribe: (_) async => 'Tap buy now. Stuck on spinner.',
      analyzeFeedback: (t, _) async => FeedbackReport.fromTranscript(t),
      reproContext: () => const ReproContext(
        selectedSeat: 'Section 105',
        deviceInfo: '| os | iOS |',
        log: '{}',
      ),
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(ctrl.state, ReportFlowState.reproPreview);
    expect(ctrl.videoPath, isNull);

    await ctrl.submit();

    expect(ctrl.state, ReportFlowState.done);
    expect(
      issueService.lastRequest?.body,
      contains('upload unavailable'),
    );
  });
}
