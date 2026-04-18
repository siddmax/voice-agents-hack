import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/memory.dart';
import 'package:syndai/agent/memory_tools.dart';
import 'package:syndai/agent/tool_registry.dart';

Future<({Memory mem, ToolRegistry reg})> _setup() async {
  final tmp = await Directory.systemTemp.createTemp('syndai_mt_');
  final mem = await Memory.open(
    dir: tmp,
    loadBootstrap: (p) async => '# seed $p\n',
  );
  final reg = ToolRegistry();
  registerMemoryTools(reg, mem);
  return (mem: mem, reg: reg);
}

void main() {
  test('memory_view happy + errors', () async {
    final s = await _setup();
    await s.mem.create('notes.md', 'line1\nline2\nline3\n');
    final r = await s.reg.call('memory_view', {'path': 'notes.md'});
    expect(r['content'], 'line1\nline2\nline3\n');

    final r2 = await s.reg.call('memory_view', {'path': 'notes.md', 'view_range': [1, 2]});
    expect(r2['content'], 'line1\nline2');

    final r3 = await s.reg.call('memory_view', {'path': 'missing.md'});
    expect(r3['error'], contains('not found'));
  });

  test('memory_create fails if exists', () async {
    final s = await _setup();
    await s.reg.call('memory_create', {'path': 'a.md', 'content': 'hi'});
    final r = await s.reg.call('memory_create', {'path': 'a.md', 'content': 'hi'});
    expect(r['error'], contains('exists'));
  });

  test('memory_append creates missing', () async {
    final s = await _setup();
    final r = await s.reg.call('memory_append', {'path': 'log.md', 'content': 'entry'});
    expect(r['ok'], true);
    final v = await s.reg.call('memory_view', {'path': 'log.md'});
    expect(v['content'], 'entry\n');
    await s.reg.call('memory_append', {'path': 'log.md', 'content': 'two'});
    final v2 = await s.reg.call('memory_view', {'path': 'log.md'});
    expect(v2['content'], 'entry\ntwo\n');
  });

  test('memory_str_replace unique-match requirement', () async {
    final s = await _setup();
    await s.mem.create('f.md', 'foo bar foo\n');
    final dup = await s.reg.call('memory_str_replace', {
      'path': 'f.md', 'old_str': 'foo', 'new_str': 'zzz',
    });
    expect(dup['error'], contains('unique'));

    final ok = await s.reg.call('memory_str_replace', {
      'path': 'f.md', 'old_str': 'bar', 'new_str': 'BAR',
    });
    expect(ok['ok'], true);
    final v = await s.reg.call('memory_view', {'path': 'f.md'});
    expect(v['content'], 'foo BAR foo\n');

    final miss = await s.reg.call('memory_str_replace', {
      'path': 'f.md', 'old_str': 'nope', 'new_str': 'x',
    });
    expect(miss['error'], contains('not found'));
  });

  test('memory_delete refuses AGENT.md', () async {
    final s = await _setup();
    await File('${s.mem.root.path}/AGENT.md').writeAsString('# agent\n');
    final r = await s.reg.call('memory_delete', {'path': 'AGENT.md'});
    expect(r['error'], contains('read-only'));
  });

  test('memory_delete refuses directories', () async {
    final s = await _setup();
    await Directory('${s.mem.root.path}/sub').create();
    final r = await s.reg.call('memory_delete', {'path': 'sub'});
    expect(r['error'], contains('directory'));
  });

  test('memory_search returns hits', () async {
    final s = await _setup();
    await s.mem.create('a.md', 'hello world\ngoodbye\n');
    await s.mem.create('b.md', 'HELLO again\n');
    final r = await s.reg.call('memory_search', {'query': 'hello'});
    final results = (r['results'] as List).cast<Map>();
    expect(results.length, greaterThanOrEqualTo(2));
    expect(results.every((m) => m.containsKey('path') && m.containsKey('line') && m.containsKey('preview')), true);
  });

  test('INDEX.md rewritten on create/delete', () async {
    final s = await _setup();
    await s.mem.create('topic.md', 'First real line\n');
    final idx = await File('${s.mem.root.path}/INDEX.md').readAsString();
    expect(idx.contains('topic.md'), true);
    expect(idx.contains('First real line'), true);

    await s.mem.delete('topic.md');
    final idx2 = await File('${s.mem.root.path}/INDEX.md').readAsString();
    expect(idx2.contains('topic.md'), false);
  });

  test('migration: legacy memory.md -> Notes.md', () async {
    final tmp = await Directory.systemTemp.createTemp('syndai_mig_');
    await File('${tmp.path}/memory.md').writeAsString('legacy content\n');
    final mem = await Memory.open(
      dir: tmp,
      loadBootstrap: (p) async => '# seed\n',
    );
    expect(await File('${mem.root.path}/Notes.md').readAsString(), 'legacy content\n');
    expect(await File('${tmp.path}/memory.md').exists(), false);

    // Idempotent: reopen, no crash, no duplicate.
    await Memory.open(dir: tmp, loadBootstrap: (p) async => '# seed\n');
  });

  test('bootstrap populates files on first run', () async {
    final tmp = await Directory.systemTemp.createTemp('syndai_bs_');
    final mem = await Memory.open(
      dir: tmp,
      loadBootstrap: (p) async => '# bootstrap $p\n',
    );
    expect(await File('${mem.root.path}/AGENT.md').exists(), true);
    expect(await File('${mem.root.path}/identity/user.md').exists(), true);
    expect(await File('${mem.root.path}/preferences/general.md').exists(), true);
  });
}
