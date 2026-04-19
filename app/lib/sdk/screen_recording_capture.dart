import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screen_recording/flutter_screen_recording.dart';

abstract class ScreenRecordingCapture {
  bool get isRecording;
  Future<bool> start();
  Future<String?> stop();
  Future<void> cancel();
}

abstract class ScreenRecordingPlatform {
  Future<bool> startRecordScreenAndAudio(
    String name, {
    required String titleNotification,
    required String messageNotification,
  });

  Future<String> stopRecordScreen();
}

class FlutterScreenRecordingPlatform implements ScreenRecordingPlatform {
  const FlutterScreenRecordingPlatform();

  @override
  Future<bool> startRecordScreenAndAudio(
    String name, {
    required String titleNotification,
    required String messageNotification,
  }) {
    return FlutterScreenRecording.startRecordScreenAndAudio(
      name,
      titleNotification: titleNotification,
      messageNotification: messageNotification,
    );
  }

  @override
  Future<String> stopRecordScreen() {
    return FlutterScreenRecording.stopRecordScreen;
  }
}

class IosReplayKitScreenRecordingPlatform implements ScreenRecordingPlatform {
  IosReplayKitScreenRecordingPlatform({
    MethodChannel channel = const MethodChannel('syndai_screen_recording'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> startRecordScreenAndAudio(
    String name, {
    required String titleNotification,
    required String messageNotification,
  }) async {
    final started = await _channel.invokeMethod<bool>(
      'startRecordScreen',
      <String, Object?>{'name': name, 'audio': true},
    );
    return started ?? false;
  }

  @override
  Future<String> stopRecordScreen() async {
    final path = await _channel.invokeMethod<String>('stopRecordScreen');
    return path ?? '';
  }
}

class NativeScreenRecordingCapture implements ScreenRecordingCapture {
  NativeScreenRecordingCapture({
    ScreenRecordingPlatform? platform,
    this.minimumDuration = const Duration(milliseconds: 900),
  }) : _platform =
           platform ??
           (!kIsWeb && Platform.isIOS
               ? IosReplayKitScreenRecordingPlatform()
               : const FlutterScreenRecordingPlatform());

  final ScreenRecordingPlatform _platform;
  final Duration minimumDuration;
  bool _recording = false;
  Future<bool>? _startFuture;
  Future<String?>? _stopFuture;
  DateTime? _startedAt;

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> start() async {
    if (_recording) return true;
    final pendingStart = _startFuture;
    if (pendingStart != null) return pendingStart;

    final name = 'voicebug_repro_${DateTime.now().millisecondsSinceEpoch}';
    final startFuture = _platform
        .startRecordScreenAndAudio(
          name,
          titleNotification: 'Bug report recording',
          messageNotification: 'Recording screen and voice for your bug report',
        )
        .then((started) {
          _recording = started;
          _startedAt = started ? DateTime.now() : null;
          return started;
        })
        .catchError((_) {
          _recording = false;
          _startedAt = null;
          return false;
        })
        .whenComplete(() {
          _startFuture = null;
        });
    _startFuture = startFuture;
    return startFuture;
  }

  @override
  Future<String?> stop() async {
    final pendingStop = _stopFuture;
    if (pendingStop != null) return pendingStop;

    final stopFuture = _stopOnce().whenComplete(() {
      _stopFuture = null;
    });
    _stopFuture = stopFuture;
    return stopFuture;
  }

  Future<String?> _stopOnce() async {
    final pendingStart = _startFuture;
    if (pendingStart != null) {
      await pendingStart;
    }
    if (!_recording) return null;
    _recording = false;
    final startedAt = _startedAt;
    _startedAt = null;
    if (startedAt != null) {
      final elapsed = DateTime.now().difference(startedAt);
      final remaining = minimumDuration - elapsed;
      if (!remaining.isNegative && remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    final path = await _platform.stopRecordScreen();
    return path.trim().isEmpty ? null : path;
  }

  @override
  Future<void> cancel() async {
    if (!_recording && _stopFuture == null) return;
    try {
      await stop();
    } catch (_) {
      _recording = false;
      _startedAt = null;
    }
  }
}
