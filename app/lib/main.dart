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
import 'ui/jarvis_screen.dart';
import 'ui/model_download_screen.dart';
import 'voice/stt.dart';
import 'voice/tts.dart';

// Tier-specific weights — used by desktop dev who pre-downloaded a model.
// Mobile users skip these and go through ModelDownloadScreen on first launch.
const _e2bPath = String.fromEnvironment('SYNDAI_GEMMA4_E2B_PATH');
const _e4bPath = String.fromEnvironment('SYNDAI_GEMMA4_E4B_PATH');
const _legacyPath = String.fromEnvironment('SYNDAI_GEMMA4_PATH');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final tier = await ModelTierDetector.detect();

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

  if (resolvedPath != null && docsDir != null) {
    built = await _buildRealAgent(resolvedPath);
    if (built == null) {
      startupError = 'Model load failed — falling back to mock.';
    }
  }

  runApp(SyndaiApp(
    preBuiltAgent: built,
    startupError: startupError,
    initialModelPath: resolvedPath,
    tier: tier,
    documentsDir: docsDir,
  ));
}

Future<AgentService?> _buildRealAgent(String modelPath) async {
  try {
    final mcpStore = McpServerStore();
    await mcpStore.load();
    return await RealAgentFactory.tryBuild(
      modelPath: modelPath,
      todos: TodoStore(),
      mcpConfigs: mcpStore.servers,
    );
  } catch (_) {
    return null;
  }
}

/// Developer override resolved from --dart-define. Mobile users won't have these.
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

class SyndaiApp extends StatefulWidget {
  final AgentService? preBuiltAgent;
  // Test-only override. When provided, the resulting agent is used instead of
  // [preBuiltAgent] / MockAgentService and the model-download path is skipped.
  final AgentService Function()? agentFactory;
  final String? startupError;
  final String? initialModelPath;
  final ModelTier tier;
  final Directory? documentsDir;

  const SyndaiApp({
    super.key,
    this.preBuiltAgent,
    this.agentFactory,
    this.startupError,
    this.initialModelPath,
    this.tier = ModelTier.e2b,
    this.documentsDir,
  });

  @override
  State<SyndaiApp> createState() => _SyndaiAppState();
}

class _SyndaiAppState extends State<SyndaiApp> {
  String? _modelPath;
  AgentService? _agent;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _modelPath = widget.initialModelPath;
    _agent = widget.preBuiltAgent;
    _startupError = widget.startupError;
  }

  Future<void> _onModelReady(String modelPath) async {
    final agent = await _buildRealAgent(modelPath);
    if (!mounted) return;
    setState(() {
      _modelPath = modelPath;
      _agent = agent;
      _startupError = agent == null ? 'Model load failed — using mock.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Test override short-circuits the download flow entirely.
    final testFactory = widget.agentFactory;
    final hasModel = testFactory != null || _modelPath != null;
    AgentService agentFactory() =>
        testFactory != null ? testFactory() : (_agent ?? MockAgentService());

    return MultiProvider(
      // Force the provider tree to rebuild (and ChatController to recreate)
      // when the model path changes after a successful download.
      key: ValueKey('app-${_modelPath ?? "none"}'),
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
        home: hasModel
            ? JarvisScreen(startupError: _startupError)
            : (widget.documentsDir != null
                ? ModelDownloadScreen(
                    tier: widget.tier,
                    destination: widget.documentsDir!,
                    onReady: _onModelReady,
                  )
                : JarvisScreen(
                    startupError: _startupError ??
                        'No model and no writable documents directory.',
                  )),
      ),
    );
  }
}
