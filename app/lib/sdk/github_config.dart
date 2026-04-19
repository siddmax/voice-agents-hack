import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

class GitHubConfig {
  final String owner;
  final String repo;
  final String token;

  const GitHubConfig({
    required this.owner,
    required this.repo,
    required this.token,
  });

  bool get isComplete =>
      owner.trim().isNotEmpty &&
      repo.trim().isNotEmpty &&
      token.trim().isNotEmpty;

  static GitHubConfig? fromEnvironment() {
    const ownerDefine = String.fromEnvironment('VOICEBUG_GH_OWNER');
    const repoDefine = String.fromEnvironment('VOICEBUG_GH_REPO');
    const tokenDefine = String.fromEnvironment('VOICEBUG_GH_TOKEN');

    String readDotenv(String key) {
      try {
        return dotenv.get(key, fallback: '').trim();
      } catch (_) {
        return '';
      }
    }

    return fromValues(
      dotenvValues: {
        'VOICEBUG_GH_OWNER': readDotenv('VOICEBUG_GH_OWNER'),
        'VOICEBUG_GH_REPO': readDotenv('VOICEBUG_GH_REPO'),
        'VOICEBUG_GH_TOKEN': readDotenv('VOICEBUG_GH_TOKEN'),
      },
      environmentValues: Platform.environment,
      defineValues: {
        'VOICEBUG_GH_OWNER': ownerDefine,
        'VOICEBUG_GH_REPO': repoDefine,
        'VOICEBUG_GH_TOKEN': tokenDefine,
      },
    );
  }

  static GitHubConfig? fromValues({
    required Map<String, String> dotenvValues,
    required Map<String, String> environmentValues,
    required Map<String, String> defineValues,
  }) {
    String resolve(String key) {
      final dotenvValue = (dotenvValues[key] ?? '').trim();
      if (dotenvValue.isNotEmpty) return dotenvValue;

      final envValue = (environmentValues[key] ?? '').trim();
      if (envValue.isNotEmpty) return envValue;

      final defineValue = (defineValues[key] ?? '').trim();
      if (defineValue.isNotEmpty) return defineValue;

      return '';
    }

    final config = GitHubConfig(
      owner: resolve('VOICEBUG_GH_OWNER'),
      repo: resolve('VOICEBUG_GH_REPO'),
      token: resolve('VOICEBUG_GH_TOKEN'),
    );

    return config.isComplete ? config : null;
  }
}
