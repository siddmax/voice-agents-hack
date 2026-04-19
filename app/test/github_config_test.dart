import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/github_config.dart';

void main() {
  group('GitHubConfig.fromValues', () {
    test('prefers dotenv values first', () {
      final config = GitHubConfig.fromValues(
        dotenvValues: {
          'VOICEBUG_GH_OWNER': 'dotenv-owner',
          'VOICEBUG_GH_REPO': 'dotenv-repo',
          'VOICEBUG_GH_TOKEN': 'dotenv-token',
        },
        environmentValues: {
          'VOICEBUG_GH_OWNER': 'env-owner',
          'VOICEBUG_GH_REPO': 'env-repo',
          'VOICEBUG_GH_TOKEN': 'env-token',
        },
        defineValues: {
          'VOICEBUG_GH_OWNER': 'define-owner',
          'VOICEBUG_GH_REPO': 'define-repo',
          'VOICEBUG_GH_TOKEN': 'define-token',
        },
      );

      expect(config, isNotNull);
      expect(config!.owner, 'dotenv-owner');
      expect(config.repo, 'dotenv-repo');
      expect(config.token, 'dotenv-token');
    });

    test('falls back to process environment when dotenv is empty', () {
      final config = GitHubConfig.fromValues(
        dotenvValues: const {},
        environmentValues: {
          'VOICEBUG_GH_OWNER': 'env-owner',
          'VOICEBUG_GH_REPO': 'env-repo',
          'VOICEBUG_GH_TOKEN': 'env-token',
        },
        defineValues: {
          'VOICEBUG_GH_OWNER': 'define-owner',
          'VOICEBUG_GH_REPO': 'define-repo',
          'VOICEBUG_GH_TOKEN': 'define-token',
        },
      );

      expect(config, isNotNull);
      expect(config!.owner, 'env-owner');
      expect(config.repo, 'env-repo');
      expect(config.token, 'env-token');
    });

    test('falls back to dart-define values when others are empty', () {
      final config = GitHubConfig.fromValues(
        dotenvValues: const {},
        environmentValues: const {},
        defineValues: {
          'VOICEBUG_GH_OWNER': 'define-owner',
          'VOICEBUG_GH_REPO': 'define-repo',
          'VOICEBUG_GH_TOKEN': 'define-token',
        },
      );

      expect(config, isNotNull);
      expect(config!.owner, 'define-owner');
      expect(config.repo, 'define-repo');
      expect(config.token, 'define-token');
    });

    test('returns null when any required value is missing', () {
      final config = GitHubConfig.fromValues(
        dotenvValues: {
          'VOICEBUG_GH_OWNER': 'owner',
          'VOICEBUG_GH_REPO': 'repo',
        },
        environmentValues: const {},
        defineValues: const {},
      );

      expect(config, isNull);
    });
  });
}
