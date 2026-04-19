import 'dart:typed_data';

import '../cactus/engine.dart';

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
  });

  bool get offerCoupon => offer != null && offer!.isNotEmpty;

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

  factory BugReproReport.fallback(String transcript, {String? videoPath}) {
    return BugReproReport.fromNarration(transcript, videoPath: videoPath);
  }

  factory BugReproReport.fromNarration(
    String transcript, {
    String? videoPath,
    String? selectedSeat,
  }) {
    final split = transcript
        .split(
          RegExp(r'(?:\.|\n|\bthen\b|\bafter that\b)', caseSensitive: false),
        )
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final steps = split.isEmpty ? [transcript] : split;
    final lower = transcript.toLowerCase();
    final severity = _inferSeverity(lower);
    final titleSeed = selectedSeat == null || selectedSeat.isEmpty
        ? transcript
        : 'Bug while using $selectedSeat';
    return BugReproReport(
      title: titleSeed.length > 80
          ? '${titleSeed.substring(0, 77)}...'
          : titleSeed,
      summary: transcript,
      steps: steps,
      expectedBehavior: lower.contains('checkout')
          ? 'Checkout should load and allow the user to continue.'
          : 'The app should complete the user action without an error.',
      actualBehavior: transcript,
      severity: severity,
      observedSignals: [
        if (lower.contains('spinner')) 'Spinner or loading state did not clear',
        if (lower.contains('error')) 'Error dialog or error state appeared',
        if (lower.contains('stuck')) 'Flow became stuck',
      ],
      narrationTranscript: transcript,
      videoPath: videoPath,
    );
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
      r"\b(stuck|blocked|broken|cannot|can't|cant|unable|spinner|timeout|forever|checkout|payment failed|purchase failed)\b",
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

  FeedbackAnalyzer(this.engine);

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
  }) async {
    try {
      final result = await engine.completeJson(
        messages: [
          {'role': 'user', 'content': _buildFeedbackPrompt(transcript)},
        ],
        schema: _feedbackSchema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.0,
        pcmData: pcmData,
      );
      return FeedbackReport.fromJson(result, plainTranscript: transcript);
    } catch (_) {
      return FeedbackReport.fallback(transcript);
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

  String _buildFeedbackPrompt(String transcript) {
    return '''You are converting a user's spoken feedback into a product triage record for a Ticketmaster-like app.

The user took time to report their experience. Preserve what they said faithfully.
Overstating sentiment can create the wrong customer response; understating frustration can hide real user pain. Base every field only on the transcript.

Transcript:
"""
$transcript
"""

Return one JSON object matching the schema.

Rules:
- Do not rewrite the transcript.
- Do not invent events, causes, product areas, or user intent.
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
