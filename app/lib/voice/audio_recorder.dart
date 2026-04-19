import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

abstract class PcmCapture {
  bool get isRecording;
  Stream<double> get amplitude;
  Future<bool> startRecording();
  Future<String?> stopRecording();
  Future<Uint8List?> stopAndGetPcm();
  Future<void> cancel();
  void dispose();
}

class PcmRecorder implements PcmCapture {
  final AudioRecorder _recorder = AudioRecorder();
  String? _path;
  bool _recording = false;
  Timer? _maxTimer;

  static const _maxDuration = Duration(seconds: 60);
  static const _config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
    bitRate: 256000,
  );

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> startRecording() async {
    if (_recording) return true;
    if (!await _recorder.hasPermission()) return false;

    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/voicebug_pcm_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(_config, path: _path!);
    _recording = true;

    _maxTimer = Timer(_maxDuration, () {
      if (_recording) stopRecording();
    });

    return true;
  }

  @override
  Future<String?> stopRecording() async {
    _maxTimer?.cancel();
    _maxTimer = null;
    if (!_recording) return _path;
    _recording = false;
    await _recorder.stop();
    return _path;
  }

  @override
  Future<Uint8List?> stopAndGetPcm() async {
    final path = await stopRecording();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    // WAV header is 44 bytes; strip it for raw PCM
    if (bytes.length <= 44) return null;
    return Uint8List.sublistView(bytes, 44);
  }

  @override
  Stream<double> get amplitude => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((a) => ((a.current + 50) / 50).clamp(0.0, 1.0));

  @override
  Future<void> cancel() async {
    _maxTimer?.cancel();
    _maxTimer = null;
    if (_recording) {
      _recording = false;
      await _recorder.stop();
    }
    if (_path != null) {
      try {
        await File(_path!).delete();
      } catch (_) {}
      _path = null;
    }
  }

  @override
  void dispose() {
    cancel();
    _recorder.dispose();
  }
}
