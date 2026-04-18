import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/agent/tool_registry.dart';
import 'package:syndai/mcp/mcp_config.dart';
import 'package:syndai/mcp/mcp_registry.dart';

void main() {
  group('McpRegistry', () {
    test('unreachable server is swallowed, agent not blocked', () async {
      final reg = ToolRegistry();
      final mcp = McpRegistry(reg);
      final cfg = McpServerConfig(
        id: 'bogus',
        name: 'bogus',
        url: 'http://127.0.0.1:1/does-not-exist',
      );
      await mcp
          .connectAll([cfg])
          .timeout(const Duration(seconds: 10), onTimeout: () {});
      // No tools registered.
      expect(reg.all.any((t) => t.source == 'bogus'), isFalse);
    });

    test('disabled servers are skipped entirely', () async {
      final reg = ToolRegistry();
      final mcp = McpRegistry(reg);
      await mcp.connectAll([
        const McpServerConfig(
          id: 'off',
          name: 'off',
          url: 'http://127.0.0.1:1/nope',
          enabled: false,
        ),
      ]);
      expect(reg.all, isEmpty);
    });

    test('registered MCP tools can be invoked via ToolRegistry', () async {
      // We verify the ToolRegistry <-> executor wiring. Simulate what the
      // registry does when listTools() returns a tool.
      final reg = ToolRegistry();
      reg.register(ToolSpec(
        name: 'fake__echo',
        description: 'echo',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'msg': {'type': 'string'},
          },
        },
        source: 'fake',
        executor: (args) async => {'echoed': args['msg']},
      ));
      reg.register(ToolSpec(
        name: 'fake__other',
        description: 'other',
        inputSchema: const {},
        source: 'fake',
        executor: (_) async => {'ok': true},
      ));

      expect(reg.all.where((t) => t.source == 'fake').length, 2);
      final r = await reg.call('fake__echo', {'msg': 'hi'});
      expect(r['echoed'], 'hi');

      // unregisterSource mirrors what disconnectAll does.
      reg.unregisterSource('fake');
      expect(reg.all.where((t) => t.source == 'fake'), isEmpty);
    });
  });
}
