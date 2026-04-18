@Tags(['cactus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/cactus/engine.dart';

void main() {
  final modelPath = Platform.environment['SYNDAI_GEMMA4_PATH'];

  test('cactus eval: 20-turn tool-call loop', () async {
    if (modelPath == null || modelPath.isEmpty) {
      markTestSkipped('Set SYNDAI_GEMMA4_PATH to the Gemma 4 E4B weights dir');
      return;
    }

    const schema = {
      'type': 'object',
      'required': ['tool', 'args'],
      'properties': {
        'tool': {'type': 'string', 'enum': ['write_todos']},
        'args': {
          'type': 'object',
          'required': ['todos'],
          'properties': {
            'todos': {
              'type': 'array',
              'items': {
                'type': 'object',
                'required': ['id', 'content', 'status'],
              }
            }
          }
        }
      }
    };

    final system = {
      'role': 'system',
      'content':
          'You are a tool-calling agent. For every user turn, respond with ONLY a JSON object of form '
              '{"tool":"write_todos","args":{"todos":[{"id":"tN","content":"...","status":"pending"}]}}. '
              'No prose, no code fences. Pick a new id each turn.'
    };

    final engine = await CactusEngine.load(modelPath);
    final List<_Row> rows = [];
    final seenHashes = <String>[];

    try {
      final convo = <Map<String, dynamic>>[system];
      for (var i = 1; i <= 20; i++) {
        convo.add({
          'role': 'user',
          'content': 'Turn $i: add a todo about topic number $i.'
        });
        final sw = Stopwatch()..start();
        var firstTryOk = false;
        var retryOk = false;
        var errMsg = '';
        String raw = '';
        try {
          raw = await engine.completeText(
            messages: convo,
            maxTokens: 256,
            temperature: 0.0,
          );
          if (_parse(raw) != null) {
            firstTryOk = true;
          } else {
            final retryConvo = List<Map<String, dynamic>>.from(convo)
              ..add({'role': 'assistant', 'content': raw})
              ..add({
                'role': 'user',
                'content':
                    'That was not valid JSON. Reply with ONLY a JSON object matching: ${jsonEncode(schema)}'
              });
            final retryRaw = await engine.completeText(
              messages: retryConvo,
              maxTokens: 256,
              temperature: 0.0,
            );
            if (_parse(retryRaw) != null) {
              retryOk = true;
              raw = retryRaw;
            } else {
              errMsg = 'parse_fail';
            }
          }
        } catch (e) {
          errMsg = '$e';
        }
        sw.stop();

        final hash = _shortHash(raw);
        seenHashes.add(hash);
        final looping = seenHashes.length >= 3 &&
            seenHashes.sublist(seenHashes.length - 3).toSet().length == 1;

        convo.add({'role': 'assistant', 'content': raw});
        rows.add(_Row(i, firstTryOk, retryOk, looping, sw.elapsedMilliseconds, errMsg, hash));
        stdout.writeln(
            '[eval] turn=$i firstTry=$firstTryOk retry=$retryOk loop=$looping ms=${sw.elapsedMilliseconds} hash=$hash err=$errMsg');

        if (looping) {
          stdout.writeln('[eval] detected loop — stopping early at turn $i');
          break;
        }
      }
    } finally {
      engine.close();
    }

    stdout.writeln('');
    stdout.writeln('===== Syndai Gemma 4 E4B tool-call eval =====');
    stdout.writeln('turn | first | retry | loop | ms    | hash    | err');
    stdout.writeln('-----+-------+-------+------+-------+---------+-----');
    for (final r in rows) {
      stdout.writeln(
          '${r.turn.toString().padLeft(4)} | ${_b(r.firstTry)} | ${_b(r.retry)} | ${_b(r.loop)} | ${r.ms.toString().padLeft(5)} | ${r.hash.padRight(7)} | ${r.err}');
    }
    final firstOk = rows.where((r) => r.firstTry).length;
    final retryOk = rows.where((r) => !r.firstTry && r.retry).length;
    final fail = rows.where((r) => !r.firstTry && !r.retry).length;
    final looped = rows.any((r) => r.loop);
    stdout.writeln('');
    stdout.writeln(
        'total=${rows.length} first-try-ok=$firstOk retry-ok=$retryOk fail=$fail loop-detected=$looped');
    stdout.writeln('=============================================');
  }, timeout: const Timeout(Duration(minutes: 30)));
}

class _Row {
  final int turn;
  final bool firstTry;
  final bool retry;
  final bool loop;
  final int ms;
  final String err;
  final String hash;
  _Row(this.turn, this.firstTry, this.retry, this.loop, this.ms, this.err, this.hash);
}

String _b(bool v) => v ? ' yes ' : '  no ';

String _shortHash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h.toRadixString(16).padLeft(7, '0').substring(0, 7);
}

Map<String, dynamic>? _parse(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final cands = <String>[t];
  final f = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (f != null) cands.add(f.group(1)!.trim());
  final a = t.indexOf('{');
  final b = t.lastIndexOf('}');
  if (a != -1 && b > a) cands.add(t.substring(a, b + 1));
  for (final c in cands) {
    try {
      final v = jsonDecode(c);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
  }
  return null;
}
