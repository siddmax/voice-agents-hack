import 'package:syndai/cactus/engine.dart';

/// A scripted engine for tests. Each call to completeJson returns the next
/// queued response in order.
class FakeCactusEngine implements CactusEngine {
  final List<Map<String, dynamic>> jsonResponses;
  int _i = 0;

  FakeCactusEngine(this.jsonResponses);

  @override
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async =>
      '';

  @override
  Future<String> completeRaw({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    void Function(int)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async =>
      '{"success":true,"response":"","function_calls":[]}';

  @override
  Future<List<Map<String, dynamic>>> completeToolCalls({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
    void Function(int)? onTokenCount,
  }) async {
    if (_i >= jsonResponses.length) return const [];
    return [jsonResponses[_i++]];
  }

  @override
  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    void Function(int)? onTokenCount,
  }) async {
    if (_i >= jsonResponses.length) {
      throw StateError('FakeCactusEngine ran out of scripted responses');
    }
    return jsonResponses[_i++];
  }

  @override
  Future<Map<String, dynamic>?> completeToolCall({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool forceTools = true,
  }) async {
    if (_i >= jsonResponses.length) return null;
    return jsonResponses[_i++];
  }

  @override
  void close() {}
}
