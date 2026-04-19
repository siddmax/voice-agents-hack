import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/feedback_analyzer.dart';
import 'package:syndai/sdk/feedback_kb.dart';
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
  bool _warmed = true;
  bool nextStart = true;
  String? nextPath = '/tmp/repro.mp4';
  String? stopError;

  @override
  bool get isRecording => _recording;

  @override
  bool get isWarmed => _warmed;

  @override
  String? get lastError => stopError;

  @override
  Future<void> warmUp() async {
    _warmed = true;
  }

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
    if (stopError != null) return null;
    return nextPath;
  }
}

class _FakeIssueService extends GitHubIssueService {
  GitHubIssueRequest? lastRequest;
  String? nextVideoUrl = 'https://example.com/repro.mp4';
  String? uploadError;

  @override
  bool get isReady => true;

  @override
  String? get lastUploadError => uploadError;

  @override
  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    lastRequest = request;
    return const GitHubIssueSubmission(
      url: 'https://github.com/acme/app/issues/7',
      issueNumber: '#7',
    );
  }

  @override
  Future<String?> uploadVideoFile(String path) async {
    uploadError = nextVideoUrl == null ? 'fake upload failed' : null;
    return Future.value(nextVideoUrl);
  }
}

ReportFlowController _controller({
  required _FakeRecorder recorder,
  required _FakeScreenRecorder screenRecorder,
  required _FakeIssueService issueService,
  required String transcript,
  Future<FeedbackReport> Function(
    String transcript,
    Uint8List? pcmData,
    void Function(String activity)? onProgress,
  )?
  analyzeFeedback,
}) {
  return ReportFlowController(
    recorder: recorder,
    screenRecorder: screenRecorder,
    issueService: issueService,
    transcribe: (_) async => transcript,
    analyzeFeedback:
        analyzeFeedback ??
        (transcript, _, onProgress) async {
          onProgress?.call('Agent summarizing');
          return FeedbackReport.fromTranscript(transcript);
        },
    reproContext: () => const ReproContext(
      selectedSeat: 'Section 105, Row 10',
      deviceInfo:
          '| Field | Value |\n|---|---|\n| os | iOS 18.0 |\n| device | iPhone Simulator |',
      log:
          '{"error":"Timeout","route":"/checkout/seat/select","code":"LIST_TO_VOID"}',
      sessionSummary: 'Checkout repro session.',
      evidence: BugReproEvidence(
        selectedSeat: 'Section 105, Row 10',
        screen: 'Checkout',
        route: '/checkout/seat/select',
        userActions: [
          'Select Section 105, Row 10 from the ticket list.',
          'Tap Buy Now.',
        ],
        expectedOutcome:
            'Tapping Buy Now should complete the purchase flow or advance to the next checkout step.',
        observedOutcome:
            'An error alert is shown and checkout does not complete.',
        observedSignals: [
          'Buy Now action was attempted',
          'Error alert or error state appeared',
          'Purchase flow did not complete',
          'Network request checkout.createIntent timed out with LIST_TO_VOID',
        ],
      ),
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

  test('feedback analysis exposes live agent activity', () async {
    final started = Completer<void>();
    final finish = Completer<FeedbackReport>();
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: _FakeScreenRecorder(),
      issueService: _FakeIssueService(),
      transcript: 'Checkout keeps losing my coupon.',
      analyzeFeedback: (transcript, _, onProgress) {
        onProgress?.call('Agent searching KB');
        started.complete();
        return finish.future;
      },
    );

    ctrl.openChooser();
    await ctrl.chooseFeedback();
    final pending = ctrl.finishFeedback();
    await started.future;

    expect(ctrl.state, ReportFlowState.analyzingFeedback);
    expect(ctrl.agentActivity, 'Agent searching KB');

    finish.complete(FeedbackReport.fromTranscript(ctrl.transcript));
    await pending;

    expect(ctrl.state, ReportFlowState.feedbackPreview);
  });

  test('feedback flow uses analyzer output for mixed negative sentiment', () async {
    final issueService = _FakeIssueService();
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: _FakeScreenRecorder(),
      issueService: issueService,
      transcript: 'I love the seat map but checkout is still confusing.',
      analyzeFeedback: (transcript, pcmData, onProgress) async =>
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
          }, plainTranscript: transcript).withResolution(
            FeedbackResolution(
              summary:
                  'Matched "Coupon discount disappears after returning to checkout" in the local support knowledge base.',
              customerSteps: const ['Reapply the promo code before payment.'],
              teamActions: const [
                'Persist applied promotion state across checkout route transitions.',
              ],
              matches: [
                FeedbackKbMatch(
                  article: FeedbackKbArticle.fromMarkdown(
                    sourcePath: 'assets/kb/checkout-coupon-disappears.md',
                    markdown: '''---
id: checkout-coupon-disappears
title: Coupon discount disappears after returning to checkout
category: Checkout & Payment
keywords: coupon, discount, checkout
---

# Coupon discount disappears after returning to checkout

## Customer Steps
1. Reapply the promo code before payment.

## Team Action
Persist applied promotion state across checkout route transitions.

## Engineering Signal
Quote refresh drops promotion metadata.
''',
                  ),
                  score: 12,
                  matchedTerms: const ['checkout'],
                ),
              ],
            ),
          ),
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
    expect(issueService.lastRequest?.body, contains('Local KB Resolution'));
    expect(
      issueService.lastRequest?.body,
      contains('Coupon discount disappears after returning to checkout'),
    );
    expect(
      issueService.lastRequest?.body,
      contains('Persist applied promotion state'),
    );
  });

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

  test('repro flow converts narration into durable checkout steps', () async {
    final ctrl = _controller(
      recorder: _FakeRecorder(),
      screenRecorder: _FakeScreenRecorder(),
      issueService: _FakeIssueService(),
      transcript:
          'So I tap on the section row button order summary. I tap on the buy now button and I see this error alert pop up.',
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(
      ctrl.bugReport?.title,
      'Checkout error after tapping Buy Now for Section 105, Row 10',
    );
    expect(ctrl.bugReport?.steps, [
      'Select Section 105, Row 10 from the ticket list.',
      'Tap Buy Now.',
      'Observe the error alert instead of a completed checkout.',
    ]);
    expect(ctrl.bugReport?.summary, contains('shows an error'));
    expect(ctrl.bugReport?.actualBehavior, contains('error alert'));
    expect(ctrl.bugReport?.severity, 'high');
    expect(ctrl.bugReport?.steps.join(' '), isNot(contains('So I tap')));
    expect(
      ctrl.bugReport?.observedSignals,
      contains(
        'Network request checkout.createIntent timed out with LIST_TO_VOID',
      ),
    );
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
      expect(issueService.lastRequest?.body, contains('Device & App Context'));
      expect(issueService.lastRequest?.body, contains('Capture Timeline'));
      expect(issueService.lastRequest?.body, contains('Session Evidence'));
      expect(issueService.lastRequest?.body, contains('Status: uploaded'));
    },
  );

  test('repro submit records explicit video upload failure reason', () async {
    final issueService = _FakeIssueService()..nextVideoUrl = null;
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

    expect(
      issueService.lastRequest?.body,
      contains('Status: upload unavailable'),
    );
    expect(issueService.lastRequest?.body, contains('fake upload failed'));
    expect(issueService.lastRequest?.body, contains('/tmp/repro.mp4'));
  });

  test(
    'repro preview and submit preserve screen recorder stop failure',
    () async {
      final issueService = _FakeIssueService();
      final ctrl = _controller(
        recorder: _FakeRecorder(),
        screenRecorder: _FakeScreenRecorder()
          ..nextPath = null
          ..stopError =
              'NO_VIDEO_FRAMES: ReplayKit stopped before delivering any video frames.',
        issueService: issueService,
        transcript: 'Tap the seat then tap buy now. The checkout stays stuck.',
      );

      ctrl.openChooser();
      await ctrl.chooseBugRepro();
      await ctrl.finishBugRepro();

      expect(ctrl.bugReport?.videoPath, isNull);
      expect(ctrl.bugReport?.videoUploadNote, contains('NO_VIDEO_FRAMES'));

      await ctrl.submit();

      expect(issueService.lastRequest?.body, contains('NO_VIDEO_FRAMES'));
      expect(
        issueService.lastRequest?.body,
        contains('video_path_returned | no'),
      );
    },
  );
}
