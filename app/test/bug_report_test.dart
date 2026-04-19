import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/screen_analyzer.dart';

void main() {
  group('BugReport.fromJson', () {
    test('parses all fields', () {
      final report = BugReport.fromJson({
        'title': 'Button broken',
        'description': 'Add to cart does nothing',
        'steps_context': 'On product page',
        'expected': 'Item added to cart',
        'actual': 'Nothing happens',
        'severity': 'high',
        'ui_state': 'Product detail view',
      });

      expect(report.title, 'Button broken');
      expect(report.description, 'Add to cart does nothing');
      expect(report.stepsContext, 'On product page');
      expect(report.expected, 'Item added to cart');
      expect(report.actual, 'Nothing happens');
      expect(report.severity, 'high');
      expect(report.uiState, 'Product detail view');
    });

    test('defaults missing optional fields', () {
      final report = BugReport.fromJson({
        'title': 'Bug',
        'description': 'Something broke',
        'severity': 'low',
      });

      expect(report.title, 'Bug');
      expect(report.stepsContext, '');
      expect(report.expected, '');
      expect(report.actual, '');
      expect(report.uiState, '');
    });

    test('defaults missing title', () {
      final report = BugReport.fromJson({
        'description': 'broke',
        'severity': 'medium',
      });
      expect(report.title, 'Bug report');
    });

    test('trims whitespace', () {
      final report = BugReport.fromJson({
        'title': '  spaced title  ',
        'description': '\n desc \n',
        'severity': 'low',
      });
      expect(report.title, 'spaced title');
      expect(report.description, 'desc');
    });

    test('normalizes invalid severity to medium', () {
      expect(BugReport.fromJson({'severity': 'URGENT'}).severity, 'medium');
      expect(BugReport.fromJson({'severity': ''}).severity, 'medium');
      expect(BugReport.fromJson({}).severity, 'medium');
    });

    test('normalizes valid severity case-insensitively', () {
      expect(BugReport.fromJson({'severity': 'CRITICAL'}).severity, 'critical');
      expect(BugReport.fromJson({'severity': 'High'}).severity, 'high');
      expect(BugReport.fromJson({'severity': ' LOW '}).severity, 'low');
    });

    test('reconciles understated severity from report evidence', () {
      final report = BugReport.fromJson({
        'title': 'Checkout issue',
        'description': 'Checkout does not finish',
        'steps_context': 'User tapped buy',
        'expected': 'Checkout completes',
        'actual': 'The spinner runs forever',
        'severity': 'low',
        'ui_state': 'Checkout loading',
      });

      expect(report.severity, 'high');
    });
  });

  group('BugReport.fallback', () {
    test('uses full transcript as title when short', () {
      final report = BugReport.fallback('Button broken');
      expect(report.title, 'Button broken');
      expect(report.description, 'Button broken');
      expect(report.severity, 'medium');
    });

    test('truncates title at 80 chars', () {
      final long = 'A' * 100;
      final report = BugReport.fallback(long);
      expect(report.title.length, 80);
      expect(report.title.endsWith('...'), true);
      expect(report.description, long);
    });

    test('sets all structured fields to Not available', () {
      final report = BugReport.fallback('test');
      expect(report.stepsContext, 'Not available');
      expect(report.expected, 'Not available');
      expect(report.actual, 'Not available');
      expect(report.uiState, 'Not available');
    });
  });

  group('BugReport.copyWith', () {
    test('copies with overrides', () {
      final original = BugReport(
        title: 'original',
        description: 'desc',
        stepsContext: 'steps',
        expected: 'exp',
        actual: 'act',
        severity: 'low',
        uiState: 'ui',
      );

      final updated = original.copyWith(
        title: 'new title',
        severity: 'critical',
      );
      expect(updated.title, 'new title');
      expect(updated.severity, 'critical');
      expect(updated.description, 'desc');
    });

    test('normalizes severity on copy', () {
      final report = BugReport.fallback('test');
      final updated = report.copyWith(severity: 'INVALID');
      expect(updated.severity, 'medium');
    });
  });
}
