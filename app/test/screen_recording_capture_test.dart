import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/screen_recording_capture.dart';

class _TestRecorder implements ScreenRecordingCapture {
  bool _warmed = false;
  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  bool get isWarmed => _warmed;

  @override
  String? get lastError => null;

  @override
  Future<void> warmUp() async => _warmed = true;

  @override
  Future<bool> start() async {
    _recording = true;
    return true;
  }

  @override
  Future<String?> stop() async {
    _recording = false;
    return '/tmp/test.mp4';
  }

  @override
  Future<void> cancel() async => _recording = false;
}

void main() {
  test('interface contract: warmUp sets isWarmed', () async {
    final recorder = _TestRecorder();
    expect(recorder.isWarmed, isFalse);
    await recorder.warmUp();
    expect(recorder.isWarmed, isTrue);
  });

  test('interface contract: start/stop lifecycle', () async {
    final recorder = _TestRecorder();
    await recorder.start();
    expect(recorder.isRecording, isTrue);
    final path = await recorder.stop();
    expect(path, '/tmp/test.mp4');
    expect(recorder.isRecording, isFalse);
  });
}
