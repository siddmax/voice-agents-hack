import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/github_issue_tools.dart';
import 'package:syndai/agent/tool_registry.dart';
import 'package:syndai/sdk/github_client.dart';

class _FakeGitHubClient extends GitHubClient {
  _FakeGitHubClient()
      : super(owner: 'demo', repo: 'repo', token: 'token');

  String? nextUrl = 'https://github.com/demo/repo/issues/882';
  String? lastTitle;
  String? lastBody;
  List<String>? lastLabels;

  @override
  Future<String?> createIssue({
    required String title,
    required String body,
    required List<String> labels,
  }) async {
    lastTitle = title;
    lastBody = body;
    lastLabels = labels;
    return nextUrl;
  }
}

void main() {
  group('registerGitHubIssueTools', () {
    test('registers create_github_issue and returns issue metadata', () async {
      final registry = ToolRegistry();
      final github = _FakeGitHubClient();

      registerGitHubIssueTools(registry, github: github);

      final result = await registry.call('create_github_issue', {
        'title': 'Checkout spinner stuck for Section 105',
        'body': 'Transcript: checkout is not loading',
        'labels': ['bug', 'warriors-checkout'],
      });

      expect(github.lastTitle, 'Checkout spinner stuck for Section 105');
      expect(github.lastBody, 'Transcript: checkout is not loading');
      expect(github.lastLabels, ['bug', 'warriors-checkout']);
      expect(result['ok'], true);
      expect(result['url'], 'https://github.com/demo/repo/issues/882');
      expect(result['issue_number'], '#882');
    });

    test('rejects missing title/body before calling github', () async {
      final registry = ToolRegistry();
      final github = _FakeGitHubClient();

      registerGitHubIssueTools(registry, github: github);

      final result = await registry.call('create_github_issue', {
        'title': '   ',
        'body': '',
      });

      expect(github.lastTitle, isNull);
      expect(result['error'], 'missing_required_fields');
    });

    test('returns issue_create_failed when github returns null', () async {
      final registry = ToolRegistry();
      final github = _FakeGitHubClient()..nextUrl = null;

      registerGitHubIssueTools(registry, github: github);

      final result = await registry.call('create_github_issue', {
        'title': 'title',
        'body': 'body',
      });

      expect(result['error'], 'issue_create_failed');
    });
  });
}
