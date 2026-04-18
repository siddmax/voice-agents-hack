import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum SttStartResult { started, permissionDenied, unavailable }

class SpeechToTextService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  String _buffer = '';
  bool _listening = false;

  bool get isListening => _listening;

  Future<bool> _ensurePermissions() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    final rec = await Permission.speech.request();
    return rec.isGranted || rec.isLimited || rec.isRestricted == false;
  }

  Future<SttStartResult> startListening({
    void Function(String partial)? onPartial,
  }) async {
    if (_listening) return SttStartResult.started;

    final granted = await _ensurePermissions();
    if (!granted) return SttStartResult.permissionDenied;

    if (!_initialized) {
      final ok = await _speech.initialize(
        onError: (e) => debugPrint('stt error: $e'),
        onStatus: (s) => debugPrint('stt status: $s'),
      );
      if (!ok) return SttStartResult.unavailable;
      _initialized = true;
    }

    _buffer = '';
    _listening = true;
    await _speech.listen(
      onResult: (r) {
        _buffer = r.recognizedWords;
        if (onPartial != null) onPartial(_buffer);
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
    );
    return SttStartResult.started;
  }

  Future<String> stopListening() async {
    if (!_listening) return _buffer;
    await _speech.stop();
    _listening = false;
    return _buffer;
  }

  Future<void> cancel() async {
    if (!_listening) return;
    await _speech.cancel();
    _listening = false;
    _buffer = '';
  }
}
