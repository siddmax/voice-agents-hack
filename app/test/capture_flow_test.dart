import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/capture_flow.dart';
import 'package:syndai/sdk/feedback_analyzer.dart';
import 'package:syndai/sdk/feedback_kb.dart';
import 'package:syndai/sdk/github_client.dart';
import 'package:syndai/sdk/screenshot_capture.dart';
import 'package:syndai/voice/audio_recorder.dart';
import 'package:syndai/voice/stt.dart';

import 'fake_cactus_engine.dart';

class _FakeStt extends SpeechToTextService {
  SttStartResult nextResult = SttStartResult.started;
  String nextTranscript = 'button is broken';

  @override
  Future<SttStartResult> startListening({
    void Function(String)? onPartial,
    void Function(String)? onFinal,
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

class _FakeRecorder implements PcmCapture {
  bool _recording = false;
  Uint8List? nextPcm = Uint8List.fromList([1, 2, 3, 4]);

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

void main() {
  late _FakeStt stt;
  late _FakeScreenshot screenshot;
  late _FakeGitHub github;
  late _FakeRecorder recorder;

  setUp(() {
    stt = _FakeStt();
    screenshot = _FakeScreenshot();
    github = _FakeGitHub();
    recorder = _FakeRecorder();
  });

  group('CaptureFlowController', () {
    test('starts in idle state', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );
      expect(ctrl.state, CaptureState.idle);
    });

    test('cancel resets all state', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.cancel();

      expect(ctrl.state, CaptureState.idle);
      expect(ctrl.report, isNull);
      expect(ctrl.feedbackReport, isNull);
      expect(ctrl.bugReproReport, isNull);
      expect(ctrl.screenshotBytes, isNull);
      expect(ctrl.issueUrl, isNull);
      expect(ctrl.errorMessage, isNull);
      expect(ctrl.partialTranscript, '');
      expect(ctrl.transcript, '');
      expect(ctrl.soundLevel, 0.0);
      expect(ctrl.screenshotFailed, false);
      expect(ctrl.mode, isNull);
    });

    test('showChooser transitions to choosing', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.showChooser();
      expect(ctrl.state, CaptureState.choosing);
    });

    test('chooseMode feedback transitions to listening', () async {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.showChooser();
      ctrl.chooseMode(CaptureMode.feedback);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.state, CaptureState.listening);
      expect(ctrl.mode, CaptureMode.feedback);
    });

    test('chooseMode bugRepro transitions to recording', () async {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.showChooser();
      ctrl.chooseMode(CaptureMode.bugRepro);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.state, CaptureState.recording);
      expect(ctrl.mode, CaptureMode.bugRepro);
    });

    test(
      'feedback flow: stopListeningAndShowTranscript is no-op from idle',
      () async {
        final ctrl = CaptureFlowController(
          engine: FakeCactusEngine([]),
          stt: stt,
          github: github,
          screenshot: screenshot,
          recorder: recorder,
        );

        await ctrl.stopListeningAndShowTranscript();
        expect(ctrl.state, CaptureState.idle);
      },
    );

    test('feedback flow: empty transcript shows error', () async {
      stt.nextTranscript = '   ';
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.showChooser();
      ctrl.chooseMode(CaptureMode.feedback);
      await Future<void>.delayed(Duration.zero);
      await ctrl.stopListeningAndShowTranscript();

      expect(ctrl.state, CaptureState.error);
      expect(ctrl.errorMessage, contains('No speech'));
    });

