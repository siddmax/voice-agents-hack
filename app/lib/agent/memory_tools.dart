import 'memory.dart';
import 'tool_registry.dart';

/// Registers the 6 Anthropic-style memory tools against [registry].
/// Keep every description under 25 words — schema bloat hurts Gemma 4 E4B.
void registerMemoryTools(ToolRegistry registry, Memory memory) {
  registry.register(ToolSpec(
    name: 'memory_view',
    description: 'Read a memory file. Optional view_range=[start,end] returns only those 1-indexed lines.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'view_range': {
          'type': 'array',
          'items': {'type': 'integer'},
          'minItems': 2,
          'maxItems': 2,
        },
      },
      'required': ['path'],
    },
    executor: (args) async {
      final path = args['path'] as String;
      final range = (args['view_range'] as List?)?.cast<int>();
      try {
        final content = await memory.view(path, viewRange: range);
        return {'ok': true, 'content': content};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));

  registry.register(ToolSpec(
    name: 'memory_create',
    description: 'Create a new memory file. Fails if the file already exists.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
    executor: (args) async {
      try {
        await memory.create(args['path'] as String, args['content'] as String);
        await memory.refreshInjectedCache();
        return {'ok': true};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));

  registry.register(ToolSpec(
    name: 'memory_append',
    description: 'Append content to a memory file, creating it if missing.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
    executor: (args) async {
      try {
        await memory.append(args['path'] as String, args['content'] as String);
        await memory.refreshInjectedCache();
        return {'ok': true};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));

  registry.register(ToolSpec(
    name: 'memory_str_replace',
    description: 'Replace a single unique occurrence of old_str with new_str in a memory file.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'old_str': {'type': 'string'},
        'new_str': {'type': 'string'},
      },
      'required': ['path', 'old_str', 'new_str'],
    },
    executor: (args) async {
      try {
        await memory.strReplace(
          args['path'] as String,
          args['old_str'] as String,
          args['new_str'] as String,
        );
        await memory.refreshInjectedCache();
        return {'ok': true};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));

  registry.register(ToolSpec(
    name: 'memory_delete',
    description: 'Delete a memory file. Refuses directories and AGENT.md.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
    executor: (args) async {
      try {
        await memory.delete(args['path'] as String);
        await memory.refreshInjectedCache();
        return {'ok': true};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));

  registry.register(ToolSpec(
    name: 'memory_search',
    description: 'Case-insensitive substring search across memory. Returns list of {path, line, preview}.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'path': {'type': 'string'},
      },
      'required': ['query'],
    },
    executor: (args) async {
      try {
        final hits = await memory.search(
          args['query'] as String,
          path: args['path'] as String?,
        );
        return {'ok': true, 'results': hits};
      } on MemoryException catch (e) {
        return {'error': e.message};
      }
    },
  ));
}
