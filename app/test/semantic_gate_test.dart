import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/semantic_gate.dart';

void main() {
  group('SemanticGate defaults', () {
    // tool name -> (happyQuery, rivalTool, wrongQuery)
    // happyQuery contains a keyword for toolName.
    // wrongQuery contains a keyword for rivalTool only.
    final cases = <String, Map<String, String>>{
      'send_message': {
        'happy': 'send a message to Alice',
        'rival': 'get_weather',
        'wrong': "what's the weather tomorrow",
      },
      'create_issue': {
        'happy': 'open a bug ticket for the crash',
        'rival': 'get_weather',
        'wrong': 'forecast for Tuesday',
      },
      'search_issues': {
        'happy': 'find issues tagged P0',
        'rival': 'set_alarm',
        'wrong': 'wake me up at 7',
      },
      'assign_issue': {
        'happy': 'assign this issue to Bob',
        'rival': 'play_music',
        'wrong': 'play some music',
      },
      'comment_on_issue': {
        'happy': 'reply on the ticket with status',
        'rival': 'set_timer',
        'wrong': 'start a 5 minute timer',
      },
      'get_weather': {
        'happy': 'is it going to rain today',
        'rival': 'send_message',
        'wrong': 'send a message to mom',
      },
      'set_alarm': {
        'happy': 'wake me at 6am',
        'rival': 'get_weather',
        'wrong': 'temperature in NYC',
      },
      'set_timer': {
        'happy': 'start a countdown for 10 minutes',
        'rival': 'set_alarm',
        'wrong': 'alarm for 7',
      },
      'set_reminder': {
        'happy': 'remind me to call grandma',
        'rival': 'play_music',
        'wrong': 'play my jazz playlist',
      },
      'play_track': {
        'happy': 'play the next song',
        'rival': 'set_alarm',
        'wrong': 'wake me at 6',
      },
      'play_music': {
        'happy': 'listen to some music',
        'rival': 'set_alarm',
        'wrong': 'alarm at 6',
      },
      'navigate': {
        'happy': 'directions to the airport',
        'rival': 'get_weather',
        'wrong': "what's the temperature",
      },
      'call': {
        'happy': 'call my mom',
        'rival': 'get_weather',
        'wrong': 'forecast for today',
      },
      'email': {
        'happy': 'send an email to accounting',
        'rival': 'get_weather',
        'wrong': 'sunny tomorrow',
      },
    };

    for (final entry in cases.entries) {
      final tool = entry.key;
      final happy = entry.value['happy']!;
      final rival = entry.value['rival']!;
      final wrong = entry.value['wrong']!;

      test('$tool passes for a matching query', () {
        final gate = SemanticGate();
        expect(
          gate.check(
            toolName: tool,
            query: happy,
            availableTools: [tool, rival],
          ),
          isTrue,
        );
        expect(gate.triggerCount, 0);
      });

      test('$tool fails when a rival tool fits better', () {
        final gate = SemanticGate();
        expect(
          gate.check(
            toolName: tool,
            query: wrong,
            availableTools: [tool, rival],
          ),
          isFalse,
        );
        expect(gate.triggerCount, 1);
      });
    }
  });

  test('unknown tool name gets benefit of the doubt', () {
    final gate = SemanticGate();
    expect(
      gate.check(
        toolName: 'some_mystery_tool',
        query: 'do anything',
        availableTools: ['some_mystery_tool', 'get_weather'],
      ),
      isTrue,
    );
    expect(gate.triggerCount, 0);
  });

  test('no available tool matches any keyword -> benefit of the doubt', () {
    final gate = SemanticGate();
    // "send_message" keywords don't match "xyzzy". No rival tool has a match.
    expect(
      gate.check(
        toolName: 'send_message',
        query: 'xyzzy',
        availableTools: ['send_message'],
      ),
      isTrue,
    );
    expect(gate.triggerCount, 0);
  });

  test('user-supplied signals merge with defaults', () {
    final gate = SemanticGate({
      'my_custom_tool': ['frobnicate', 'widget'],
    });
    // Custom tool keyword hits.
    expect(
      gate.check(
        toolName: 'my_custom_tool',
        query: 'please frobnicate the widget',
        availableTools: ['my_custom_tool'],
      ),
      isTrue,
    );
    // Defaults still present.
    expect(
      gate.check(
        toolName: 'get_weather',
        query: 'any rain today',
        availableTools: ['get_weather'],
      ),
      isTrue,
    );
  });
}
