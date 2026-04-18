import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/cactus/model_tier.dart';

void main() {
  group('pickTier', () {
    test('returns e2b when RAM is 6 GB', () {
      expect(pickTier(6.0), ModelTier.e2b);
    });

    test('returns e2b when RAM is 10 GB', () {
      expect(pickTier(10.0), ModelTier.e2b);
    });

    test('returns e4b when RAM is exactly 12 GB', () {
      expect(pickTier(12.0), ModelTier.e4b);
    });

    test('returns e4b when RAM is 16 GB', () {
      expect(pickTier(16.0), ModelTier.e4b);
    });

    test('falls back to e2b when RAM is unknown', () {
      expect(pickTier(null), ModelTier.e2b);
    });

    test('override "e4b" wins over low RAM', () {
      expect(pickTier(4.0, override: 'e4b'), ModelTier.e4b);
    });

    test('override "e2b" wins over high RAM', () {
      expect(pickTier(64.0, override: 'e2b'), ModelTier.e2b);
    });

    test('override is case-insensitive', () {
      expect(pickTier(4.0, override: 'E4B'), ModelTier.e4b);
      expect(pickTier(64.0, override: 'E2B'), ModelTier.e2b);
    });

    test('unknown override string is ignored', () {
      expect(pickTier(16.0, override: 'huge'), ModelTier.e4b);
      expect(pickTier(4.0, override: ''), ModelTier.e2b);
    });
  });
}
