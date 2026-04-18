import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/output_processor.dart';

void main() {
  group('levenshtein', () {
    test('identical', () => expect(levenshtein('abc', 'abc'), 0));
    test('empty-left', () => expect(levenshtein('', 'abc'), 3));
    test('empty-right', () => expect(levenshtein('abc', ''), 3));
    test('one-char-substitution', () => expect(levenshtein('a', 'b'), 1));
    test('classic kitten/sitting', () {
      expect(levenshtein('kitten', 'sitting'), 3);
    });
    test('insertion', () => expect(levenshtein('cat', 'cats'), 1));
  });

  group('extractJsonObject', () {
    test('plain', () {
      expect(extractJsonObject('{"a":1}'), {'a': 1});
    });
    test('fenced json', () {
      expect(
        extractJsonObject('```json\n{"a":1}\n```'),
        {'a': 1},
      );
    });
    test('fenced without json tag', () {
      expect(extractJsonObject('```\n{"a":2}\n```'), {'a': 2});
    });
    test('trailing prose', () {
      expect(
        extractJsonObject('Sure! {"name":"x","arguments":{}} hope that helps'),
        {'name': 'x', 'arguments': <String, dynamic>{}},
      );
    });
    test('nested braces', () {
      final m = extractJsonObject('prefix {"a":{"b":{"c":1}}} suffix');
      expect(m, isNotNull);
      expect(m!['a'], {
        'b': {'c': 1},
      });
    });
    test('strings with braces inside', () {
      final m = extractJsonObject('{"msg":"hello {world}"}');
      expect(m!['msg'], 'hello {world}');
    });
    test('escaped quote inside string', () {
      final m = extractJsonObject(r'{"msg":"he said \"hi\""}');
      expect(m!['msg'], 'he said "hi"');
    });
    test('malformed returns null', () {
      expect(extractJsonObject('not json at all'), isNull);
    });
    test('empty returns null', () {
      expect(extractJsonObject(''), isNull);
    });
    test('unterminated returns null', () {
      expect(extractJsonObject('{"a":1'), isNull);
    });
  });

  group('fuzzyMatchNames', () {
    final tools = [
      {'name': 'send_message'},
      {'name': 'create_issue'},
    ];
    test('exact match unchanged', () {
      final r = fuzzyMatchNames([
        {'name': 'send_message', 'arguments': {}},
      ], tools);
      expect(r.first['name'], 'send_message');
    });
    test('2-edit snap', () {
      final r = fuzzyMatchNames([
        {'name': 'send_mesage', 'arguments': {}},
      ], tools);
      expect(r.first['name'], 'send_message');
    });
    test('5-edit rejected', () {
      final r = fuzzyMatchNames([
        {'name': 'zzzzzzzzzzz', 'arguments': {}},
      ], tools);
      expect(r.first['name'], 'zzzzzzzzzzz');
    });
    test('empty tool list noop', () {
      final r = fuzzyMatchNames([
        {'name': 'whatever', 'arguments': {}},
      ], []);
      expect(r.first['name'], 'whatever');
    });
  });

  group('coerceTypes', () {
    final tools = [
      {
        'name': 'set_timer',
        'inputSchema': {
          'properties': {
            'minutes': {'type': 'integer', 'minimum': 0},
            'label': {'type': 'string'},
          },
        },
      },
      {
        'name': 'set_mood',
        'inputSchema': {
          'properties': {
            'mood': {
              'type': 'string',
              'enum': ['happy', 'sad', 'neutral'],
            },
          },
        },
      },
    ];
    test('float to int', () {
      final r = coerceTypes([
        {'name': 'set_timer', 'arguments': {'minutes': 5.0}},
      ], tools);
      expect(r.first['arguments']['minutes'], 5);
      expect(r.first['arguments']['minutes'], isA<int>());
    });
    test('negative clamped to abs', () {
      final r = coerceTypes([
        {'name': 'set_timer', 'arguments': {'minutes': -7}},
      ], tools);
      expect(r.first['arguments']['minutes'], 7);
    });
    test('string int parsed', () {
      final r = coerceTypes([
        {'name': 'set_timer', 'arguments': {'minutes': '12'}},
      ], tools);
      expect(r.first['arguments']['minutes'], 12);
    });
    test('enum snap', () {
      final r = coerceTypes([
        {'name': 'set_mood', 'arguments': {'mood': 'hapy'}},
      ], tools);
      expect(r.first['arguments']['mood'], 'happy');
    });
    test('enum too far left alone', () {
      final r = coerceTypes([
        {'name': 'set_mood', 'arguments': {'mood': 'ecstatic'}},
      ], tools);
      expect(r.first['arguments']['mood'], 'ecstatic');
    });
    test('no-op for strings without enum', () {
      final r = coerceTypes([
        {'name': 'set_timer', 'arguments': {'label': 'wake up'}},
      ], tools);
      expect(r.first['arguments']['label'], 'wake up');
    });
  });

  group('cleanStringArgs', () {
    test('trim + trailing punct', () {
      final r = cleanStringArgs([
        {'name': 'x', 'arguments': {'q': '  hello world.  '}},
      ]);
      expect(r.first['arguments']['q'], 'hello world');
    });
    test('leading article', () {
      final r = cleanStringArgs([
        {'name': 'x', 'arguments': {'q': 'The Beatles'}},
      ]);
      expect(r.first['arguments']['q'], 'Beatles');
    });
    test('surrounding quotes', () {
      final r = cleanStringArgs([
        {'name': 'x', 'arguments': {'q': '"hello"'}},
      ]);
      expect(r.first['arguments']['q'], 'hello');
    });
    test('leaves non-strings alone', () {
      final r = cleanStringArgs([
        {'name': 'x', 'arguments': {'n': 5}},
      ]);
      expect(r.first['arguments']['n'], 5);
    });
  });

  group('extractArgsFromQuery', () {
    final tools = [
      {
        'name': 'set_alarm',
        'inputSchema': {
          'properties': {
            'hour': {'type': 'integer'},
            'minute': {'type': 'integer'},
          },
        },
      },
      {
        'name': 'set_timer',
        'inputSchema': {
          'properties': {
            'minutes': {'type': 'integer'},
            'hours': {'type': 'integer'},
            'seconds': {'type': 'integer'},
          },
        },
      },
    ];
    test('7:30 pm populates hour/minute', () {
      final r = extractArgsFromQuery([
        {'name': 'set_alarm', 'arguments': <String, dynamic>{}},
      ], 'wake me at 7:30 pm', tools);
      expect(r.first['arguments']['hour'], 19);
      expect(r.first['arguments']['minute'], 30);
    });
    test('am 12 -> 0', () {
      final r = extractArgsFromQuery([
        {'name': 'set_alarm', 'arguments': <String, dynamic>{}},
      ], 'midnight is 12 am', tools);
      expect(r.first['arguments']['hour'], 0);
    });
    test('5 minutes', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': <String, dynamic>{}},
      ], 'set a timer for 5 minutes', tools);
      expect(r.first['arguments']['minutes'], 5);
    });
    test('2 hours', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': <String, dynamic>{}},
      ], '2 hour timer', tools);
      expect(r.first['arguments']['hours'], 2);
    });
    test('30 seconds', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': <String, dynamic>{}},
      ], 'in 30 seconds', tools);
      expect(r.first['arguments']['seconds'], 30);
    });
    test('does not stomp valid int', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': {'minutes': 3}},
      ], 'set a timer for 5 minutes', tools);
      expect(r.first['arguments']['minutes'], 3);
    });
    test('replaces bad string value', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': {'minutes': 'five'}},
      ], 'set a timer for 5 minutes', tools);
      expect(r.first['arguments']['minutes'], 5);
    });
    test('no regex match -> noop', () {
      final r = extractArgsFromQuery([
        {'name': 'set_timer', 'arguments': <String, dynamic>{}},
      ], 'hello there', tools);
      expect(r.first['arguments'], isEmpty);
    });
  });

  group('looksLikeRefusal', () {
    test('i cannot', () => expect(looksLikeRefusal('I cannot do that'), isTrue));
    test("i'm sorry", () => expect(looksLikeRefusal("I'm sorry, but no"), isTrue));
    test('i am sorry', () => expect(looksLikeRefusal('I am sorry to say'), isTrue));
    test('i apologize', () => expect(looksLikeRefusal('I apologize'), isTrue));
    test('which song', () =>
        expect(looksLikeRefusal('Which song would you like?'), isTrue));
    test('could you please', () =>
        expect(looksLikeRefusal('Could you please clarify'), isTrue));
    test('let me know which', () =>
        expect(looksLikeRefusal('Let me know which one'), isTrue));
    test('empty', () => expect(looksLikeRefusal(''), isFalse));
    test('normal tool call JSON', () =>
        expect(looksLikeRefusal('{"name":"x","arguments":{}}'), isFalse));
  });

  group('OutputProcessor.process', () {
    final tools = [
      {
        'name': 'set_timer',
        'inputSchema': {
          'properties': {
            'minutes': {'type': 'integer', 'minimum': 0},
            'label': {'type': 'string'},
          },
        },
      },
    ];
    test('single call pipeline', () {
      final out = OutputProcessor.process(
        call: {
          'name': 'set_timer',
          'arguments': {'minutes': -5.0, 'label': '  "wake up."  '},
        },
        tools: tools,
        query: 'set a timer for 10 minutes',
      );
      expect(out['name'], 'set_timer');
      // -5.0 becomes int 5 (abs), NOT 10 — valid output not stomped.
      expect(out['arguments']['minutes'], 5);
      expect(out['arguments']['label'], 'wake up');
    });
    test('fuzzy name snap + query extraction fills missing', () {
      final out = OutputProcessor.process(
        call: {
          'name': 'set_tmer',
          'arguments': <String, dynamic>{},
        },
        tools: tools,
        query: 'for 15 minutes',
      );
      expect(out['name'], 'set_timer');
      expect(out['arguments']['minutes'], 15);
    });
  });
}
