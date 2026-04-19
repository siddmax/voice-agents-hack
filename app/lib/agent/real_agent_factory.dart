import '../cactus/engine.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_registry.dart';
import 'agent_loop.dart';
import 'agent_service.dart';
import 'compaction.dart';
import 'memory.dart';
import 'prompt_assembler.dart';
import 'todos.dart';
import 'tool_registry.dart';

/// Loads Gemma 4 E4B, connects every enabled MCP server, wires the
/// AgentLoop. Returns null if the model fails to load — caller should fall
/// back to mock and surface the error.
class RealAgentFactory {
  static Future<AgentService?> tryBuild({
    required String modelPath,
    required TodoStore todos,
    required List<McpServerConfig> mcpConfigs,
  }) async {
    try {
      final engine = await CactusEngine.load(modelPath);
      final memory = await Memory.open();
      await memory.refreshInjectedCache();
      final toolResults = ToolResultStore();
      final toolRegistry = ToolRegistry();
      final assembler = PromptAssembler(
        todos: todos,
        readMemory: memory.readAll,
        toolResults: toolResults,
        toolRegistry: toolRegistry,
      );
      final mcp = McpRegistry(toolRegistry);
      await mcp.connectAll(mcpConfigs);
      return AgentLoop(
        engine: engine,
        todos: todos,
        memory: memory,
        tools: toolRegistry,
        assembler: assembler,
        compactor: MessageListCompactor(engine: engine),
      );
    } catch (_) {
      return null;
    }
  }
}
