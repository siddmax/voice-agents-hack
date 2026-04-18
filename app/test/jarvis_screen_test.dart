import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/main.dart';
import 'package:syndai/ui/activity_feed.dart';
import 'package:syndai/ui/chat_controller.dart';
import 'package:syndai/ui/jarvis_orb.dart';
import 'package:syndai/ui/jarvis_screen.dart';

class _FakeAgent implements AgentService {
  @override
  Stream<AgentEvent> run(String userInput) async* {
    yield const AgentToolCall('memory_view', <String, dynamic>{});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    yield const AgentToolResult('memory_view', 'ok');
    yield const AgentToken('Done.');
    yield const AgentFinished('All good.');
  }

  @override
  Future<void> cancel() async {}
}

AgentService fakeAgent() => _FakeAgent();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('JarvisScreen mounts with orb and feed', (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();
    expect(find.byType(JarvisScreen), findsOneWidget);
    expect(find.byType(JarvisOrb), findsOneWidget);
    expect(find.byType(ActivityFeed), findsOneWidget);
  });

  testWidgets('sending renders tool-call chip and token from event stream',
      (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();

    final chat = Provider.of<ChatController>(
      tester.element(find.byType(JarvisScreen)),
      listen: false,
    );
    await chat.send('hello');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining('memory_view'), findsWidgets);
    expect(find.textContaining('Done.'), findsOneWidget);
  });

  testWidgets('settings gear opens modal sheet', (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Voice output'), findsOneWidget);
    expect(find.text('MCP servers'), findsOneWidget);
  });
}
