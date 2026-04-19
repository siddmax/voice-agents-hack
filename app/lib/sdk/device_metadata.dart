import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

class DeviceMetadata {
  final String os;
  final String device;
  final String appVersion;
  final String screenResolution;
  final String locale;

  DeviceMetadata({
    required this.os,
    required this.device,
    required this.appVersion,
    required this.screenResolution,
    required this.locale,
  });

  static Future<DeviceMetadata> collectWithScreen(String screenResolution) async {
    final locale = Platform.localeName;
    final deviceInfo = DeviceInfoPlugin();
    String os = Platform.operatingSystem;
    String device = 'Unknown';

    if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      os = 'macOS ${info.osRelease}';
      device = info.model;
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      os = 'iOS ${info.systemVersion}';
      device = info.utsname.machine;
    } else if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      os = 'Android ${info.version.release}';
      device = '${info.manufacturer} ${info.model}';
    }

    String appVersion = '1.0.0';
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version;
    } catch (_) {}

    return DeviceMetadata(
      os: os,
      device: device,
      appVersion: appVersion,
      screenResolution: screenResolution,
      locale: locale,
    );
  }

  static Future<DeviceMetadata> collect(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size * mq.devicePixelRatio;
    return collectWithScreen('${size.width.toInt()}x${size.height.toInt()}');
  }

  Map<String, String> toMap() => {
        'os': os,
        'device': device,
        'app_version': appVersion,
        'screen_resolution': screenResolution,
        'locale': locale,
      };

  String toMarkdownTable() {
    final rows = toMap().entries.map((e) => '| ${e.key} | ${e.value} |').join('\n');
    return '| Field | Value |\n|---|---|\n$rows';
  }
}
