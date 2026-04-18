import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../mcp/mcp_config.dart';
import '../mcp/mcp_store.dart';
import 'app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final store = context.watch<McpServerStore>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Voice output'),
            subtitle: const Text(
                'Speak the final response aloud when the agent finishes.'),
            value: settings.voiceOutput,
            onChanged: (v) => settings.setVoiceOutput(v),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              children: [
                Text('MCP servers',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  onPressed: () => _openEditor(context),
                ),
              ],
            ),
          ),
          if (store.servers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No MCP servers configured.'),
            ),
          ...store.servers.map((s) => _ServerTile(server: s)),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final McpServerConfig server;
  const _ServerTile({required this.server});

  @override
  Widget build(BuildContext context) {
    final store = context.read<McpServerStore>();
    final tokenStatus = (server.bearerToken ?? '').isEmpty
        ? 'No token set'
        : 'Token set';
    return Dismissible(
      key: ValueKey(server.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(Icons.delete,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('Delete ${server.name}?'),
                content: const Text('This removes the MCP server config.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete')),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => store.delete(server.id),
      child: ListTile(
        leading: Icon(
          server.enabled ? Icons.cloud_done : Icons.cloud_off,
          color: server.enabled
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
        title: Text(server.name),
        subtitle: Text('${server.url}\n$tokenStatus',
            style: Theme.of(context).textTheme.bodySmall),
        isThreeLine: true,
        trailing: Switch(
          value: server.enabled,
          onChanged: (v) => store.update(McpServerConfig(
            id: server.id,
            name: server.name,
            url: server.url,
            bearerToken: server.bearerToken,
            extraHeaders: server.extraHeaders,
            enabled: v,
          )),
        ),
        onTap: () => _openEditor(context, existing: server),
      ),
    );
  }
}

void _openEditor(BuildContext context, {McpServerConfig? existing}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _ServerEditor(existing: existing),
    ),
  );
}

class _ServerEditor extends StatefulWidget {
  final McpServerConfig? existing;
  const _ServerEditor({this.existing});

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _token = TextEditingController(text: e?.bearerToken ?? '');
    _enabled = e?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and URL are required.')),
      );
      return;
    }
    final store = context.read<McpServerStore>();
    final existing = widget.existing;
    final cfg = McpServerConfig(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      url: url,
      bearerToken: _token.text.isEmpty ? null : _token.text,
      extraHeaders: existing?.extraHeaders ?? const {},
      enabled: _enabled,
    );
    if (existing == null) {
      await store.add(cfg);
    } else {
      await store.update(cfg);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isNew ? 'Add MCP server' : 'Edit MCP server',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Linear',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'URL',
              hintText: 'https://mcp.linear.app/sse',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            decoration: const InputDecoration(
              labelText: 'Bearer token',
              hintText: 'Optional',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: Text(isNew ? 'Add' : 'Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
