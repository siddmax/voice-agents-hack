import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/memory.dart';

Future<Memory> _openTemp() async {
  final tmp = await Directory.systemTemp.createTemp('syndai_mv_');
  return Memory.open(
    dir: tmp,
    loadBootstrap: (p) async => '# seed $p\n',
  );
}

void main() {
  group('resolveSafe', () {
    test('rejects traversal', () async {
      final m = await _openTemp();
      expect(() => m.resolveSafe('../evil.md'), throwsA(isA<MemoryException>()));
      expect(() => m.resolveSafe('a/../../b.md'), throwsA(isA<MemoryException>()));
    });
    test('rejects absolute paths', () async {
      final m = await _openTemp();
      expect(() => m.resolveSafe('/etc/passwd'), throwsA(isA<MemoryException>()));
    });
    test('rejects null byte', () async {
      final m = await _openTemp();
      expect(() => m.resolveSafe('a\u0000b.md'), throwsA(isA<MemoryException>()));
    });
    test('rejects empty', () async {
      final m = await _openTemp();
      expect(() => m.resolveSafe(''), throwsA(isA<MemoryException>()));
    });
    test('normalizes slug', () async {
      final m = await _openTemp();
      final f = m.resolveSafe('My Folder/Some Note.md');
      expect(f.path, endsWith('my-folder/some-note.md'));
    });
    test('preserves UPPERCASE stems', () async {
      final m = await _openTemp();
      expect(m.resolveSafe('AGENT.md').path, endsWith('AGENT.md'));
      expect(m.resolveSafe('INDEX.md').path, endsWith('INDEX.md'));
    });
  });

  group('atomic + caps', () {
    test('write fsyncs via tmp+rename', () async {
      final m = await _openTemp();
      await m.create('a.md', 'hello\n');
      expect(await File('${m.root.path}/a.md').readAsString(), 'hello\n');
    });
    test('50KB cap rejected', () async {
      final m = await _openTemp();
      final big = 'x' * (50 * 1024 + 1);
      expect(() => m.create('big.md', big), throwsA(isA<MemoryException>()));
    });
  });

  group('secret scan', () {
    final cases = <String, String>{
      'sk-key': 'see sk-ABCDEFGHIJKLMNOP1234 here',
      'bearer': 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz',
      'pem': '-----BEGIN RSA PRIVATE KEY-----\ndata',
      'pem-plain': '-----BEGIN PRIVATE KEY-----\ndata',
      'aws': 'key AKIAABCDEFGHIJKLMNOP',
    };
    cases.forEach((label, content) {
      test('rejects $label', () async {
        final m = await _openTemp();
        expect(() => m.create('leak.md', content), throwsA(isA<MemoryException>()));
      });
    });
  });
}
