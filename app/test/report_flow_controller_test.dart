import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/feedback_analyzer.dart';
import 'package:syndai/sdk/github_issue_service.dart';
import 'package:syndai/sdk/screen_recording_capture.dart';
import 'package:syndai/ui/report_flow_controller.dart';
import 'package:syndai/voice/audio_recorder.dart';

class _FakeRecorder implements PcmCapture {
  bool _recording = false;
  Uint8List? nextPcm = Uint8List.fromList([1, 2, 3]);

  @override
  Stream<double> get amplitude => const Stream.empty();

  @override
  bool get isRecording => _recording;

  @override
  Future<void> cancel() async {
    _recording = false;
  }

  @override
  void dispose() {
    _recording = false;
  }

  @override
  Future<bool> startRecording() async {
    _recording = true;
    return true;
  }

  @override
  Future<Uint8List?> stopAndGetPcm() async {
    _recording = false;
    return nextPcm;
  }

  @override
  Future<String?> stopRecording() async {
    _recording = false;
    return '/tmp/fake.wav';
  }
}

class _FakeScreenRecorder implements ScreenRecordingCapture {
  bool _recording = false;
  bool nextStart = true;
  String? nextPath = '/tmp/repro.mp4';

  @override
  bool get isRecording => _recording;

  @override
  Future<void> cancel() async {
    _recording = false;
  }

  @override
  Future<bool> start() async {
    _recording = nextStart;
    return nextStart;
  }

  @override
  Future<String?> stop() async {
    _recording = false;
    return nextPath;
  }
}

class _FakeIssueService extends GitHubIssueService {
  GitHubIssueRequest? lastRequest;
  String? nextVideoUrl = 'https://example.com/repro.mp4';

  @override
  bool get isReady => true;

  @override
  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    lastRequest = request;
    return const GitHubIssueSubmission(
      url: 'https://github.com/acme/app/issues/7',
      issueNumber: '#7',
    );
  }

  @override
  Future<String?> uploadVideoFile(String path) async => nextVideoUrl;
}

ReportFlowController _controller({
  required _FakeRecorder recorder,
  required _FakeScreenRecorder screenRecorder,
  required _FakeIssueService issueService,
  required String transcript,
  Future<FeedbackReport> Function(String transcript, Uint8List? pcmData)?
  analyzeFeedback,
}) {
  return ReportFlowController(
    recorder: recorder,
    screenRecorder: screenRecorder,
    issueService: issueService,
    transcribe: (_) async => transcript,
    analyzeFeedback:
        analyzeFeedback ??
        (transcript, _) async => FeedbackReport.fromTranscript(transcript),
    reproContext: () => const ReproContext(
      selectedSeat: 'Section 105, Row 10',
      deviceInfo: 'Simulator - iPhone 17 Pro.',
      log: '{"error":"Timeout"}',
    ),
  );
}

void main() {
  test('mode picker opens from idle', () {
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: _FakeScreenRecorder(),
      issueService: _FakeIssueService(),
      transcript: 'hello',
    );

    ctrl.openChooser();

    expect(ctrl.state, ReportFlowState.choosingMode);
  });

  test(
    'feedback flow reaches plain transcript preview with negative offer',
    () async {
      final ctrl = _controller(
        recorder: _FakeRecorder(),
        screenRecorder: _FakeScreenRecorder(),
        issueService: _FakeIssueService(),
        transcript: 'Checkout is broken and I am frustrated.',
      );

      ctrl.openChooser();
      await ctrl.chooseFeedback();
      await ctrl.finishFeedback();

      expect(ctrl.state, ReportFlowState.feedbackPreview);
      expect(
        ctrl.feedbackReport?.plainTranscript,
        contains('Checkout is broken'),
      );
      expect(ctrl.feedbackReport?.offer, contains('SORRY10'));
    },
  );

  test('feedback submit sends GitHub feedback labels and body', () async {
    final issueService = _FakeIssueService();
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: _FakeScreenRecorder(),
      issueService: issueService,
      transcript: 'The checkout fees are confusing and expensive.',
    );

    ctrl.openChooser();
    await ctrl.chooseFeedback();
    await ctrl.finishFeedback();
    await ctrl.submit();

    expect(ctrl.state, ReportFlowState.done);
    expect(issueService.lastRequest?.labels, contains('feedback'));
    expect(issueService.lastRequest?.labels, contains('voicebug'));
    expect(issueService.lastRequest?.labels, contains('sentiment:negative'));
    expect(issueService.lastRequest?.body, contains('Plain voice transcript'));
    expect(issueService.lastRequest?.body, isNot(contains('{')));
  });

  test(
    'feedback flow uses analyzer output for mixed negative sentiment',
    () async {
      final issueService = _FakeIssueService();
      final ctrl = _controller(
        recorder: _FakeRecorder(),
        screenRecorder: _FakeScreenRecorder(),
        issueService: issueService,
        transcript: 'I love the seat map but checkout is still confusing.',
        analyzeFeedback: (transcript, pcmData) async =>
            FeedbackReport.fromJson({
              'summary': 'Seat map is good, checkout is confusing',
              'sentiment': 'mixed_negative',
              'sentiment_score': 0.36,
              'sentiment_confidence': 0.88,
              'category': 'Checkout & Payment',
              'themes': ['seat map', 'checkout'],
              'pain_points': ['checkout is confusing'],
              'requested_outcome': 'Make checkout clearer',
              'emotional_tone': 'mixed',
              'actionable_insight': 'Review checkout labels and fee copy.',
              'offer_eligible': true,
            }, plainTranscript: transcript),
      );

      ctrl.openChooser();
      await ctrl.chooseFeedback();
      await ctrl.finishFeedback();
      await ctrl.submit();

      expect(ctrl.feedbackReport?.sentiment, Sentiment.mixedNegative);
      expect(ctrl.feedbackReport?.offer, contains('SORRY10'));
      expect(
        issueService.lastRequest?.labels,
        contains('sentiment:mixed_negative'),
      );
      expect(
        issueService.lastRequest?.body,
        contains('Seat map is good, checkout is confusing'),
      );
    },
  );

  test('repro flow records video path and builds steps', () async {
    final screenRecorder = _FakeScreenRecorder()..nextPath = '/tmp/repro.mp4';
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: screenRecorder,
      issueService: _FakeIssueService(),
      transcript: 'Tap the seat then tap buy now. The checkout stays stuck.',
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(ctrl.state, ReportFlowState.reproPreview);
    expect(ctrl.bugReport?.videoPath, '/tmp/repro.mp4');
    expect(ctrl.bugReport?.steps.length, greaterThanOrEqualTo(2));
    expect(ctrl.bugReport?.severity, 'high');
  });

  test(
    'repro submit includes video evidence url when upload succeeds',
    () async {
      final issueService = _FakeIssueService();
      final ctrl = _controller(
        recorder: _FakeRecorder(),
        screenRecorder: _FakeScreenRecorder(),
        issueService: issueService,
        transcript: 'Tap the seat then tap buy now. The checkout stays stuck.',
      );

      ctrl.openChooser();
      await ctrl.chooseBugRepro();
      await ctrl.finishBugRepro();
      await ctrl.submit();

      expect(issueService.lastRequest?.labels, contains('bug'));
      expect(issueService.lastRequest?.labels, contains('severity:high'));
      expect(
        issueService.lastRequest?.body,
        contains('https://example.com/repro.mp4'),
      );
      expect(issueService.lastRequest?.body, contains('Steps To Reproduce'));
    },
  );
}
