import 'dart:io';

import 'github_client.dart';
import 'github_config.dart';

class GitHubIssueRequest {
  final String title;
  final String body;
  final List<String> labels;

  const GitHubIssueRequest({
    required this.title,
    required this.body,
    required this.labels,
  });
}

class GitHubIssueSubmission {
  final String url;
  final String? issueNumber;

  const GitHubIssueSubmission({required this.url, required this.issueNumber});
}

class GitHubIssueFailure implements Exception {
  final String message;

  const GitHubIssueFailure(this.message);

  @override
  String toString() => message;
}

class GitHubIssueService {
  final GitHubConfig? config;
  final GitHubClient? _client;
  String? _lastUploadError;
  int? _lastUploadBytes;

  GitHubIssueService({GitHubConfig? config, GitHubClient? client})
    : config = config ?? GitHubConfig.fromEnvironment(),
      _client = client;

  bool get isReady => config != null || _client != null;

  String? get lastUploadError => _lastUploadError;
  int? get lastUploadBytes => _lastUploadBytes;

  String get readinessMessage {
    if (isReady) return 'GitHub issue submission is configured.';
    return 'GitHub issue submission is not configured. Set VOICEBUG_GH_OWNER, '
        'VOICEBUG_GH_REPO, and VOICEBUG_GH_TOKEN.';
  }

  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    final resolvedConfig = config;
    if (resolvedConfig == null && _client == null) {
      throw GitHubIssueFailure(readinessMessage);
    }

    final client = _client ?? _clientFromConfig(resolvedConfig!);

    final url = await client.createIssue(
      title: request.title,
      body: request.body,
      labels: request.labels,
    );

    if (url == null) {
      throw GitHubIssueFailure(
        client.lastError ??
            'GitHub issue creation failed. Check your repo token and repo config.',
      );
    }

    final issueNumber = Uri.tryParse(url)?.pathSegments.last;
    return GitHubIssueSubmission(
      url: url,
      issueNumber: issueNumber == null || issueNumber.isEmpty
          ? null
          : '#$issueNumber',
    );
  }

  Future<String?> uploadVideoFile(String path) async {
    _lastUploadError = null;
    _lastUploadBytes = null;
    final resolvedConfig = config;
    if (resolvedConfig == null && _client == null) {
      _lastUploadError =
          'GitHub is not configured, so the recording was not uploaded.';
      return null;
    }
    final file = File(path);
    if (!await file.exists()) {
      _lastUploadError =
          'The local screen recording file was not found at $path.';
      return null;
    }
    _lastUploadBytes = await file.length();

    final client = _client ?? _clientFromConfig(resolvedConfig!);
    final url = await client.uploadVideo(await file.readAsBytes());
    if (url == null) {
      _lastUploadError =
          client.lastError ??
          'GitHub did not return a URL for the uploaded recording.';
    }
    return url;
  }

  GitHubClient _clientFromConfig(GitHubConfig config) {
    return GitHubClient(
      owner: config.owner,
      repo: config.repo,
      token: config.token,
    );
  }
}
