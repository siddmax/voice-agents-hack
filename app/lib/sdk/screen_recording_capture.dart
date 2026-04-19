import 'dart:async';

abstract class ScreenRecordingCapture {
  bool get isRecording;
  bool get isWarmed;
  String? get lastError;
  Future<void> warmUp();
  Future<bool> start();
  Future<String?> stop();
  Future<void> cancel();
}
