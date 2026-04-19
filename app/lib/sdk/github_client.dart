import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GitHubClient {
  final String owner;
  final String repo;
  final String token;

  GitHubClient({
    required this.owner,
    required this.repo,
    required this.token,
  });

  Map<String, String> get _headers => {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      };

  Future<String?> uploadScreenshot(Uint8List pngBytes) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'voicebug-screenshots/$timestamp.png';
    final b64 = base64Encode(pngBytes);

    final resp = await http.put(
      Uri.parse('https://api.github.com/repos/$owner/$repo/contents/$path'),
      headers: _headers,
      body: jsonEncode({
        'message': 'VoiceBug screenshot $timestamp',
        'content': b64,
      }),
    );

    if (resp.statusCode == 201 || resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['content']?['download_url'] as String?;
    }
    return null;
  }

  Future<String?> createIssue({
    required String title,
    required String body,
    required List<String> labels,
  }) async {
    final resp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/issues'),
      headers: _headers,
      body: jsonEncode({
        'title': title,
        'body': body,
        'labels': labels,
      }),
    );

    if (resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return data['html_url'] as String?;
    }
    return null;
  }

  static String formatIssueBody({
    required String severity,
    required String description,
    required String stepsContext,
    required String expected,
    required String actual,
    required String uiState,
    required String deviceTable,
    String? screenshotUrl,
  }) {
    final screenshotSection = screenshotUrl != null
        ? '**Screenshot:**\n![screenshot]($screenshotUrl)'
        : '*No screenshot captured*';

    return '''## Bug Report (VoiceBug — on-device AI)

**Severity:** $severity

**Description:**
$description

**Steps Context:**
$stepsContext

**Expected:**
$expected

**Actual:**
$actual

**Screenshot:**
$screenshotSection

**Device:**
$deviceTable

**UI State (AI Analysis):**
$uiState

---
*Report structured on-device by VoiceBug. No raw audio or unredacted data left the user\'s device.*''';
  }
}
