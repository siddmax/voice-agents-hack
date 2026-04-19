import 'dart:typed_data';

import '../cactus/engine.dart';
import 'feedback_kb.dart';

enum Sentiment { positive, neutral, mixedNegative, negative }

extension SentimentLabel on Sentiment {
  String get label => switch (this) {
    Sentiment.positive => 'positive',
    Sentiment.neutral => 'neutral',
    Sentiment.mixedNegative => 'mixed_negative',
    Sentiment.negative => 'negative',
  };

  bool get offerEligible =>
      this == Sentiment.negative || this == Sentiment.mixedNegative;
}

class FeedbackEvidence {
  final String quote;
  final String polarity;
  final String strength;

  const FeedbackEvidence({
    required this.quote,
    required this.polarity,
    required this.strength,
  });

  factory FeedbackEvidence.fromJson(Map<String, dynamic> json) {
    return FeedbackEvidence(
      quote: (json['quote'] as String?)?.trim() ?? '',
      polarity: _normalizePolarity(json['polarity'] as String?),
      strength: _normalizeStrength(json['strength'] as String?),
    );
  }

  static String _normalizePolarity(String? value) {
    final normalized = (value ?? '').toLowerCase().replaceAll('-', '_').trim();
    return switch (normalized) {
      'positive' || 'praise' => 'positive',
      'negative' || 'complaint' => 'negative',
      'request' || 'requested_outcome' => 'request',
      _ => 'neutral',
    };
  }

  static String _normalizeStrength(String? value) {
    final normalized = (value ?? '').toLowerCase().trim();
    return switch (normalized) {
      'strong' || 'high' => 'strong',
      'weak' || 'low' => 'weak',
      _ => 'moderate',
    };
  }
}

class FeedbackReport {
  static const negativeOffer =
      'Sorry for the bad experience. Use SORRY10 for 10% off your next ticket.';

  final String plainTranscript;
  final String summary;
  final Sentiment sentiment;
  final double sentimentScore;
  final double sentimentConfidence;
  final String category;
  final List<String> themes;
  final List<String> painPoints;
  final String requestedOutcome;
  final String emotionalTone;
  final String actionableInsight;
  final List<FeedbackEvidence> evidence;
  final bool praisePresent;
  final bool complaintsPresent;
  final bool requestPresent;
  final String? offer;
  final FeedbackResolution? resolution;

  FeedbackReport({
    required this.plainTranscript,
    required this.summary,
    required this.sentiment,
    required this.sentimentScore,
    required this.sentimentConfidence,
    required this.category,
    required this.themes,
    required this.painPoints,
    required this.requestedOutcome,
    required this.emotionalTone,
    required this.actionableInsight,
    this.evidence = const [],
    this.praisePresent = false,
    this.complaintsPresent = false,
    this.requestPresent = false,
    this.offer,
    this.resolution,
  });

  bool get offerCoupon => offer != null && offer!.isNotEmpty;
  bool get hasResolution => resolution?.isNotEmpty == true;

  FeedbackReport withResolution(FeedbackResolution? nextResolution) {
    return FeedbackReport(
      plainTranscript: plainTranscript,
      summary: summary,
      sentiment: sentiment,
      sentimentScore: sentimentScore,
      sentimentConfidence: sentimentConfidence,
      category: category,
      themes: themes,
      painPoints: painPoints,
      requestedOutcome: requestedOutcome,
      emotionalTone: emotionalTone,
      actionableInsight: actionableInsight,
      evidence: evidence,
      praisePresent: praisePresent,
      complaintsPresent: complaintsPresent,
      requestPresent: requestPresent,
      offer: offer,
      resolution: nextResolution,
    );
  }

