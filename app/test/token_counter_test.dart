import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/compaction.dart';

void main() {
  group('TokenCounter.estimate', () {
    test('empty string -> 0', () {
      expect(TokenCounter.estimate(''), 0);
    });

    test('"abcd" (4 chars) -> 1', () {
      expect(TokenCounter.estimate('abcd'), 1);
    });

    test('"abcde" (5 chars) -> 2 (ceiling of 5/4)', () {
      expect(TokenCounter.estimate('abcde'), 2);
    });

    test('100-char string -> 25', () {
      expect(TokenCounter.estimate('x' * 100), 25);
    });

    test('101-char string -> 26 (ceiling)', () {
      expect(TokenCounter.estimate('x' * 101), 26);
    });
  });
}
