import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:syndai/agent/agent_service.dart';
import 'package:syndai/agent/mock_agent_service.dart';
import 'package:syndai/main.dart';
import 'package:syndai/sdk/github_issue_service.dart';
import 'package:syndai/ui/activity_feed.dart';
import 'package:syndai/ui/app_settings.dart';
import 'package:syndai/ui/chat_controller.dart';
import 'package:syndai/ui/jarvis_screen.dart';
import 'package:syndai/voice/audio_recorder.dart';
import 'package:syndai/voice/tts.dart';

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

  @override
  Future<String?> transcribe(Uint8List pcm) async => null;
}

AgentService fakeAgent() => _FakeAgent();

class _FakeRecorder implements PcmCapture {
  _FakeRecorder();

  bool _recording = false;
  Uint8List? nextPcm = Uint8List.fromList([1, 2, 3, 4]);

  @override
  bool get isRecording => _recording;

  @override
  Stream<double> get amplitude => const Stream<double>.empty();

  @override
  Future<bool> startRecording() async {
    _recording = true;
    return true;
  }

  @override
  Future<String?> stopRecording() async {
    _recording = false;
    return '/tmp/fake.wav';
  }

  @override
  Future<Uint8List?> stopAndGetPcm() async {
    _recording = false;
    return nextPcm;
  }

  @override
  Future<void> cancel() async {
    _recording = false;
  }

  @override
  void dispose() {
    _recording = false;
  }
}

class _FakeGitHubIssueService extends GitHubIssueService {
  _FakeGitHubIssueService({this.ready = true});

  final bool ready;
  GitHubIssueRequest? lastRequest;

  @override
  bool get isReady => ready;

  @override
  String get readinessMessage =>
      'GitHub issue submission is not configured. Set VOICEBUG_GH_OWNER, VOICEBUG_GH_REPO, and VOICEBUG_GH_TOKEN.';

  @override
  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    lastRequest = request;
    return const GitHubIssueSubmission(
      url: 'https://github.com/acme/repo/issues/42',
      issueNumber: '#42',
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.resetPhysicalSize();
    binding.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  testWidgets('JarvisScreen mounts with seat list and activation bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();
    expect(find.byType(JarvisScreen), findsOneWidget);
    expect(find.text('Golden State Warriors vs. LA Lakers'), findsOneWidget);
    expect(find.text('Section 105, Row 10'), findsWidgets);
    expect(find.text('Switch to Map'), findsOneWidget);
    expect(find.text('2 Tickets'), findsOneWidget);
  });

  testWidgets('sending renders tool-call chip and token from event stream', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
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
    expect(find.textContaining('Done.'), findsWidgets);
    expect(find.byType(ActivityFeed), findsOneWidget);
  });

  testWidgets('settings gear opens modal sheet', (tester) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(SyndaiApp(agentFactory: fakeAgent));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.favorite_border));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Voice output'), findsOneWidget);
    expect(find.text('MCP servers'), findsOneWidget);
  });

  testWidgets('listening sheet exposes finish and cancel controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    final recorder = _FakeRecorder();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings()..load()),
          Provider(create: (_) => TextToSpeechService()),
          ChangeNotifierProvider(create: (_) => ChatController(fakeAgent())),
        ],
        child: MaterialApp(home: JarvisScreen(recorder: recorder)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.graphic_eq_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining("I'm listening. Tell me what happened"),
      findsWidgets,
    );

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Finish Capture'), findsOneWidget);
  });

  testWidgets('starting listening does not auto-greet or auto-run the agent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    final recorder = _FakeRecorder();
    final chat = ChatController(fakeAgent());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings()..load()),
          Provider(create: (_) => TextToSpeechService()),
          ChangeNotifierProvider<ChatController>.value(value: chat),
        ],
        child: MaterialApp(home: JarvisScreen(recorder: recorder)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.graphic_eq_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));

    expect(chat.events, isEmpty);
    expect(chat.running, isFalse);
  });

  testWidgets('mock agent shows model-not-loaded warning on mic tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings()..load()),
          Provider(create: (_) => TextToSpeechService()),
          ChangeNotifierProvider(
            create: (_) => ChatController(MockAgentService()),
          ),
        ],
        child: MaterialApp(home: JarvisScreen(recorder: _FakeRecorder())),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.graphic_eq_rounded).first);
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('Voice capture needs the on-device model'),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows GitHub readiness banner when submission is not configured',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 2200);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSettings()..load()),
            Provider(create: (_) => TextToSpeechService()),
            ChangeNotifierProvider(create: (_) => ChatController(fakeAgent())),
          ],
          child: MaterialApp(
            home: JarvisScreen(
              githubIssueService: _FakeGitHubIssueService(ready: false),
              recorder: _FakeRecorder(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('GitHub issue submission is not configured'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'seat list does not show the gray location circle after back navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 2200);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        SyndaiApp(agentFactory: fakeAgent, startupError: null),
      );
      await tester.pump();

      expect(find.byIcon(Icons.location_on_outlined), findsNothing);

      await tester.tap(find.text('Section 105, Row 10').first);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back).first);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Section 105, Row 10'), findsWidgets);
      expect(find.byIcon(Icons.location_on_outlined), findsNothing);
    },
  );
}
