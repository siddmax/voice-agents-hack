import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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
  await dotenv.load(fileName: '.env');

  final tier = await ModelTierDetector.detect();

  final overridePath = _legacyOverridePath(tier);
  Directory? docsDir;
  String? existingPath;
  try {
    docsDir = await getApplicationSupportDirectory();
    existingPath = await ModelDownloader.existingModelPath(
      tier: tier,
      destination: docsDir,
    );
    // Migrate from old Documents location if model exists there.
    if (existingPath == null) {
      final oldDir = await getApplicationDocumentsDirectory();
      final oldPath = await ModelDownloader.existingModelPath(
        tier: tier,
        destination: oldDir,
      );
      if (oldPath != null) {
        final dirName = ModelDownloader.dirNameForTier(tier);
        await docsDir.create(recursive: true);
        await Directory(oldPath).rename('${docsDir.path}/$dirName');
        existingPath = '${docsDir.path}/$dirName';
      }
    }
  } catch (_) {
    // Tests / headless environments may not have path_provider wired up.
  }

  final resolvedPath = overridePath ?? existingPath;

  // The agent build (which calls cactusInit and memory-maps several GB
  // of weights) used to await here, blocking runApp and showing a frozen
  // white screen for the duration. We hand it off to the SyndaiApp state
  // so the UI renders immediately with a "Warming up Syndai" indicator
  // while the model loads in a background isolate.
  runApp(SyndaiApp(
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
  bool _loadingAgent = false;

  @override
  void initState() {
    super.initState();
    _modelPath = widget.initialModelPath;
    _agent = widget.preBuiltAgent;
    _startupError = widget.startupError;
    if (_modelPath != null && _agent == null && widget.agentFactory == null) {
      _loadAgent(_modelPath!);
    }
  }

  Future<void> _loadAgent(String modelPath) async {
    if (_loadingAgent) return;
    setState(() => _loadingAgent = true);
    final agent = await _buildRealAgent(modelPath);
    if (!mounted) return;
    setState(() {
      _agent = agent;
      _loadingAgent = false;
      if (agent == null) _startupError = 'Model load failed — using mock.';
    });
  }

  Future<void> _onModelReady(String modelPath) async {
    setState(() => _modelPath = modelPath);
    await _loadAgent(modelPath);
  }

  @override
  Widget build(BuildContext context) {
    // Test override short-circuits the download flow entirely.
    final testFactory = widget.agentFactory;
    final hasModel = testFactory != null || _modelPath != null;
    final agentReady = testFactory != null || _agent != null;
    AgentService agentFactory() =>
        testFactory != null ? testFactory() : (_agent ?? MockAgentService());

    return MultiProvider(
      // Force the provider tree to rebuild (and ChatController to recreate)
      // when the model path or agent readiness changes — so the JarvisScreen
      // gets a fresh ChatController bound to the real agent the moment
      // cactusInit returns.
      key: ValueKey('app-${_modelPath ?? "none"}-${agentReady ? "real" : "warming"}'),
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
            ? JarvisScreen(
                startupError: _startupError ??
                    (_loadingAgent
                        ? 'Warming up Syndai — loading the model. First time can take ~30 s.'
                        : null),
              )
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
