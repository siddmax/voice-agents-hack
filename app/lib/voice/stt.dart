import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum SttStartResult { started, permissionDenied, unavailable }

class SpeechToTextService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  String _buffer = '';
  bool _listening = false;
  String? _lastError;
  final StreamController<double> _levelCtrl = StreamController.broadcast();

  bool get isListening => _listening;

  /// Stream of sound levels in [0.0, 1.0]. Underlying platform reports dB
  /// roughly in [-2, 10]; we normalize here so UI can use it directly.
  Stream<double> get soundLevel => _levelCtrl.stream;

  /// Pre-iOS-13-style permission_handler request returns permanentlyDenied
  /// on iOS simulator without showing the system dialog (Baseflow #574).
  /// On iOS we let speech_to_text's own initialize() trigger the native
  /// SFSpeechRecognizer + AVAudioSession dialogs, which work in the sim.
  /// On Android we still need permission_handler — RECORD_AUDIO is a runtime
  /// permission and the plugin doesn't request it on its own.
  Future<bool> _ensurePermissionsAndroidOnly() async {
    if (!Platform.isAndroid) return true;
    final mic = await Permission.microphone.request();
    return mic.isGranted;
  }

  Future<SttStartResult> startListening({
    void Function(String partial)? onPartial,
  }) async {
    if (_listening) return SttStartResult.started;

    if (!await _ensurePermissionsAndroidOnly()) {
      return SttStartResult.permissionDenied;
    }

    if (!_initialized) {
      _lastError = null;
      final ok = await _speech.initialize(
        // Both callbacks fire on the iOS-native permission denial path.
        onError: (e) {
          _lastError = e.errorMsg;
          debugPrint('stt error: ${e.errorMsg} (permanent=${e.permanent})');
        },
        onStatus: (s) => debugPrint('stt status: $s'),
      );
      if (!ok) {
        // initialize() returns false on iOS when SFSpeechRecognizer auth
        // is denied. The iOS dialog fired; user said no.
        return SttStartResult.permissionDenied;
      }
      _initialized = true;
    }

    _buffer = '';
    _listening = true;
    await _speech.listen(
      onResult: (r) {
        _buffer = r.recognizedWords;
        if (onPartial != null) onPartial(_buffer);
      },
      onSoundLevelChange: (level) {
        final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
        if (!_levelCtrl.isClosed) _levelCtrl.add(normalized);
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
    );
    // listen() returning doesn't tell us if the AVAudioSession mic dialog
    // was denied — that surfaces via onError. Inspect the last reported
    // error here so the UI can report "denied" instead of a silent no-op.
    if (!_speech.isListening) {
      _listening = false;
      final err = _lastError?.toLowerCase() ?? '';
      if (err.contains('denied') || err.contains('permission')) {
        return SttStartResult.permissionDenied;
      }
      return SttStartResult.unavailable;
    }
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
