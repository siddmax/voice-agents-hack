import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'agent/agent_service.dart';
import 'agent/mock_agent_service.dart';
import 'agent/real_agent_factory.dart';
import 'agent/todos.dart';
import 'cactus/model_downloader.dart';
import 'cactus/model_tier.dart';
import 'mcp/mcp_store.dart';
import 'ui/app_settings.dart';
import 'ui/chat_controller.dart';
import 'ui/chat_screen.dart';
import 'ui/model_download_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/task_ledger.dart';
import 'voice/stt.dart';
import 'voice/tts.dart';

// Tier-specific weights. Supply both at build time when you want the app to
// auto-pick based on device RAM (see [ModelTierDetector]):
//   --dart-define=SYNDAI_GEMMA4_E2B_PATH=/abs/path/to/e2b-weights
//   --dart-define=SYNDAI_GEMMA4_E4B_PATH=/abs/path/to/e4b-weights
// Legacy single-path alias is treated as an E4B weights path.
const _e2bPath = String.fromEnvironment('SYNDAI_GEMMA4_E2B_PATH');
const _e4bPath = String.fromEnvironment('SYNDAI_GEMMA4_E4B_PATH');
const _legacyPath = String.fromEnvironment('SYNDAI_GEMMA4_PATH');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final tier = await ModelTierDetector.detect();

  // Prefer dart-define overrides (desktop dev), else the on-device download
  // location. If neither is present we boot to [ModelDownloadScreen] and let
  // the user grab the weights.
  final overridePath = _legacyOverridePath(tier);
  Directory? docsDir;
  String? existingPath;
  try {
    docsDir = await getApplicationDocumentsDirectory();
    existingPath = await ModelDownloader.existingModelPath(
      tier: tier,
      destination: docsDir,
    );
  } catch (_) {
    // Tests / headless environments may not have path_provider wired up.
  }

  final resolvedPath = overridePath ?? existingPath;

  AgentService? built;
  String? startupError;

  if (resolvedPath != null) {
    final mcpStore = McpServerStore();
    await mcpStore.load();
    try {
      built = await RealAgentFactory.tryBuild(
        modelPath: resolvedPath,
        todos: TodoStore(),
        mcpConfigs: mcpStore.servers,
      );
      if (built == null) {
        startupError = 'Model load returned null — falling back to mock.';
      }
    } catch (e) {
      startupError = 'Model load threw: $e';
    }
  }

  runApp(SyndaiApp(
    agentFactory: () => built ?? MockAgentService(),
    startupError: startupError,
    initialModelPath: resolvedPath,
    tier: tier,
    documentsDir: docsDir,
  ));
}

/// Resolve a developer-supplied override for [tier] from `--dart-define`.
///
/// Mobile users go through [ModelDownloadScreen] — this path is for desktop
/// devs who want to point at a pre-existing weights directory.
///
/// Priority order:
///   1. The path matching [tier] (E4B → `SYNDAI_GEMMA4_E4B_PATH`, E2B → `SYNDAI_GEMMA4_E2B_PATH`).
///   2. Legacy `SYNDAI_GEMMA4_PATH` (historically E4B-only).
///   3. The other tier's path, as a last resort.
///   4. `null` if nothing is configured → caller falls through to the
///      on-device download check.
String? _legacyOverridePath(ModelTier tier) {
  String? nonEmpty(String s) => s.isEmpty ? null : s;

  final preferred =
      tier == ModelTier.e4b ? nonEmpty(_e4bPath) : nonEmpty(_e2bPath);
  if (preferred != null) return preferred;

  final legacy = nonEmpty(_legacyPath);
  if (legacy != null) return legacy;

  final other =
      tier == ModelTier.e4b ? nonEmpty(_e2bPath) : nonEmpty(_e4bPath);
  return other;
}

class SyndaiApp extends StatelessWidget {
  final AgentService Function() agentFactory;
  final String? startupError;

  /// Path to on-device weights (null → app boots to [ModelDownloadScreen]).
  final String? initialModelPath;
  final ModelTier tier;
  final Directory? documentsDir;

  const SyndaiApp({
    super.key,
    required this.agentFactory,
    this.startupError,
    this.initialModelPath,
    this.tier = ModelTier.e2b,
    this.documentsDir,
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
        home: initialModelPath == null && documentsDir != null
            ? ModelDownloadScreen(
                tier: tier,
                destination: documentsDir!,
                onReady: (_) {
                  // Integration hook: when Track J lands JarvisScreen, wire
                  // it here via a navigator push that rebuilds the agent.
                  // For now the screen itself shows a "Model ready" state.
                },
              )
            : _HomeShell(startupError: startupError),
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