  factory FeedbackReport.fromJson(
    Map<String, dynamic> json, {
    String plainTranscript = '',
  }) {
    final rawScore = (json['sentiment_score'] as num?)?.toDouble() ?? 0.5;
    final rawConfidence =
        (json['sentiment_confidence'] as num?)?.toDouble() ?? 0.75;
    final sentimentStr =
        (json['sentiment'] as String?)
            ?.toLowerCase()
            .replaceAll('-', '_')
            .trim() ??
        '';
    final parsedSentiment = switch (sentimentStr) {
      'positive' => Sentiment.positive,
      'mixed_negative' || 'mixed negative' => Sentiment.mixedNegative,
      'negative' => Sentiment.negative,
      _ => Sentiment.neutral,
    };
    final modelEvidence = _parseValidatedEvidence(
      json['evidence'],
      transcript: plainTranscript,
    );
    final lexicalEvidence = _detectSentimentEvidence(plainTranscript);
    final evidence = _mergeSentimentEvidence(modelEvidence, lexicalEvidence);
    final evidenceItems = _mergeEvidenceItems(
      modelEvidence,
      _lexicalEvidenceItems(plainTranscript, lexicalEvidence),
    );
    final sentiment = _reconcileSentiment(
      parsedSentiment,
      score: rawScore,
      evidence: evidence,
    );
    final score = _reconcileScore(
      rawScore,
      sentiment,
      evidence,
    ).clamp(0.0, 1.0);
    final confidence = _reconcileConfidence(
      rawConfidence,
      sentiment,
      evidence,
    ).clamp(0.0, 1.0);
    final summary = (json['summary'] as String?)?.trim();
    final emotionalTone = _reconcileTone(
      (json['emotional_tone'] as String?)?.trim(),
      sentiment,
      evidence,
    );

    return FeedbackReport(
      plainTranscript: plainTranscript,
      summary: summary == null || summary.isEmpty ? plainTranscript : summary,
      sentiment: sentiment,
      sentimentScore: score,
      sentimentConfidence: confidence,
      category: (json['category'] as String?)?.trim() ?? 'General',
      themes:
          (json['themes'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      painPoints:
          (json['pain_points'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      requestedOutcome: (json['requested_outcome'] as String?)?.trim() ?? '',
      emotionalTone: emotionalTone,
      actionableInsight: (json['actionable_insight'] as String?)?.trim() ?? '',
      evidence: evidenceItems,
      praisePresent: evidence.positive,
      complaintsPresent: evidence.negative,
      requestPresent: evidence.request,
      offer: sentiment.offerEligible ? negativeOffer : null,
    );
  }

  factory FeedbackReport.fallback(String transcript) {
    return FeedbackReport.fromTranscript(transcript);
  }

  factory FeedbackReport.fromTranscript(String transcript) {
    final evidence = _detectSentimentEvidence(transcript);
    final lower = transcript.toLowerCase();
    final sentiment = evidence.negative && evidence.positive
        ? Sentiment.mixedNegative
        : evidence.negative
        ? Sentiment.negative
        : evidence.positive
        ? Sentiment.positive
        : Sentiment.neutral;
    final themes = <String>[
      if (lower.contains('checkout') || lower.contains('payment'))
        'Checkout & Payment',
      if (lower.contains('price') ||
          lower.contains('fee') ||
          lower.contains('expensive'))
        'Pricing & Fees',
      if (lower.contains('slow') ||
          lower.contains('stuck') ||
          lower.contains('spinner'))
        'Performance',
      if (lower.contains('seat') || lower.contains('ticket'))
        'Ticket Selection',
    ];
    final category = themes.isEmpty ? 'General' : themes.first;
    return FeedbackReport(
      plainTranscript: transcript,
      summary: transcript,
      sentiment: sentiment,
      sentimentScore: switch (sentiment) {
        Sentiment.positive => evidence.strongPositive ? 0.94 : 0.82,
        Sentiment.neutral => 0.5,
        Sentiment.mixedNegative => 0.34,
        Sentiment.negative => 0.18,
      },
      sentimentConfidence: 0.68,
      category: category,
      themes: themes,
      painPoints: evidence.negative ? [transcript] : [],
      requestedOutcome: '',
      emotionalTone: switch (sentiment) {
        Sentiment.positive => 'satisfied',
        Sentiment.neutral => 'neutral',
        Sentiment.mixedNegative => 'mixed',
        Sentiment.negative => 'frustrated',
      },
      actionableInsight: evidence.negative
          ? 'Review this feedback for a product or reliability follow-up.'
          : 'Track this feedback alongside related product themes.',
      evidence: _lexicalEvidenceItems(transcript, evidence),
      praisePresent: evidence.positive,
      complaintsPresent: evidence.negative,
      requestPresent: evidence.request,
      offer: sentiment.offerEligible ? negativeOffer : null,
    );
  }

  static _SentimentEvidence _detectSentimentEvidence(String transcript) {
    final lower = transcript.toLowerCase();
    final negative = RegExp(
      r'\b(bad|broken|awful|terrible|hate|frustrat|annoy|angry|slow|stuck|failed|fail|crash|expensive|confusing|disappear|lost)\b',
    ).hasMatch(lower);
    final positive =
        RegExp(
          r'\b(good|great|love|loved|favorite|favourite|best|smooth|easy|fast|helpful|nice|excellent|awesome|amazing|wonderful|perfect)\b',
        ).hasMatch(lower) ||
        RegExp(
          r'\b(?:i|we)\s+(?:really\s+)?(?:like|liked|enjoy|enjoyed)\b',
        ).hasMatch(lower);
    final strongPositive = RegExp(
      r'\b(love|loved|favorite|favourite|best|excellent|awesome|amazing|wonderful|perfect)\b',
    ).hasMatch(lower);
    final request = RegExp(
      r'\b(please|could you|can you|would like|wish|hope|want|need|should)\b',
    ).hasMatch(lower);
    return _SentimentEvidence(
      positive: positive,
      negative: negative,
      strongPositive: strongPositive,
      request: request,
    );
  }

  static List<FeedbackEvidence> _parseValidatedEvidence(
    Object? raw, {
    required String transcript,
  }) {
    if (raw is! List) return const [];
    final transcriptNorm = _normalizeForQuoteMatch(transcript);
    final out = <FeedbackEvidence>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final evidence = FeedbackEvidence.fromJson(item.cast<String, dynamic>());
      if (evidence.quote.isEmpty) continue;
      final quoteNorm = _normalizeForQuoteMatch(evidence.quote);
      if (quoteNorm.isEmpty) continue;
      if (transcriptNorm.isNotEmpty && !transcriptNorm.contains(quoteNorm)) {
        continue;
      }
      out.add(evidence);
    }
    return out;
  }

  static _SentimentEvidence _mergeSentimentEvidence(
    List<FeedbackEvidence> modelEvidence,
    _SentimentEvidence lexicalEvidence,
  ) {
    final modelPositive = modelEvidence.any((e) => e.polarity == 'positive');
    final modelNegative = modelEvidence.any((e) => e.polarity == 'negative');
    final modelRequest = modelEvidence.any((e) => e.polarity == 'request');
    final modelStrongPositive = modelEvidence.any(
      (e) => e.polarity == 'positive' && e.strength == 'strong',
    );

    return _SentimentEvidence(
      positive: modelPositive || lexicalEvidence.positive,
      negative: modelNegative || lexicalEvidence.negative,
      strongPositive: modelStrongPositive || lexicalEvidence.strongPositive,
      request: modelRequest || lexicalEvidence.request,
    );
  }

  static List<FeedbackEvidence> _mergeEvidenceItems(
    List<FeedbackEvidence> modelEvidence,
    List<FeedbackEvidence> lexicalEvidence,
  ) {
    final out = <FeedbackEvidence>[];
    final seen = <String>{};
    for (final item in [...modelEvidence, ...lexicalEvidence]) {
      final key =
          '${_normalizeForQuoteMatch(item.quote)}|${item.polarity}|${item.strength}';
      if (item.quote.isEmpty || !seen.add(key)) continue;
      out.add(item);
    }
    return out;
  }

  static String _normalizeForQuoteMatch(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<FeedbackEvidence> _lexicalEvidenceItems(
    String transcript,
    _SentimentEvidence evidence,
  ) {
    final out = <FeedbackEvidence>[];
    if (evidence.positive) {
      out.add(
        FeedbackEvidence(
          quote: transcript,
          polarity: 'positive',
          strength: evidence.strongPositive ? 'strong' : 'moderate',
        ),
      );
    }
    if (evidence.negative) {
      out.add(
        FeedbackEvidence(
          quote: transcript,
          polarity: 'negative',
          strength: 'moderate',
        ),
      );
    }
    return out.where((e) => e.quote.isNotEmpty).toList(growable: false);
  }

  static Sentiment _reconcileSentiment(
    Sentiment parsed, {
    required double score,
    required _SentimentEvidence evidence,
  }) {
    if (evidence.positive && evidence.negative) return Sentiment.mixedNegative;
    if (evidence.negative) return Sentiment.negative;
    if (evidence.strongPositive) return Sentiment.positive;
    if (parsed == Sentiment.neutral && evidence.positive && score >= 0.65) {
      return Sentiment.positive;
    }
    if (parsed == Sentiment.neutral && score >= 0.75) {
      return Sentiment.positive;
    }
    if (parsed == Sentiment.neutral && score <= 0.25) {
      return Sentiment.negative;
    }
    return parsed;
  }

  static String _reconcileTone(
    String? tone,
    Sentiment sentiment,
    _SentimentEvidence evidence,
  ) {
    final normalized = (tone ?? '').toLowerCase().trim();
    if (normalized.isNotEmpty && normalized != 'neutral') return normalized;
    return switch (sentiment) {
      Sentiment.positive => evidence.strongPositive ? 'delighted' : 'satisfied',
      Sentiment.neutral => 'neutral',
      Sentiment.mixedNegative => 'mixed',
      Sentiment.negative => 'frustrated',
    };
  }

  static double _reconcileScore(
    double score,
    Sentiment sentiment,
    _SentimentEvidence evidence,
  ) {
    return switch (sentiment) {
      Sentiment.positive when evidence.strongPositive =>
        score < 0.9 ? 0.92 : score,
      Sentiment.positive => score < 0.65 ? 0.72 : score,
      Sentiment.neutral => score < 0.35 || score > 0.65 ? 0.5 : score,
      Sentiment.mixedNegative => score > 0.45 ? 0.38 : score,
      Sentiment.negative => score > 0.35 ? 0.22 : score,
    };
  }

  static double _reconcileConfidence(
    double confidence,
    Sentiment sentiment,
    _SentimentEvidence evidence,
  ) {
    if (sentiment == Sentiment.positive && evidence.strongPositive) {
      return confidence < 0.82 ? 0.82 : confidence;
    }
    if (sentiment.offerEligible && evidence.negative) {
      return confidence < 0.78 ? 0.78 : confidence;
    }
    return confidence;
  }
}

class _SentimentEvidence {
  final bool positive;
  final bool negative;
  final bool strongPositive;
  final bool request;

  const _SentimentEvidence({
    required this.positive,
    required this.negative,
    required this.strongPositive,
    required this.request,
  });
}

class BugReproEvidence {
  final String selectedSeat;
  final String screen;
  final String route;
  final List<String> userActions;
  final String expectedOutcome;
  final String observedOutcome;
  final List<String> observedSignals;

  const BugReproEvidence({
    this.selectedSeat = '',
    this.screen = '',
    this.route = '',
    this.userActions = const [],
    this.expectedOutcome = '',
    this.observedOutcome = '',
    this.observedSignals = const [],
  });

  bool get hasFacts =>
      selectedSeat.trim().isNotEmpty ||
      screen.trim().isNotEmpty ||
      route.trim().isNotEmpty ||
      userActions.any((action) => action.trim().isNotEmpty) ||
      expectedOutcome.trim().isNotEmpty ||
      observedOutcome.trim().isNotEmpty ||
      observedSignals.any((signal) => signal.trim().isNotEmpty);
}

class BugReproReport {
  final String title;
  final String summary;
  final List<String> steps;
  final String expectedBehavior;
  final String actualBehavior;
  final String severity;
  final List<String> observedSignals;
  final String narrationTranscript;
  final String? videoPath;
  final String? videoUrl;
  final String? videoUploadNote;

  BugReproReport({
    required this.title,
    required this.summary,
    required this.steps,
    required this.expectedBehavior,
    required this.actualBehavior,
    required this.severity,
    required this.observedSignals,
    required this.narrationTranscript,
    this.videoPath,
    this.videoUrl,
    this.videoUploadNote,
  });

  factory BugReproReport.fromJson(
    Map<String, dynamic> json, {
    String narrationTranscript = '',
    String? videoPath,
    String? videoUrl,
    String? videoUploadNote,
  }) {
    final fallback = BugReproReport.fromNarration(
      narrationTranscript,
      videoPath: videoPath,
    );
    final steps =
        (json['steps'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const [];
    final observedSignals =
        (json['observed_signals'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const [];
    final title = (json['title'] as String?)?.trim();
    final summary = (json['summary'] as String?)?.trim();
    final expected = (json['expected_behavior'] as String?)?.trim();
    final actual = (json['actual_behavior'] as String?)?.trim();
    final modelSeverity = _normalizeSeverity(json['severity'] as String?);
    final severity = _reconcileSeverity(
      modelSeverity,
      evidenceText: [
        narrationTranscript,
        summary,
        actual,
        ...observedSignals,
      ].whereType<String>().join('\n'),
    );

    return BugReproReport(
      title: title == null || title.isEmpty ? fallback.title : title,
      summary: summary == null || summary.isEmpty ? fallback.summary : summary,
      steps: steps.isEmpty ? fallback.steps : steps,
      expectedBehavior: expected == null || expected.isEmpty
          ? fallback.expectedBehavior
          : expected,
      actualBehavior: actual == null || actual.isEmpty
          ? fallback.actualBehavior
          : actual,
      severity: severity,
      observedSignals: observedSignals.isEmpty
          ? fallback.observedSignals
          : observedSignals,
      narrationTranscript: narrationTranscript,
      videoPath: videoPath,
      videoUrl: videoUrl,
      videoUploadNote: videoUploadNote,
    );
  }

  factory BugReproReport.fallback(
    String transcript, {
    String? videoPath,
    String? videoUploadNote,
  }) {
    return BugReproReport.fromNarration(
      transcript,
      videoPath: videoPath,
      videoUploadNote: videoUploadNote,
    );
  }

  factory BugReproReport.fromEvidence(
    BugReproEvidence evidence, {
    required String narrationTranscript,
    String? videoPath,
    String? videoUploadNote,
  }) {
    if (!evidence.hasFacts) {
      return BugReproReport.fromNarration(
        narrationTranscript,
        videoPath: videoPath,
        videoUploadNote: videoUploadNote,
      );
    }

    final fallback = BugReproReport.fromNarration(
      narrationTranscript,
      videoPath: videoPath,
      selectedSeat: evidence.selectedSeat,
      videoUploadNote: videoUploadNote,
    );
    final evidenceText = [
      evidence.selectedSeat,
      evidence.screen,
      evidence.route,
      evidence.expectedOutcome,
      evidence.observedOutcome,
      ...evidence.userActions,
      ...evidence.observedSignals,
      narrationTranscript,
    ].join('\n');
    final actionLower = evidence.userActions.join('\n').toLowerCase();
    final observedLower = [
      evidence.expectedOutcome,
      evidence.observedOutcome,
      ...evidence.observedSignals,
    ].join('\n').toLowerCase();
    final narrationLower = narrationTranscript.toLowerCase();
    final seat = _normalizeSeat(evidence.selectedSeat);
    final hasBuyAction = RegExp(
      r'\b(buy now|buy|purchase|checkout|pay|continue)\b',
    ).hasMatch(actionLower.isEmpty ? narrationLower : actionLower);
    final hasError = RegExp(
      r'\b(error|alert|popup|pop up|failed|failure|something went wrong)\b',
    ).hasMatch(observedLower.isEmpty ? narrationLower : observedLower);
    final hasSpinner = RegExp(
      r'\b(spinner|loading|stuck|hang|hangs|forever|timeout)\b',
    ).hasMatch(observedLower.isEmpty ? narrationLower : observedLower);
    final steps = _buildEvidenceSteps(
      evidence: evidence,
      fallback: fallback,
      seat: seat,
      hasBuyAction: hasBuyAction,
      hasError: hasError,
      hasSpinner: hasSpinner,
    );
    final expected = evidence.expectedOutcome.trim();
    final actual = evidence.observedOutcome.trim();

    return BugReproReport(
      title: _buildEvidenceTitle(
        fallback: fallback,
        seat: seat,
        hasBuyAction: hasBuyAction,
        hasError: hasError,
        hasSpinner: hasSpinner,
      ),
      summary: _buildEvidenceSummary(
        fallback: fallback,
        seat: seat,
        hasBuyAction: hasBuyAction,
        hasError: hasError,
        hasSpinner: hasSpinner,
      ),
      steps: steps,
      expectedBehavior: expected.isEmpty
          ? fallback.expectedBehavior
          : _sentence(expected),
      actualBehavior: actual.isEmpty
          ? fallback.actualBehavior
          : _sentence(actual),
      severity: _reconcileSeverity('medium', evidenceText: evidenceText),
      observedSignals: _buildEvidenceObservedSignals(
        evidence: evidence,
        fallback: fallback,
        hasBuyAction: hasBuyAction,
        hasError: hasError,
        hasSpinner: hasSpinner,
      ),
      narrationTranscript: narrationTranscript,
      videoPath: videoPath,
      videoUploadNote: videoUploadNote,
    );
  }

  factory BugReproReport.fromNarration(
    String transcript, {
    String? videoPath,
    String? selectedSeat,
    String? videoUploadNote,
  }) {
    final normalizedTranscript = transcript.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final lower = transcript.toLowerCase();
    final seat = _normalizeSeat(selectedSeat) ?? _extractSeat(transcript);
    final hasSeatAction =
        seat != null ||
        RegExp(r'\b(tap|select|choose|open)\b.*\bseat\b').hasMatch(lower);
    final hasBuyAction = RegExp(
      r'\b(buy now|buy|purchase|checkout|pay|continue)\b',
    ).hasMatch(lower);
    final hasError = RegExp(
      r'\b(error|alert|popup|pop up|failed|failure|something went wrong)\b',
    ).hasMatch(lower);
    final hasSpinner = RegExp(
      r'\b(spinner|loading|stuck|hang|hangs|forever|timeout)\b',
    ).hasMatch(lower);
    final steps = _buildNarratedSteps(
      transcript: normalizedTranscript,
      seat: seat,
      hasSeatAction: hasSeatAction,
      hasBuyAction: hasBuyAction,
      hasError: hasError,
      hasSpinner: hasSpinner,
    );
    final severity = _inferSeverity(lower);
    final titleSeed = _buildNarratedTitle(
      transcript: normalizedTranscript,
      seat: seat,
      hasBuyAction: hasBuyAction,
      hasError: hasError,
      hasSpinner: hasSpinner,
    );
    final summary = _buildNarratedSummary(
      transcript: normalizedTranscript,
      seat: seat,
      hasBuyAction: hasBuyAction,
      hasError: hasError,
      hasSpinner: hasSpinner,
    );
    return BugReproReport(
      title: titleSeed.length > 80
          ? '${titleSeed.substring(0, 77)}...'
          : titleSeed,
      summary: summary,
      steps: steps,
      expectedBehavior: lower.contains('checkout')
          ? 'Checkout should load and allow the user to continue.'
          : hasBuyAction
          ? 'Tapping Buy Now should complete the purchase flow or move to the next checkout step.'
          : 'The app should complete the user action without an error.',
      actualBehavior: _buildNarratedActual(
        transcript: normalizedTranscript,
        hasError: hasError,
        hasSpinner: hasSpinner,
      ),
      severity: severity,
      observedSignals: _buildObservedSignals(
        seat: seat,
        hasBuyAction: hasBuyAction,
        hasError: hasError,
        hasSpinner: hasSpinner,
      ),
      narrationTranscript: transcript,
      videoPath: videoPath,
      videoUploadNote: videoUploadNote,
    );
  }

  static List<String> _buildEvidenceSteps({
    required BugReproEvidence evidence,
    required BugReproReport fallback,
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final steps = evidence.userActions
        .map(_sentence)
        .where((step) => step.isNotEmpty)
        .where((step) => !_isTranscriptStyleStep(step))
        .toList();
    String lowerSteps() => steps.join('\n').toLowerCase();

    if (seat != null && !lowerSteps().contains(seat.toLowerCase())) {
      steps.insert(0, 'Select $seat from the ticket list.');
    }
    if (hasBuyAction &&
        !RegExp(
          r'\b(buy now|buy|purchase|checkout)\b',
        ).hasMatch(lowerSteps())) {
      steps.add('Tap Buy Now.');
    }
    if (hasSpinner &&
        !hasError &&
        !RegExp(r'\b(wait|loading|finish loading)\b').hasMatch(lowerSteps())) {
      steps.add('Wait for checkout to finish loading.');
    }
    if (hasError && !RegExp(r'\b(error|alert)\b').hasMatch(lowerSteps())) {
      steps.add('Observe the error alert instead of a completed checkout.');
    } else if (hasSpinner &&
        !RegExp(
          r'\b(stuck|does not resolve|remains)\b',
        ).hasMatch(lowerSteps())) {
      steps.add('Observe that the checkout flow remains stuck.');
    }

    final durable = _dedupe(steps);
    return durable.isEmpty ? fallback.steps : durable;
  }

  static bool _isTranscriptStyleStep(String step) {
    return RegExp(
      r"^\s*(so\s+)?(i|we)\s+(tap|click|press|select|choose|see|saw|try|tried|am|was|were)\b",
      caseSensitive: false,
    ).hasMatch(step);
  }

  static String _buildEvidenceTitle({
    required BugReproReport fallback,
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final target = seat ?? 'selected seat';
    if (hasBuyAction && hasError) {
      return 'Checkout error after tapping Buy Now for $target';
    }
    if (hasBuyAction && hasSpinner) {
      return 'Checkout gets stuck after tapping Buy Now for $target';
    }
    return fallback.title;
  }

  static String _buildEvidenceSummary({
    required BugReproReport fallback,
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final target = seat ?? 'the selected seat';
    if (hasBuyAction && hasError) {
      return 'Selecting $target and tapping Buy Now shows an error instead of completing checkout.';
    }
    if (hasBuyAction && hasSpinner) {
      return 'Selecting $target and tapping Buy Now leaves checkout stuck instead of advancing.';
    }
    return fallback.summary;
  }

  static List<String> _buildEvidenceObservedSignals({
    required BugReproEvidence evidence,
    required BugReproReport fallback,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    return _dedupe([
      if (evidence.selectedSeat.trim().isNotEmpty)
        'Selected seat: ${evidence.selectedSeat.trim()}',
      if (evidence.screen.trim().isNotEmpty)
        'Screen: ${evidence.screen.trim()}',
      if (evidence.route.trim().isNotEmpty) 'Route: ${evidence.route.trim()}',
      ...evidence.observedSignals,
      if (hasBuyAction) 'Buy Now action was attempted',
      if (hasError) 'Error alert or error state appeared',
      if (hasSpinner) 'Checkout/loading state did not resolve',
      if (hasBuyAction && (hasError || hasSpinner))
        'Purchase flow did not complete',
      if (evidence.observedSignals.isEmpty) ...fallback.observedSignals,
    ]);
  }

  static String _sentence(String value) {
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty) return '';
    if (RegExp(r'[.!?]$').hasMatch(trimmed)) return trimmed;
    return '$trimmed.';
  }

  static List<String> _buildNarratedSteps({
    required String transcript,
    required String? seat,
    required bool hasSeatAction,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final steps = <String>[];
    if (hasSeatAction) {
      steps.add(
        seat == null
            ? 'Select the affected seat from the ticket list.'
            : 'Select $seat from the ticket list.',
      );
    }
    if (hasBuyAction) {
      steps.add('Tap Buy Now.');
    }
    if (hasSpinner) {
      steps.add('Wait for checkout to finish loading.');
    }
    if (hasError) {
      steps.add('Observe the error alert instead of a completed checkout.');
    } else if (hasSpinner) {
      steps.add('Observe that the checkout flow remains stuck.');
    }
    if (steps.isNotEmpty) return _dedupe(steps);
    return transcript.isEmpty
        ? const ['Reproduce the narrated action.']
        : [transcript];
  }

  static String _buildNarratedTitle({
    required String transcript,
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final target = seat ?? 'selected seat';
    if (hasBuyAction && hasError) {
      return 'Checkout error after tapping Buy Now for $target';
    }
    if (hasBuyAction && hasSpinner) {
      return 'Checkout gets stuck after tapping Buy Now for $target';
    }
    if (seat != null) return 'Bug while using $seat';
    return transcript.isEmpty ? 'Bug reproduction' : transcript;
  }

  static String _buildNarratedSummary({
    required String transcript,
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    final target = seat ?? 'the selected seat';
    if (hasBuyAction && hasError) {
      return 'Selecting $target and tapping Buy Now shows an error instead of completing checkout.';
    }
    if (hasBuyAction && hasSpinner) {
      return 'Selecting $target and tapping Buy Now leaves checkout stuck instead of advancing.';
    }
    return transcript;
  }

  static String _buildNarratedActual({
    required String transcript,
    required bool hasError,
    required bool hasSpinner,
  }) {
    if (hasError && hasSpinner) {
      return 'Checkout does not complete; the flow remains stuck and an error alert is shown.';
    }
    if (hasError) {
      return 'An error alert is shown and checkout does not complete.';
    }
    if (hasSpinner) {
      return 'Checkout remains stuck in a loading state.';
    }
    return transcript;
  }

  static List<String> _buildObservedSignals({
    required String? seat,
    required bool hasBuyAction,
    required bool hasError,
    required bool hasSpinner,
  }) {
    return _dedupe([
      if (seat != null) 'Selected seat: $seat',
      if (hasBuyAction) 'Buy Now action was attempted',
      if (hasError) 'Error alert or error state appeared',
      if (hasSpinner) 'Checkout/loading state did not resolve',
      if (hasBuyAction && (hasError || hasSpinner))
        'Purchase flow did not complete',
    ]);
  }

  static String? _extractSeat(String transcript) {
    final match = RegExp(
      r'\bsection\s+([a-z0-9]+)(?:\s*,?\s*row\s+([a-z0-9]+))?',
      caseSensitive: false,
    ).firstMatch(transcript);
    if (match == null) return null;
    final section = match.group(1);
    final row = match.group(2);
    if (section == null || section.isEmpty) return null;
    if (row == null || row.isEmpty) return 'Section ${section.toUpperCase()}';
    return 'Section ${section.toUpperCase()}, Row ${row.toUpperCase()}';
  }

  static String? _normalizeSeat(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static List<String> _dedupe(Iterable<String> values) {
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      final cleaned = value.trim();
      if (cleaned.isEmpty || !seen.add(cleaned.toLowerCase())) continue;
      out.add(cleaned);
    }
    return out;
  }

  static String _normalizeSeverity(String? raw) {
    final s = (raw ?? 'medium').toLowerCase().trim();
    if (const {'critical', 'high', 'medium', 'low'}.contains(s)) return s;
    return 'medium';
  }

  static String _reconcileSeverity(
    String modelSeverity, {
    required String evidenceText,
  }) {
    final inferred = _inferSeverity(evidenceText.toLowerCase());
    if (_severityRank(inferred) > _severityRank(modelSeverity)) {
      return inferred;
    }
    return modelSeverity;
  }

  static String _inferSeverity(String lower) {
    if (RegExp(
      r'\b(crash|data loss|lost data|double charge|charged twice|security|privacy|payment charged)\b',
    ).hasMatch(lower)) {
      return 'critical';
    }
    if (RegExp(
      r"\b(stuck|blocked|broken|cannot|can't|cant|unable|spinner|timeout|forever|checkout|buy now|error alert|payment failed|purchase failed)\b",
    ).hasMatch(lower)) {
      return 'high';
    }
    if (RegExp(
      r'\b(slow|confusing|glitch|incorrect|missing)\b',
    ).hasMatch(lower)) {
      return 'medium';
    }
    return 'low';
  }

  static int _severityRank(String severity) => switch (severity) {
    'critical' => 4,
    'high' => 3,
    'medium' => 2,
    'low' => 1,
    _ => 2,
  };
}

class FeedbackAnalyzer {
  final CactusEngine engine;
  final FeedbackKnowledgeBase knowledgeBase;
  final bool enableNativeRag;

  FeedbackAnalyzer(
    this.engine, {
    FeedbackKnowledgeBase? knowledgeBase,
    this.enableNativeRag = false,
  }) : knowledgeBase = knowledgeBase ?? FeedbackKnowledgeBase.bundled();

  static const _feedbackSchema = {
    'type': 'object',
    'properties': {
      'summary': {'type': 'string'},
      'sentiment': {
        'type': 'string',
        'enum': ['positive', 'neutral', 'mixed_negative', 'negative'],
      },
      'sentiment_score': {'type': 'number'},
      'sentiment_confidence': {'type': 'number'},
      'category': {
        'type': 'string',
        'enum': [
          'Checkout & Payment',
          'Ticket Selection',
          'Search & Discovery',
          'Account & Login',
          'Performance',
          'Pricing & Fees',
          'UI/UX Design',
          'Content & Information',
          'Customer Support',
          'General',
        ],
      },
      'themes': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'pain_points': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'requested_outcome': {'type': 'string'},
      'emotional_tone': {
        'type': 'string',
        'enum': [
          'frustrated',
          'disappointed',
          'confused',
          'neutral',
          'mixed',
          'satisfied',
          'delighted',
          'angry',
        ],
      },
      'actionable_insight': {'type': 'string'},
      'offer_eligible': {'type': 'boolean'},
      'evidence': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'quote': {'type': 'string'},
            'polarity': {
              'type': 'string',
              'enum': ['positive', 'negative', 'neutral', 'request'],
            },
            'strength': {
              'type': 'string',
              'enum': ['strong', 'moderate', 'weak'],
            },
          },
          'required': ['quote', 'polarity', 'strength'],
        },
      },
      'praise_present': {'type': 'boolean'},
      'complaints_present': {'type': 'boolean'},
      'request_present': {'type': 'boolean'},
    },
    'required': [
      'summary',
      'sentiment',
      'sentiment_score',
      'sentiment_confidence',
      'category',
      'themes',
      'pain_points',
      'requested_outcome',
      'emotional_tone',
      'actionable_insight',
      'offer_eligible',
      'evidence',
      'praise_present',
      'complaints_present',
      'request_present',
    ],
  };

  static const _bugReproSchema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'summary': {'type': 'string'},
      'steps': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'expected_behavior': {'type': 'string'},
      'actual_behavior': {'type': 'string'},
      'severity': {
        'type': 'string',
        'enum': ['critical', 'high', 'medium', 'low'],
      },
      'observed_signals': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': [
      'title',
      'summary',
      'steps',
      'expected_behavior',
      'actual_behavior',
      'severity',
      'observed_signals',
    ],
  };

  Future<FeedbackReport> analyzeFeedback({
    required String transcript,
    Uint8List? pcmData,
    void Function(String activity)? onProgress,
  }) async {
    onProgress?.call('Agent thinking');
    final initial = FeedbackReport.fromTranscript(transcript);
    onProgress?.call('Agent searching KB');
    final kbMatches = await knowledgeBase.search(
      transcript: transcript,
      category: initial.category,
      themes: initial.themes,
      painPoints: initial.painPoints,
    );
    var kbContext = FeedbackKnowledgeBase.renderForPrompt(kbMatches);
    if (enableNativeRag) {
      onProgress?.call('Agent using Cactus RAG');
      final nativeContext = await _nativeRagContext(transcript);
      if (nativeContext.trim().isNotEmpty) {
        kbContext = '$kbContext\n\n$nativeContext';
      }
    }
    try {
      onProgress?.call('Agent summarizing');
      final result = await engine.completeJson(
        messages: [
          {
            'role': 'user',
            'content': _buildFeedbackPrompt(
              transcript: transcript,
              kbContext: kbContext,
            ),
          },
        ],
        schema: _feedbackSchema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.0,
        pcmData: pcmData,
      );
      final report = FeedbackReport.fromJson(
        result,
        plainTranscript: transcript,
      );
      return _attachResolution(report, kbMatches);
    } catch (_) {
      return _attachResolution(FeedbackReport.fallback(transcript), kbMatches);
    }
  }

  Future<BugReproReport> analyzeBugRepro({
    required String transcript,
    Uint8List? pcmData,
  }) async {
    try {
      final result = await engine.completeJson(
        messages: [
          {'role': 'user', 'content': _buildBugReproPrompt(transcript)},
        ],
        schema: _bugReproSchema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.1,
        pcmData: pcmData,
      );
      return BugReproReport.fromJson(result, narrationTranscript: transcript);
    } catch (_) {
      return BugReproReport.fallback(transcript);
    }
  }

  FeedbackReport _attachResolution(
    FeedbackReport report,
    List<FeedbackKbMatch> kbMatches,
  ) {
    if (!report.sentiment.offerEligible && !report.complaintsPresent) {
      return report;
    }
    return report.withResolution(knowledgeBase.buildResolution(kbMatches));
  }

  Future<String> _nativeRagContext(String transcript) async {
    try {
      final raw = await engine.ragQuery(
        query: transcript,
        topK: 3,
        timeout: const Duration(seconds: 2),
      );
      if (raw.trim().isEmpty) return '';
      return 'Native Cactus RAG results:\n$raw';
    } catch (_) {
      return '';
    }
  }

  String _buildFeedbackPrompt({
    required String transcript,
    required String kbContext,
  }) {
    return '''You are converting a user's spoken feedback into a product triage record for a Ticketmaster-like app.

The user took time to report their experience. Preserve what they said faithfully.
Overstating sentiment can create the wrong customer response; understating frustration can hide real user pain. Base sentiment and evidence only on the transcript.

Transcript:
"""
$transcript
"""

Relevant local knowledge base articles:
"""
$kbContext
"""

Return one JSON object matching the schema.

Rules:
- Do not rewrite the transcript.
- Do not invent events, causes, product areas, or user intent.
- Use the knowledge base only for actionable_insight and requested_outcome. Do not use it as evidence that the user felt something.
- If evidence is weak, use lower confidence and neutral or mixed_negative sentiment.
- Sentiment should reflect the user's experience, not politeness.
- Use "mixed_negative" when the user mentions positives but the actionable takeaway is frustration or a blocker.
- Use "negative" when the user reports failure, confusion, anger, abandonment, payment or checkout trouble, or inability to complete the goal.
- Use "positive" only when the feedback is clearly favorable with no meaningful complaint.
- Explicit praise such as "I love this app", "favorite app", "best app", "excellent", or "amazing" is positive and should score 0.9 or higher unless the transcript also contains a complaint.
- Use "neutral" for factual requests or ambiguous feedback.
- Do not create coupon copy. Set offer_eligible true only when sentiment is "negative" or "mixed_negative".
- Add 1-3 evidence items for positive, negative, or requested-outcome signals. Each evidence quote must be copied exactly from the transcript and must support its polarity.
- Set praise_present, complaints_present, and request_present from transcript evidence only. Do not infer these booleans without a matching evidence quote.

sentiment_score: 0.0 = extremely negative, 0.5 = neutral, 1.0 = extremely positive.
sentiment_confidence: 0.0 = uncertain, 1.0 = very confident.
themes: key topics the user mentioned (e.g., "slow loading", "confusing navigation", "great prices").
pain_points: specific frustrations or blockers, if any.
requested_outcome: what the user wants changed or preserved.
actionable_insight: one concrete recommendation for the product team.

Reply with ONLY the JSON object. No prose, no code fences.''';
  }

  String _buildBugReproPrompt(String transcript) {
    return '''You are analyzing a bug reproduction narration from an app user. While reproducing the bug, the user narrated what they were doing:

"$transcript"

Extract a structured step-by-step reproduction from their narration. Each step should be a clear action (e.g., "Tap on Section 105, Row 10", "Wait for checkout to load").
Also summarize the bug and list observed signals such as spinner, error dialog, timeout, crash, or missing discount when present.
Severity guide: critical = crash, data loss, duplicate charge, security, or privacy issue; high = user is blocked, checkout/payment is broken, spinner/timeout never clears, or the goal cannot be completed; medium = degraded or confusing behavior with a workaround; low = cosmetic issue.
Do not understate severity when the narration contains blocking words like stuck, broken, cannot, unable, spinner, timeout, checkout failure, or payment failure.

Reply with ONLY the JSON object. No prose, no code fences.''';
  }
}
