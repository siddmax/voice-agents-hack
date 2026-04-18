import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/main.dart';

class _FakeAgent implements AgentService {
  @override
  Stream<AgentEvent> run(String userInput) async* {
    yield const AgentToken('Hi ');
    yield const AgentToken('there!');
    yield const AgentFinished('Greeted the user.');
  }

  @override
  Future<void> cancel() async {}
}

AgentService fakeAgent() => _FakeAgent();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sending a message produces an agent bubble', (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();

    final field = find.byType(TextField).first;
    expect(field, findsOneWidget);

    await tester.enterText(field, 'hello');
    await tester.pump();

    final sendBtn = find.byType(FilledButton).first;
    await tester.tap(sendBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('hello'), findsOneWidget);
    expect(find.textContaining('Hi'), findsWidgets);
  });
}
