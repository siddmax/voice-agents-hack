import 'dart:async';

import 'package:flutter/services.dart';

import 'screen_recording_capture.dart';

class ViewCaptureRecorder implements ScreenRecordingCapture {
  ViewCaptureRecorder({
    MethodChannel channel = const MethodChannel('syndai_view_capture'),
  }) : _channel = channel;

  final MethodChannel _channel;
  bool _warmed = false;
  bool _recording = false;
  String? _lastError;
  Future<String?>? _stopFuture;

  @override
  bool get isRecording => _recording;

  @override
  bool get isWarmed => _warmed;

  @override
  String? get lastError => _lastError;

  @override
  Future<void> warmUp() async {
    _lastError = null;
    try {
      final result = await _channel.invokeMethod<bool>('warmUp');
      _warmed = result ?? false;
      if (!_warmed) {
        _lastError = 'View capture warmUp returned false.';
      }
    } catch (e) {
      _lastError = _formatError(e);
      _warmed = false;
    }
  }

  @override
  Future<bool> start() async {
    _lastError = null;
    if (!_warmed) {
      await warmUp();
    }
    if (!_warmed) {
      _lastError ??=
          'View capture could not capture an initial frame before recording.';
    }
    _recording = true;
    return true;
  }

  @override
  Future<String?> stop() async {
    final pending = _stopFuture;
    if (pending != null) return pending;

    _lastError = null;
    final future = _stopOnce().whenComplete(() => _stopFuture = null);
    _stopFuture = future;
    return future;
  }

  Future<String?> _stopOnce() async {
    final wasRecording = _recording;
    _recording = false;
    if (!_warmed && !wasRecording) {
      _lastError =
          'Screen recording was not ready. The issue will still include narration and steps.';
      return null;
    }
    try {
      final path = await _channel.invokeMethod<String>('flush');
      final trimmed = path?.trim() ?? '';
      if (trimmed.isEmpty) {
        _lastError = 'View capture flush did not return a file path.';
        return null;
      }
      _warmed = true;
      return trimmed;
    } catch (e) {
      _lastError = _formatError(e);
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    _recording = false;
    try {
      await _channel.invokeMethod<void>('coolDown');
    } catch (_) {}
    _warmed = false;
  }

  String _formatError(Object error) {
    if (error is PlatformException) {
      final parts = [
        error.code,
        if (error.message != null && error.message!.isNotEmpty) error.message,
      ];
      return parts.join(': ');
    }
    return error.toString();
  }
}

class FakeViewCaptureRecorder implements ScreenRecordingCapture {
  bool _warmed = false;
  bool _recording = false;
  String? _lastError;
  int _stopCount = 0;
  Future<String?>? _stopFuture;

  String? nextPath = '/tmp/repro.mp4';
  bool nextWarmUp = true;
  Duration? stopDelay;

  int get stopCount => _stopCount;

  @override
  bool get isRecording => _recording;

  @override
  bool get isWarmed => _warmed;

  @override
  String? get lastError => _lastError;

  @override
  Future<void> warmUp() async {
    _warmed = nextWarmUp;
  }

  @override
  Future<bool> start() async {
    if (!_warmed) await warmUp();
    if (!_warmed) {
      _lastError =
          'View capture could not capture an initial frame before recording.';
    }
    _recording = true;
    return true;
  }

  @override
  Future<String?> stop() async {
    final pending = _stopFuture;
    if (pending != null) return pending;

    final future = _fakeStop().whenComplete(() => _stopFuture = null);
    _stopFuture = future;
    return future;
  }

  Future<String?> _fakeStop() async {
    final wasRecording = _recording;
    _stopCount++;
    _recording = false;
    if (!_warmed && !wasRecording) {
      _lastError =
          'Screen recording was not ready. The issue will still include narration and steps.';
      return null;
    }
    if (!_warmed) {
      _warmed = nextPath != null;
      return nextPath;
    }
    if (stopDelay != null) await Future<void>.delayed(stopDelay!);
    return nextPath;
  }

  @override
  Future<void> cancel() async {
    _recording = false;
    _warmed = false;
  }
}
