import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GitHubClient {
  final String owner;
  final String repo;
  final String token;
  String? _lastError;
  Future<void> _assetUploadTail = Future<void>.value();

  static const _assetBranch = 'voicebug-assets';
  static const maxVideoUploadBytes = 95 * 1024 * 1024;

  GitHubClient({required this.owner, required this.repo, required this.token});

  Map<String, String> get _headers => {
    'Authorization': 'token $token',
    'Accept': 'application/vnd.github.v3+json',
  };

  String? get lastError => _lastError;

  Future<String?> uploadScreenshot(Uint8List pngBytes) async {
    return _uploadAsset(
      pathPrefix: 'screenshots',
      extension: 'png',
      bytes: pngBytes,
      messagePrefix: 'VoiceBug screenshot',
    );
  }

  Future<String?> uploadVideo(Uint8List videoBytes) async {
    if (videoBytes.length > maxVideoUploadBytes) {
      _lastError =
          'Screen recording is ${(videoBytes.length / (1024 * 1024)).toStringAsFixed(1)} MB, above the 95 MB upload limit.';
      return null;
    }
    return _uploadAsset(
      pathPrefix: 'videos',
      extension: 'mp4',
      bytes: videoBytes,
      messagePrefix: 'VoiceBug screen recording',
    );
  }

  Future<String?> _uploadAsset({
    required String pathPrefix,
    required String extension,
    required Uint8List bytes,
    required String messagePrefix,
  }) {
    return _enqueueAssetUpload(() async {
      _lastError = null;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '$pathPrefix/$timestamp.$extension';
      final b64 = base64Encode(bytes);

      var resp = await _putContent(path, b64, '$messagePrefix $timestamp');

      if (resp.statusCode == 404) {
        final created = await _createAssetBranch();
        if (!created) {
          _lastError =
              'Unable to create the $_assetBranch branch for evidence uploads.';
          return null;
        }
        resp = await _putContent(path, b64, '$messagePrefix $timestamp');
      }

      if (resp.statusCode == 201 || resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final downloadUrl = data['content']?['download_url'] as String?;
        if (downloadUrl == null || downloadUrl.isEmpty) {
          _lastError =
              'GitHub accepted the upload but did not return a file URL.';
          return null;
        }
        return downloadUrl;
      }
      _lastError = _extractApiError(resp);
      return null;
    });
  }

  Future<T> _enqueueAssetUpload<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _assetUploadTail = _assetUploadTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<http.Response> _putContent(String path, String b64, String message) {
    return http.put(
      Uri.parse('https://api.github.com/repos/$owner/$repo/contents/$path'),
      headers: _headers,
      body: jsonEncode({
        'message': message,
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
        'content': 'VoiceBug evidence storage. Do not merge this branch.',
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
          {
            'path': 'README.md',
            'mode': '100644',
            'type': 'blob',
            'sha': blobSha,
          },
        ],
      }),
    );
    if (treeResp.statusCode != 201) return false;
    final treeSha = jsonDecode(treeResp.body)['sha'] as String;

    final commitResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/commits'),
      headers: _headers,
      body: jsonEncode({
        'message': 'Initialize VoiceBug evidence storage',
        'tree': treeSha,
        'parents': <String>[],
      }),
    );
    if (commitResp.statusCode != 201) return false;
    final commitSha = jsonDecode(commitResp.body)['sha'] as String;

    final refResp = await http.post(
      Uri.parse('https://api.github.com/repos/$owner/$repo/git/refs'),
      headers: _headers,
      body: jsonEncode({'ref': 'refs/heads/$_assetBranch', 'sha': commitSha}),
    );
    return refResp.statusCode == 201;
  }

  Future<String?> createIssue({
    required String title,
    required String body,
    required List<String> labels,
  }) async {
    _lastError = null;
    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues');
    var resp = await http.post(
      url,
      headers: _headers,
      body: jsonEncode({'title': title, 'body': body, 'labels': labels}),
    );

    if (resp.statusCode == 403) {
      resp = await http.post(
        url,
        headers: _headers,
        body: jsonEncode({'title': title, 'body': body}),
      );
    }

    if (resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return data['html_url'] as String?;
    }
    _lastError = _extractApiError(resp);
    return null;
  }

  String _extractApiError(http.Response resp) {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final message = (decoded['message'] as String?)?.trim() ?? '';
        if (message.isNotEmpty) {
          final docsUrl =
              (decoded['documentation_url'] as String?)?.trim() ?? '';
          return docsUrl.isEmpty
              ? 'GitHub API ${resp.statusCode}: $message'
              : 'GitHub API ${resp.statusCode}: $message ($docsUrl)';
        }
      }
    } catch (_) {
      // Fall through to a generic HTTP error.
    }
    return 'GitHub API ${resp.statusCode}: ${resp.reasonPhrase ?? 'request failed'}';
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
