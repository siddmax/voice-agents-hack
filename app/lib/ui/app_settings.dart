import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  static const _kVoiceOutput = 'settings.voiceOutput';

  bool _voiceOutput = true;
  bool get voiceOutput => _voiceOutput;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _voiceOutput = prefs.getBool(_kVoiceOutput) ?? true;
    notifyListeners();
  }

  Future<void> setVoiceOutput(bool v) async {
    _voiceOutput = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVoiceOutput, v);
    notifyListeners();
  }
}
