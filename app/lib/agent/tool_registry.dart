typedef ToolExecutor = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> args);

class ToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolExecutor executor;
  final String? source;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.executor,
    this.source,
  });

  Map<String, dynamic> toSchema() => {
        'name': name,
        'description': description,
        'parameters': inputSchema,
      };
}

class ToolRegistry {
  final Map<String, ToolSpec> _tools = {};

  void register(ToolSpec tool) {
    _tools[tool.name] = tool;
  }

  void unregisterSource(String source) {
    _tools.removeWhere((_, t) => t.source == source);
  }

  ToolSpec? get(String name) => _tools[name];

  List<ToolSpec> get all => List.unmodifiable(_tools.values);

  List<Map<String, dynamic>> toSchemas() =>
      _tools.values.map((t) => t.toSchema()).toList();

  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> args) async {
    final t = _tools[name];
    if (t == null) {
      return {'error': 'unknown_tool', 'name': name};
    }
    try {
      return await t.executor(args);
    } catch (e) {
      return {'error': 'tool_exception', 'name': name, 'message': '$e'};
    }
  }
}
