import '../sdk/github_client.dart';
import 'tool_registry.dart';

void registerGitHubIssueTools(
  ToolRegistry registry, {
  required GitHubClient github,
}) {
  registry.register(ToolSpec(
    name: 'create_github_issue',
    description:
        'Create a GitHub issue in the configured repo with title, body, and labels.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'body': {'type': 'string'},
        'labels': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['title', 'body'],
    },
    executor: (args) async {
      final title = (args['title'] as String?)?.trim() ?? '';
      final body = (args['body'] as String?)?.trim() ?? '';
      final labels = ((args['labels'] as List?) ?? const [])
          .whereType<String>()
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toList();

      if (title.isEmpty || body.isEmpty) {
        return {
          'error': 'missing_required_fields',
          'message': 'title and body are required',
        };
      }

      final url = await github.createIssue(
        title: title,
        body: body,
        labels: labels,
      );
      if (url == null) {
        return {
          'error': 'issue_create_failed',
          'message': 'GitHub issue creation failed',
        };
      }

      final issueNumber = Uri.tryParse(url)?.pathSegments.last;
      return {
        'ok': true,
        'url': url,
        if (issueNumber != null && issueNumber.isNotEmpty)
          'issue_number': '#$issueNumber',
      };
    },
  ));
}
