import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

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

  factory BugReport.fromJson(
    Map<String, dynamic> json, {
    String evidenceText = '',
  }) {
    final title = (json['title'] as String?)?.trim() ?? 'Bug report';
    final description = (json['description'] as String?)?.trim() ?? '';
    final stepsContext = (json['steps_context'] as String?)?.trim() ?? '';
    final expected = (json['expected'] as String?)?.trim() ?? '';
    final actual = (json['actual'] as String?)?.trim() ?? '';
    final uiState = (json['ui_state'] as String?)?.trim() ?? '';
    final severity = _reconcileSeverity(
      _normalizeSeverity(json['severity'] as String?),
      evidenceText: [
        evidenceText,
        title,
        description,
        stepsContext,
        expected,
        actual,
        uiState,
      ].where((item) => item.isNotEmpty).join('\n'),
    );

    return BugReport(
      title: title,
      description: description,
      stepsContext: stepsContext,
      expected: expected,
      actual: actual,
      severity: severity,
      uiState: uiState,
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

  BugReport copyWith({
    String? title,
    String? description,
    String? stepsContext,
    String? expected,
    String? actual,
    String? severity,
    String? uiState,
  }) {
    return BugReport(
      title: title ?? this.title,
      description: description ?? this.description,
      stepsContext: stepsContext ?? this.stepsContext,
      expected: expected ?? this.expected,
      actual: actual ?? this.actual,
      severity: severity != null ? _normalizeSeverity(severity) : this.severity,
      uiState: uiState ?? this.uiState,
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

class ScreenAnalyzer {
  final CactusEngine engine;

  ScreenAnalyzer(this.engine);

  static const _maxImageDimension = 1280;
  static bool? _supportsVision;

  static const _schema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'steps_context': {'type': 'string'},
      'expected': {'type': 'string'},
      'actual': {'type': 'string'},
      'severity': {
        'type': 'string',
        'enum': ['critical', 'high', 'medium', 'low'],
      },
      'ui_state': {'type': 'string'},
    },
    'required': ['title', 'description', 'severity'],
  };

  Future<BugReport> analyze({
    required String transcript,
    Uint8List? screenshotPng,
    Uint8List? pcmData,
  }) async {
    String? tempPath;

    try {
      if (screenshotPng != null && _supportsVision != false) {
        tempPath = await _writeToTempFile(screenshotPng);
      }

      final message = <String, dynamic>{
        'role': 'user',
        'content': _buildPrompt(transcript),
        if (tempPath != null) 'images': [tempPath],
      };

      final result = await engine.completeJson(
        messages: [message],
        schema: _schema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.1,
        pcmData: pcmData,
      );
      if (tempPath != null) _supportsVision = true;
      return BugReport.fromJson(result, evidenceText: transcript);
    } catch (e) {
      if (tempPath != null && _supportsVision == null) {
        _supportsVision = false;
        return _analyzeTextOnly(transcript);
      }
      return BugReport.fallback(transcript);
    } finally {
      if (tempPath != null) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
    }
  }

  Future<BugReport> _analyzeTextOnly(String transcript) async {
    final messages = [
      {'role': 'user', 'content': _buildPrompt(transcript)},
    ];
    try {
      final result = await engine.completeJson(
        messages: messages,
        schema: _schema,
        retries: 2,
        maxTokens: 1024,
        temperature: 0.1,
      );
      return BugReport.fromJson(result, evidenceText: transcript);
    } catch (_) {
      return BugReport.fallback(transcript);
    }
  }

  Future<String> _writeToTempFile(Uint8List pngBytes) async {
    final resized = await _resizeIfNeeded(pngBytes);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/voicebug_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(resized);
    return file.path;
  }

  static Future<Uint8List> _resizeIfNeeded(Uint8List pngBytes) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final w = image.width;
    final h = image.height;

    if (w <= _maxImageDimension && h <= _maxImageDimension) {
      image.dispose();
      return pngBytes;
    }

    final scale = _maxImageDimension / (w > h ? w : h);
    final targetW = (w * scale).round();
    final targetH = (h * scale).round();

    final resizedCodec = await ui.instantiateImageCodec(
      pngBytes,
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final resizedFrame = await resizedCodec.getNextFrame();
    final resizedImage = resizedFrame.image;

    final byteData = await resizedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    resizedImage.dispose();
    image.dispose();

    return byteData!.buffer.asUint8List();
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
