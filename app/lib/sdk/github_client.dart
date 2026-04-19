import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GitHubClient {
  final String owner;
  final String repo;
  final String token;

  static const _assetBranch = 'voicebug-assets';

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
    final path = '$timestamp.png';
    final b64 = base64Encode(pngBytes);

    var resp = await _putContent(path, b64, timestamp);

    if (resp.statusCode == 404) {
      final created = await _createAssetBranch();
      if (!created) return null;
      resp = await _putContent(path, b64, timestamp);
    }

    if (resp.statusCode == 201 || resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['content']?['download_url'] as String?;
    }
    return null;
  }

  Future<http.Response> _putContent(String path, String b64, int timestamp) {
    return http.put(
      Uri.parse('https://api.github.com/repos/$owner/$repo/contents/$path'),
      headers: _headers,
      body: jsonEncode({
        'message': 'VoiceBug screenshot $timestamp',
        'content': b64,
        'branch': _assetBranch,
      }),
    );
  }

  Future<bool> _createAssetBranch() async {
    final blobResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/blobs'),
      headers: _headers,
      body: jsonEncode({
        'content': 'VoiceBug screenshot storage. Do not merge this branch.',
        'encoding': 'utf-8',
      }),
    );
    if (blobResp.statusCode != 201) return false;
    final blobSha = jsonDecode(blobResp.body)['sha'] as String;

    final treeResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/trees'),
      headers: _headers,
      body: jsonEncode({
        'tree': [
          {'path': 'README.md', 'mode': '100644', 'type': 'blob', 'sha': blobSha},
        ],
      }),
    );
    if (treeResp.statusCode != 201) return false;
    final treeSha = jsonDecode(treeResp.body)['sha'] as String;

    final commitResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/commits'),
      headers: _headers,
      body: jsonEncode({
        'message': 'Initialize VoiceBug screenshot storage',
        'tree': treeSha,
        'parents': <String>[],
      }),
    );
    if (commitResp.statusCode != 201) return false;
    final commitSha = jsonDecode(commitResp.body)['sha'] as String;

    final refResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/refs'),
      headers: _headers,
      body: jsonEncode({
        'ref': 'refs/heads/$_assetBranch',
        'sha': commitSha,
      }),
    );
    return refResp.statusCode == 201;
  }

  Future<String?> createIssue({
    required String title,
    required String body,
    required List<String> labels,
  }) async {
    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues');
    var resp = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({
        'title': title,
        'body': body,
        'labels': labels,
      }),
    );

    if (resp.statusCode == 403) {
      resp = await http.post(
        url,
        headers: _headers,
        body: jsonEncode({
          'title': title,
          'body': body,
        }),
      );
    }

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
    String? rawTranscript,
  }) {
    final screenshotSection = screenshotUrl != null
        ? '![screenshot]($screenshotUrl)'
        : '*No screenshot captured*';

    final transcriptSection = rawTranscript != null && rawTranscript.isNotEmpty
        ? '\n<details>\n<summary>Raw voice transcript</summary>\n\n$rawTranscript\n\n</details>\n'
        : '';

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
$transcriptSection
---
*Report structured on-device by VoiceBug. Screenshot and structured text sent to GitHub. No raw audio stored.*''';
  }
}
