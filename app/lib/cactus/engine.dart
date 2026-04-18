// Lane A owns the concrete impl. This file defines only the abstract
// contract that Lane C's agent loop codes against. At merge, Lane A's
// real implementation (Gemma 4 E4B via cactus.dart FFI) extends this.

abstract class CactusEngine {
  static Future<CactusEngine> load(String modelPath) =>
      throw UnimplementedError('Lane A concrete impl');

  Stream<String> complete({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.7,
  });

  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 2,
  });

  void close();
}