    test('feedback permission denied sets error', () async {
      stt.nextResult = SttStartResult.permissionDenied;
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.showChooser();
      ctrl.chooseMode(CaptureMode.feedback);
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.state, CaptureState.error);
      expect(ctrl.errorMessage, contains('permission'));
    });

    test('dispose calls cancel', () {
      final ctrl = CaptureFlowController(
        engine: FakeCactusEngine([]),
        stt: stt,
        github: github,
        screenshot: screenshot,
        recorder: recorder,
      );

      ctrl.dispose();
      expect(ctrl.state, CaptureState.idle);
    });
  });

  group('FeedbackReport', () {
    test('fromJson parses all fields', () {
      final report = FeedbackReport.fromJson({
        'summary': 'Great app',
        'sentiment': 'positive',
        'sentiment_score': 0.9,
        'category': 'UI/UX Design',
        'themes': ['smooth navigation', 'great prices'],
        'emotional_tone': 'delighted',
        'actionable_insight': 'Keep the current flow',
      });

      expect(report.sentiment, Sentiment.positive);
      expect(report.sentimentScore, 0.9);
      expect(report.category, 'UI/UX Design');
      expect(report.themes, hasLength(2));
      expect(report.offerCoupon, false);
    });

    test('negative sentiment triggers coupon', () {
      final report = FeedbackReport.fromJson({
        'summary': 'Terrible experience',
        'sentiment': 'negative',
        'sentiment_score': 0.15,
        'category': 'Checkout & Payment',
        'themes': ['slow', 'broken'],
        'emotional_tone': 'frustrated',
        'actionable_insight': 'Fix checkout',
      });

      expect(report.sentiment, Sentiment.negative);
      expect(report.offerCoupon, true);
    });

    test('mixed negative sentiment triggers coupon', () {
      final report = FeedbackReport.fromJson({
        'summary': 'Seat map is helpful but checkout is confusing',
        'sentiment': 'mixed_negative',
        'sentiment_score': 0.35,
        'sentiment_confidence': 0.9,
        'category': 'Checkout & Payment',
        'themes': ['seat map', 'checkout'],
        'pain_points': ['checkout is confusing'],
        'requested_outcome': 'Clarify checkout',
        'emotional_tone': 'mixed',
        'actionable_insight': 'Review checkout copy',
        'offer_eligible': true,
      });

      expect(report.sentiment, Sentiment.mixedNegative);
      expect(report.offerCoupon, true);
      expect(report.offer, FeedbackReport.negativeOffer);
    });

    test('positive sentiment ignores model supplied offer', () {
      final report = FeedbackReport.fromJson({
        'summary': 'Great experience',
        'sentiment': 'positive',
        'sentiment_score': 0.9,
        'category': 'UI/UX Design',
        'themes': ['fast checkout'],
        'emotional_tone': 'delighted',
        'actionable_insight': 'Keep the current flow',
        'offer': 'Invented coupon',
        'offer_eligible': true,
      });

      expect(report.sentiment, Sentiment.positive);
      expect(report.offerCoupon, false);
    });

    test('explicit favorite app praise overrides neutral model label', () {
      final report = FeedbackReport.fromJson({
        'summary': 'User loves the app',
        'sentiment': 'neutral',
        'sentiment_score': 0.8,
        'sentiment_confidence': 0.6,
        'category': 'General',
        'themes': ['overall satisfaction'],
        'pain_points': <String>[],
        'requested_outcome': 'Keep the app as is',
        'emotional_tone': 'neutral',
        'actionable_insight': 'Track strong positive satisfaction.',
        'offer_eligible': false,
      }, plainTranscript: 'I love this app. This is my my most favorite app.');

      expect(report.sentiment, Sentiment.positive);
      expect(report.sentimentScore, greaterThanOrEqualTo(0.9));
      expect(report.sentimentConfidence, greaterThanOrEqualTo(0.82));
      expect(report.offerCoupon, false);
    });

    test('validated praise evidence overrides neutral model label', () {
      final report = FeedbackReport.fromJson({
        'summary': 'User loves the app',
        'sentiment': 'neutral',
        'sentiment_score': 0.8,
        'sentiment_confidence': 0.6,
        'category': 'General',
        'themes': ['overall satisfaction'],
        'pain_points': <String>[],
        'requested_outcome': 'Keep the app as is',
        'emotional_tone': 'neutral',
        'actionable_insight': 'Track strong positive satisfaction.',
        'offer_eligible': false,
        'evidence': [
          {
            'quote': 'I love this app',
            'polarity': 'positive',
            'strength': 'strong',
          },
        ],
        'praise_present': true,
        'complaints_present': false,
        'request_present': false,
      }, plainTranscript: 'I love this app. This is my most favorite app.');

      expect(report.sentiment, Sentiment.positive);
      expect(report.sentimentScore, greaterThanOrEqualTo(0.9));
      expect(
        report.evidence.map((item) => item.quote),
        contains('I love this app'),
      );
      expect(report.praisePresent, true);
    });

    test('invented evidence is dropped and does not drive sentiment', () {
      final report = FeedbackReport.fromJson({
        'summary': 'User reported a checkout failure',
        'sentiment': 'neutral',
        'sentiment_score': 0.5,
        'sentiment_confidence': 0.7,
        'category': 'General',
        'themes': ['checkout'],
        'pain_points': ['checkout failed'],
        'requested_outcome': 'Fix checkout',
        'emotional_tone': 'neutral',
        'actionable_insight': 'Investigate checkout.',
        'offer_eligible': true,
        'evidence': [
          {
            'quote': 'checkout failed',
            'polarity': 'negative',
            'strength': 'strong',
          },
        ],
        'praise_present': false,
        'complaints_present': true,
        'request_present': true,
      }, plainTranscript: 'I love this app.');

      expect(report.sentiment, Sentiment.positive);
      expect(
        report.evidence.map((e) => e.quote),
        isNot(contains('checkout failed')),
      );
      expect(report.offerCoupon, false);
    });

    test('mixed praise and complaint evidence becomes mixed negative', () {
      final report = FeedbackReport.fromJson({
        'summary': 'Seat map is good but checkout is confusing',
        'sentiment': 'positive',
        'sentiment_score': 0.82,
        'sentiment_confidence': 0.9,
        'category': 'Checkout & Payment',
        'themes': ['seat map', 'checkout'],
        'pain_points': ['checkout is confusing'],
        'requested_outcome': 'Make checkout clearer',
        'emotional_tone': 'satisfied',
        'actionable_insight': 'Review checkout copy.',
        'offer_eligible': false,
        'evidence': [
          {
            'quote': 'I love the seat map',
            'polarity': 'positive',
            'strength': 'strong',
          },
          {
            'quote': 'checkout is confusing',
            'polarity': 'negative',
            'strength': 'moderate',
          },
        ],
        'praise_present': true,
        'complaints_present': true,
        'request_present': false,
      }, plainTranscript: 'I love the seat map, but checkout is confusing.');

      expect(report.sentiment, Sentiment.mixedNegative);
      expect(report.offer, FeedbackReport.negativeOffer);
      expect(report.complaintsPresent, true);
    });

    test('fallback gives strong favorite praise a high positive score', () {
      final report = FeedbackReport.fromTranscript(
        'I love this app. This is my most favorite app.',
      );

      expect(report.sentiment, Sentiment.positive);
      expect(report.sentimentScore, 0.94);
    });

    test('fallback creates neutral report', () {
      final report = FeedbackReport.fallback('test feedback');
      expect(report.sentiment, Sentiment.neutral);
      expect(report.offerCoupon, false);
      expect(report.summary, 'test feedback');
    });
  });

  group('FeedbackAnalyzer', () {
    test(
      'uses evidence-bound prompt with deterministic offer eligibility',
      () async {
        final engine = FakeCactusEngine([
          {
            'summary': 'Seat map is useful but checkout is confusing',
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
            'evidence': [
              {
                'quote': 'checkout is confusing',
                'polarity': 'negative',
                'strength': 'moderate',
              },
            ],
            'praise_present': true,
            'complaints_present': true,
            'request_present': false,
          },
        ]);
        final analyzer = FeedbackAnalyzer(
          engine,
          knowledgeBase: FeedbackKnowledgeBase.inMemory([
            FeedbackKbArticle.fromMarkdown(
              sourcePath: 'assets/kb/checkout-coupon-disappears.md',
              markdown: '''---
id: checkout-coupon-disappears
title: Coupon discount disappears after returning to checkout
category: Checkout & Payment
keywords: coupon, discount, checkout, confusing
---

# Coupon discount disappears after returning to checkout

## Customer Steps
1. Reapply the promo code before payment.

## Team Action
Persist applied promotion state across checkout route transitions.

## Engineering Signal
Checkout route transitions can drop promotion metadata.
''',
            ),
          ]),
        );

        final report = await analyzer.analyzeFeedback(
          transcript: 'I like the seat map, but checkout is confusing.',
        );

        expect(report.sentiment, Sentiment.mixedNegative);
        expect(report.offer, FeedbackReport.negativeOffer);
        expect(report.resolution?.summary, contains('Coupon discount'));
        expect(
          report.resolution?.teamActions.first,
          contains('Persist applied promotion state'),
        );
        expect(engine.ragQueryCalls, 0);
        final prompt =
            engine.capturedMessages.single.single['content'] as String;
        expect(
          prompt,
          contains('Base sentiment and evidence only on the transcript'),
        );
        expect(prompt, contains('Relevant local knowledge base articles'));
        expect(prompt, contains('Coupon discount disappears'));
        expect(prompt, contains('Do not create coupon copy'));
        expect(prompt, contains('Set offer_eligible true only'));
        expect(prompt, contains('Each evidence quote must be copied exactly'));
      },
    );
  });

  group('BugReproReport', () {
    test('fromJson parses steps', () {
      final report = BugReproReport.fromJson({
        'title': 'Checkout hangs',
        'steps': ['Tap seat', 'Tap buy', 'Wait 5 seconds'],
        'expected_behavior': 'Checkout loads',
        'actual_behavior': 'Spinner forever',
        'severity': 'high',
      });

      expect(report.steps, hasLength(3));
      expect(report.severity, 'high');
    });

    test('fallback uses transcript as single step', () {
      final report = BugReproReport.fallback('everything is broken');
      expect(report.steps, ['everything is broken']);
      expect(report.severity, 'high');
    });

    test('reconciles understated model severity from narration evidence', () {
      final report = BugReproReport.fromJson(
        {
          'title': 'Checkout issue',
          'summary': 'Checkout does not finish',
          'steps': ['Tap buy', 'Wait'],
          'expected_behavior': 'Checkout completes',
          'actual_behavior': 'The spinner runs forever',
          'severity': 'low',
          'observed_signals': ['Spinner never clears'],
        },
        narrationTranscript:
            'I tap buy and the checkout spinner is stuck forever.',
      );

      expect(report.severity, 'high');
    });

    test('fromEvidence prioritizes app facts over first-person narration', () {
      final report = BugReproReport.fromEvidence(
        const BugReproEvidence(
          selectedSeat: 'Section 105, Row 10',
          screen: 'Checkout',
          route: '/checkout/seat/select',
          userActions: [
            'Select Section 105, Row 10 from the ticket list.',
            'Tap Buy Now.',
          ],
          expectedOutcome: 'Checkout should advance.',
          observedOutcome:
              'An error alert is shown and checkout does not complete.',
          observedSignals: ['Error alert or error state appeared'],
        ),
        narrationTranscript:
            'So I tap on the section row button and I see this error alert pop up.',
        videoPath: '/tmp/repro.mp4',
      );

      expect(report.steps, [
        'Select Section 105, Row 10 from the ticket list.',
        'Tap Buy Now.',
        'Observe the error alert instead of a completed checkout.',
      ]);
      expect(report.steps.join(' '), isNot(contains('So I')));
      expect(report.actualBehavior, contains('error alert'));
      expect(report.observedSignals, contains('Route: /checkout/seat/select'));
      expect(report.videoPath, '/tmp/repro.mp4');
    });

    test('hydrates empty bug fields from narration fallback', () {
      final report = BugReproReport.fromJson(
        {
          'title': '',
          'summary': '',
          'steps': <String>[],
          'expected_behavior': '',
          'actual_behavior': '',
          'severity': 'medium',
          'observed_signals': <String>[],
        },
        narrationTranscript: 'Tap buy then checkout gets stuck',
        videoPath: '/tmp/repro.mp4',
      );

      expect(report.title, isNotEmpty);
      expect(report.steps, [
        'Tap Buy Now.',
        'Wait for checkout to finish loading.',
        'Observe that the checkout flow remains stuck.',
      ]);
      expect(report.expectedBehavior, contains('Checkout should load'));
      expect(
        report.actualBehavior,
        'Checkout remains stuck in a loading state.',
      );
      expect(
        report.observedSignals,
        contains('Checkout/loading state did not resolve'),
      );
      expect(report.videoPath, '/tmp/repro.mp4');
    });
  });
}
