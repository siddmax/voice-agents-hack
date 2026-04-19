import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/screen_recording_capture.dart';

class _FakeScreenRecordingPlatform implements ScreenRecordingPlatform {
  bool nextStart = true;
  String nextPath = '/tmp/repro.mp4';
  int starts = 0;
  int stops = 0;
  Completer<String>? stopCompleter;

  @override
  Future<bool> startRecordScreenAndAudio(
    String name, {
    required String titleNotification,
    required String messageNotification,
  }) async {
    starts += 1;
    return nextStart;
  }

  @override
  Future<String> stopRecordScreen() {
    stops += 1;
    final completer = stopCompleter;
    if (completer != null) return completer.future;
    return Future.value(nextPath);
  }
}

void main() {
  test('stop is single-flight so native stop cannot be called twice', () async {
    final platform = _FakeScreenRecordingPlatform()
      ..stopCompleter = Completer<String>();
    final capture = NativeScreenRecordingCapture(
      platform: platform,
      minimumDuration: Duration.zero,
    );

    expect(await capture.start(), isTrue);

    final firstStop = capture.stop();
    final secondStop = capture.stop();

    expect(platform.stops, 1);
    platform.stopCompleter!.complete('/tmp/repro.mp4');

    expect(await firstStop, '/tmp/repro.mp4');
    expect(await secondStop, '/tmp/repro.mp4');
    expect(platform.stops, 1);
    expect(capture.isRecording, isFalse);
  });

  test('failed start does not call platform stop', () async {
    final platform = _FakeScreenRecordingPlatform()..nextStart = false;
    final capture = NativeScreenRecordingCapture(
      platform: platform,
      minimumDuration: Duration.zero,
    );

    expect(await capture.start(), isFalse);
    expect(await capture.stop(), isNull);
    expect(platform.stops, 0);
  });

  test('cancel shares the same guarded stop path', () async {
    final platform = _FakeScreenRecordingPlatform();
    final capture = NativeScreenRecordingCapture(
      platform: platform,
      minimumDuration: Duration.zero,
    );

    expect(await capture.start(), isTrue);
    await Future.wait([capture.cancel(), capture.cancel()]);

    expect(platform.stops, 1);
    expect(capture.isRecording, isFalse);
  });
}
