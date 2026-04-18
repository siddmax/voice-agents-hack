import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'agent/agent_service.dart';
import 'agent/mock_agent_service.dart';
import 'agent/real_agent_factory.dart';
import 'agent/todos.dart';
import 'cactus/model_tier.dart';
import 'mcp/mcp_store.dart';
import 'ui/app_settings.dart';
import 'ui/chat_controller.dart';
import 'ui/jarvis_screen.dart';
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

  AgentService? built;
  String? startupError;

  final tier = await ModelTierDetector.detect();
  final resolvedPath = _resolveModelPath(tier);

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
  } else {
    startupError =
        'No Gemma 4 weights configured. Running mock agent. Detected tier: '
        '${tier.name}. Pass --dart-define=SYNDAI_GEMMA4_E2B_PATH=... and/or '
        '--dart-define=SYNDAI_GEMMA4_E4B_PATH=... when building.';
  }

  runApp(SyndaiApp(
    agentFactory: () => built ?? MockAgentService(),
    startupError: startupError,
  ));
}

String? _resolveModelPath(ModelTier tier) {
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
        home: JarvisScreen(startupError: startupError),
      ),
    );
  }
}
