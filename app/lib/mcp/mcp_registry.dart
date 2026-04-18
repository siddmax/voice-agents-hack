import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:mcp_client/mcp_client.dart' as mcp;

import '../agent/tool_registry.dart';
import 'mcp_config.dart';

class McpRegistry {
  final ToolRegistry toolRegistry;
  final Map<String, mcp.Client> _clients = {};

  McpRegistry(this.toolRegistry);

  /// Connect to every enabled server and register its tools. Failures on
  /// individual servers are logged and skipped — never blocks the caller.
  Future<void> connectAll(List<McpServerConfig> configs) async {
    await Future.wait(configs.where((c) => c.enabled).map(_connectOne));
  }

  Future<void> _connectOne(McpServerConfig cfg) async {
    // Run inside a guarded zone so async errors from the underlying transport
    // (which are published on broadcast streams) don't propagate out and
    // crash the agent startup.
    final completer = Completer<void>();
    runZonedGuarded(() async {
      try {
        final headers = <String, String>{
          ...cfg.extraHeaders,
          if (cfg.bearerToken != null)
            'Authorization': 'Bearer ${cfg.bearerToken}',
        };
        final result = await mcp.McpClient.createAndConnect(
          config: mcp.McpClient.simpleConfig(
            name: 'syndai',
            version: '0.1.0',
          ),
          transportConfig: mcp.TransportConfig.streamableHttp(
            baseUrl: cfg.url,
            headers: headers,
          ),
        );
        if (!result.isSuccess) {
          dev.log('MCP connect failed for ${cfg.name}', name: 'mcp_registry');
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final client = result.get();
        _clients[cfg.id] = client;
        final tools = await client.listTools();
        for (final t in tools) {
          toolRegistry.register(ToolSpec(
            name: _namespacedName(cfg, t.name),
            description: t.description,
            inputSchema: t.inputSchema,
            source: cfg.id,
            executor: (args) => _invoke(cfg.id, t.name, args),
          ));
        }
      } catch (e, st) {
        dev.log('MCP connect failed for ${cfg.name}: $e',
            name: 'mcp_registry', error: e, stackTrace: st);
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    }, (e, st) {
      dev.log('MCP zone error ${cfg.name}: $e', name: 'mcp_registry');
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  String _namespacedName(McpServerConfig cfg, String toolName) {
    // Keep it short & snake-ish. MCP tool names are globally unique within a
    // server; we prefix with server id to avoid collisions across servers.
    final safeId = cfg.id.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    return '${safeId}__$toolName';
  }

  Future<Map<String, dynamic>> _invoke(
      String serverId, String toolName, Map<String, dynamic> args) async {
    final client = _clients[serverId];
    if (client == null) {
      return {'error': 'not_connected', 'server': serverId};
    }
    final r = await client.callTool(toolName, args);
    return {
      'isError': r.isError ?? false,
      'content': r.content.map((c) => _contentToJson(c)).toList(),
    };
  }

  Map<String, dynamic> _contentToJson(mcp.Content c) {
    if (c is mcp.TextContent) return {'type': 'text', 'text': c.text};
    // Fallback — re-encode via toJson().
    return c.toJson();
  }

  Future<void> disconnectAll() async {
    for (final entry in _clients.entries) {
      try {
        entry.value.disconnect();
        toolRegistry.unregisterSource(entry.key);
      } catch (_) {}
    }
    _clients.clear();
  }

  // For tests/debug.
  String debugJson() => jsonEncode({
        'clients': _clients.keys.toList(),
        'tools': toolRegistry.all.map((t) => t.name).toList(),
      });
}
