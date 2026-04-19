import 'dart:typed_data';

import 'package:flutter/services.dart';

class ScreenshotCapture {
  static const _channel = MethodChannel('com.voicebug/screenshot');

  Future<bool> checkPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openSettings() async {
    await _channel.invokeMethod<void>('openSettings');
  }

  Future<Uint8List?> capture() async {
    try {
      final result = await _channel.invokeMethod<Uint8List>('capture');
      return result;
    } catch (_) {
      return null;
    }
  }
}
