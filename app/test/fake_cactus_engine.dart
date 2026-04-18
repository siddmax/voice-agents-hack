import 'package:syndai/cactus/engine.dart';

/// A scripted engine for tests. Each call to completeJson returns the next
/// queued response in order. complete() emits each string in sequence.
class FakeCactusEngine implements CactusEngine {
  final List<Map<String, dynamic>> jsonResponses;
  int _i = 0;

  FakeCactusEngine(this.jsonResponses);

  @override
  Stream<String> complete({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) =>
      const Stream.empty();

  @override
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async =>
      '';

  @override
  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async {
    if (_i >= jsonResponses.length) {
      throw StateError('FakeCactusEngine ran out of scripted responses');
    }
    return jsonResponses[_i++];
  }

  @override
  void close() {}
}
