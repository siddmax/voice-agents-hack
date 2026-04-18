@Tags(['cactus'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/cactus/engine.dart';

void main() {
  final modelPath = Platform.environment['SYNDAI_GEMMA4_PATH'];

  test('cactus smoke: says hello', () async {
    if (modelPath == null || modelPath.isEmpty) {
      markTestSkipped('Set SYNDAI_GEMMA4_PATH to the Gemma 4 E4B weights dir');
      return;
    }
    if (!Directory(modelPath).existsSync() && !File(modelPath).existsSync()) {
      fail('SYNDAI_GEMMA4_PATH does not exist: $modelPath');
    }

    final engine = await CactusEngine.load(modelPath);
    try {
      final out = await engine.completeText(
        messages: [
          {'role': 'user', 'content': "Say the word 'hello' and nothing else."}
        ],
        maxTokens: 32,
        temperature: 0.0,
      );
      stdout.writeln('[smoke] output: $out');
      expect(out.toLowerCase(), contains('hello'));
    } finally {
      engine.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
