import 'dart:typed_data';

import 'package:syndai/cactus/engine.dart';

class FakeCactusEngine implements CactusEngine {
  final List<Map<String, dynamic>> jsonResponses;
  int _i = 0;

  final List<List<Map<String, dynamic>>> capturedMessages = [];
  double? nextConfidence;
  bool nextCloudHandoff = false;
  String? nextThinking;
  String? nextRaw;

  FakeCactusEngine(this.jsonResponses);

  @override
  Future<String> completeText({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
  }) async => '';

  @override
  Future<String> completeRaw({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    capturedMessages.add(messages);
    if (nextRaw != null) return nextRaw!;
    return '{"success":true,"response":"","function_calls":[],'
        '"confidence":${nextConfidence ?? 0.85},'
        '"cloud_handoff":$nextCloudHandoff}';
  }

  @override
  Future<CactusResponse> completeRawWithMetadata({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxTokens = 512,
    double temperature = 0.2,
    bool forceTools = false,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    capturedMessages.add(messages);
    return CactusResponse(
      rawText: '{"success":true,"response":"","function_calls":[]}',
      confidence: nextConfidence ?? 0.85,
      cloudHandoff: nextCloudHandoff,
      thinking: nextThinking,
    );
  }

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
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
  }) async {
    capturedMessages.add(messages);
    if (_i >= jsonResponses.length) {
      throw StateError('FakeCactusEngine ran out of scripted responses');
    }
    return jsonResponses[_i++];
  }

  @override
  Future<(Map<String, dynamic>, CactusResponse)> completeJsonWithMetadata({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required Map<String, dynamic> schema,
    int retries = 3,
    int maxTokens = 512,
    double temperature = 0.2,
    String? query,
    bool enableThinking = false,
    Uint8List? pcmData,
    void Function(int)? onTokenCount,
  }) async {
    capturedMessages.add(messages);
    if (_i >= jsonResponses.length) {
      throw StateError('FakeCactusEngine ran out of scripted responses');
    }
    final json = jsonResponses[_i++];
    final meta = CactusResponse(
      rawText: '{}',
      confidence: nextConfidence ?? 0.85,
      cloudHandoff: nextCloudHandoff,
      thinking: nextThinking,
    );
    return (json, meta);
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
