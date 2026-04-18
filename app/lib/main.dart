import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'agent/agent_service.dart';
import 'agent/mock_agent_service.dart';
import 'agent/real_agent_factory.dart';
import 'agent/todos.dart';
import 'mcp/mcp_store.dart';
import 'ui/app_settings.dart';
import 'ui/chat_controller.dart';
import 'ui/chat_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/task_ledger.dart';
import 'voice/stt.dart';
import 'voice/tts.dart';

// Provide at build time: --dart-define=SYNDAI_GEMMA4_PATH=/abs/path/to/weights
const _modelPath = String.fromEnvironment('SYNDAI_GEMMA4_PATH');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AgentService? built;
  String? startupError;

  if (_modelPath.isNotEmpty) {
    final mcpStore = McpServerStore();
    await mcpStore.load();
    try {
      built = await RealAgentFactory.tryBuild(
        modelPath: _modelPath,
        todos: TodoStore(),
        mcpConfigs: mcpStore.servers,
      );
      if (built == null) {
        startupError = 'Model load returned null — falling back to mock.';
      }
    } catch (e) {
      startupError = 'Model load threw: $e';
    }
  } else {
    startupError =
        'SYNDAI_GEMMA4_PATH not set. Running mock agent. Pass it via --dart-define when building to run Gemma 4 E4B locally.';
  }

  runApp(SyndaiApp(
    agentFactory: () => built ?? MockAgentService(),
    startupError: startupError,
  ));
}

class SyndaiApp extends StatelessWidget {
  final AgentService Function() agentFactory;
  final String? startupError;
  const SyndaiApp({
    super.key,
    required this.agentFactory,
    this.startupError,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()..load()),
        ChangeNotifierProvider(create: (_) => McpServerStore()..load()),
        Provider(create: (_) => SpeechToTextService()),
        Provider(create: (_) => TextToSpeechService()),
        ChangeNotifierProvider(create: (_) => ChatController(agentFactory())),
      ],
      child: MaterialApp(
        title: 'Syndai',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D6A4F)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2D6A4F),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: _HomeShell(startupError: startupError),
      ),
    );
  }
}

class _HomeShell extends StatefulWidget {
  final String? startupError;
  const _HomeShell({this.startupError});

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _index = 0;

  static const _screens = <Widget>[
    ChatScreen(),
    TaskLedgerScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.startupError!),
          duration: const Duration(seconds: 6),
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat'),
          NavigationDestination(
              icon: Icon(Icons.checklist_outlined),
              selectedIcon: Icon(Icons.checklist),
              label: 'Tasks'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
