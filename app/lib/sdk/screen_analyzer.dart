import 'dart:convert';
import 'dart:typed_data';

import '../cactus/engine.dart';

class BugReport {
  final String title;
  final String description;
  final String stepsContext;
  final String expected;
  final String actual;
  final String severity;
  final String uiState;

  BugReport({
    required this.title,
    required this.description,
    required this.stepsContext,
    required this.expected,
    required this.actual,
    required this.severity,
    required this.uiState,
  });

  factory BugReport.fromJson(Map<String, dynamic> json) {
    return BugReport(
      title: (json['title'] as String?)?.trim() ?? 'Bug report',
      description: (json['description'] as String?)?.trim() ?? '',
      stepsContext: (json['steps_context'] as String?)?.trim() ?? '',
      expected: (json['expected'] as String?)?.trim() ?? '',
      actual: (json['actual'] as String?)?.trim() ?? '',
      severity: _normalizeSeverity(json['severity'] as String?),
      uiState: (json['ui_state'] as String?)?.trim() ?? '',
    );
  }

  factory BugReport.fallback(String transcript) {
    return BugReport(
      title: transcript.length > 80
          ? '${transcript.substring(0, 77)}...'
          : transcript,
      description: transcript,
      stepsContext: 'Not available',
      expected: 'Not available',
      actual: 'Not available',
      severity: 'medium',
      uiState: 'Not available',
    );
  }

  static String _normalizeSeverity(String? raw) {
    final s = (raw ?? 'medium').toLowerCase().trim();
    if (const {'critical', 'high', 'medium', 'low'}.contains(s)) return s;
    return 'medium';
  }
}

class ScreenAnalyzer {
  final CactusEngine engine;

  ScreenAnalyzer(this.engine);

  static const _schema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'steps_context': {'type': 'string'},
      'expected': {'type': 'string'},
      'actual': {'type': 'string'},
      'severity': {'type': 'string', 'enum': ['critical', 'high', 'medium', 'low']},
      'ui_state': {'type': 'string'},
    },
    'required': ['title', 'description', 'severity'],
  };

  Future<BugReport> analyze({
    required String transcript,
    Uint8List? screenshotPng,
  }) async {
    final content = <Map<String, dynamic>>[];

    if (screenshotPng != null) {
      final b64 = base64Encode(screenshotPng);
      content.add({
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,$b64'},
      });
    }

    content.add({
      'type': 'text',
      'text': _buildPrompt(transcript),
    });

    final messages = [
      {
        'role': 'user',
        'content': content,
      }
    ];

    try {
      final result = await engine.completeJson(
        messages: messages,
        schema: _schema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.1,
      );
      return BugReport.fromJson(result);
    } on JsonRetryExhausted {
      return BugReport.fallback(transcript);
    } catch (_) {
      return BugReport.fallback(transcript);
    }
  }

  String _buildPrompt(String transcript) {
    return '''You are analyzing a bug report from an app user. Given:
- A screenshot of the current app screen (if provided)
- The user's voice description: "$transcript"

Generate a structured bug report as JSON:
{
  "title": "short descriptive title (max 80 chars)",
  "description": "detailed description combining user's words with screen evidence",
  "steps_context": "what user was doing based on screen state",
  "expected": "what user expected (from their words)",
  "actual": "what actually happened (from words + screen evidence)",
  "severity": "critical|high|medium|low",
  "ui_state": "description of current UI state from screenshot"
}

Severity guide: critical = crash or data loss, high = feature completely broken, medium = feature partially broken or visual glitch affecting usability, low = cosmetic.

Reply with ONLY the JSON object. No prose, no code fences.''';
  }
}
