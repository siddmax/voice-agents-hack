import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/github_client.dart';

void main() {
  group('GitHubClient.formatIssueBody', () {
    test('formats complete issue body with screenshot', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'high',
        description: 'Cart button unresponsive',
        stepsContext: 'Viewing product detail page',
        expected: 'Item added to cart',
        actual: 'Nothing happens on tap',
        uiState: 'Product detail with Add to Cart button visible',
        deviceTable: '| os | macOS 15.4 |',
        screenshotUrl: 'https://example.com/screenshot.png',
      );

      expect(body, contains('**Severity:** high'));
      expect(body, contains('Cart button unresponsive'));
      expect(body, contains('Viewing product detail page'));
      expect(body, contains('Item added to cart'));
      expect(body, contains('Nothing happens on tap'));
      expect(body, contains('![screenshot](https://example.com/screenshot.png)'));
      expect(body, contains('macOS 15.4'));
      expect(body, contains('No raw audio stored'));
    });

    test('formats body without screenshot', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'medium',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
      );

      expect(body, contains('*No screenshot captured*'));
      expect(body, isNot(contains('![screenshot]')));
    });

    test('includes raw transcript in collapsible section', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'low',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
        rawTranscript: 'the button is not working when I tap it',
      );

      expect(body, contains('<details>'));
      expect(body, contains('Raw voice transcript'));
      expect(body, contains('the button is not working when I tap it'));
      expect(body, contains('</details>'));
    });

    test('omits transcript section when null', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'low',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
      );

      expect(body, isNot(contains('<details>')));
    });

    test('omits transcript section when empty', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'low',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
        rawTranscript: '',
      );

      expect(body, isNot(contains('<details>')));
    });

    test('does not have duplicate Screenshot header', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'high',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
        screenshotUrl: 'https://example.com/img.png',
      );

      final matches = '**Screenshot:**'.allMatches(body).length;
      expect(matches, 1);
    });

    test('privacy footer is accurate', () {
      final body = GitHubClient.formatIssueBody(
        severity: 'low',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        uiState: 'ui',
        deviceTable: 'table',
      );

      expect(body, isNot(contains('No raw audio or unredacted data left')));
      expect(body, contains('No raw audio stored'));
    });
  });
}
