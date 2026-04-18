import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// Which flavor of Gemma 4 to load.
///
/// - [e2b] ~2B params, INT4. Fits on phones with < 12 GB RAM.
/// - [e4b] ~4B params, INT4. Requires 12 GB+ RAM comfortably.
enum ModelTier { e2b, e4b }

/// Detects the appropriate [ModelTier] for the current device.
///
/// Decision logic (see [pickTier]):
///   1. Compile-time override `--dart-define=SYNDAI_MODEL_TIER=e2b|e4b` wins.
///   2. Otherwise, total physical RAM (GB) decides: >= 12 → e4b, else e2b.
///   3. If RAM cannot be read, falls back to e2b (safer).
class ModelTierDetector {
  static const _override = String.fromEnvironment('SYNDAI_MODEL_TIER');

  /// Detect the tier for the current device.
  static Future<ModelTier> detect() async {
    final ramGb = await _totalRamGb();
    return pickTier(ramGb, override: _override);
  }

  /// RAM detection strategy:
  ///
  /// Uses `device_info_plus` directly on every supported platform:
  ///
  /// * Android — `AndroidDeviceInfo.physicalRamSize` (MB) via
  ///   `ActivityManager.MemoryInfo.totalMem`.
  /// * iOS     — `IosDeviceInfo.physicalRamSize` (MB) via
  ///   `NSProcessInfo.processInfo.physicalMemory`.
  /// * macOS   — `MacOsDeviceInfo.memorySize` (bytes) via `sysctl hw.memsize`.
  /// * Other/unknown — returns null → caller falls back to `e2b`.
  ///
  /// We chose the `device_info_plus` path over a custom `MethodChannel` to
  /// avoid shipping native Kotlin/Swift/Objective-C code inside the hackathon
  /// timebox. Tradeoff: we depend on a 3rd-party plugin to stay accurate; on
  /// the Android side the totalMem reading is slightly below install-advertised
  /// RAM (kernel/GPU reservation), so a 12-GB device commonly reports ~11.3 GB.
  /// The 12-GB threshold is applied to the *reported* value — users with
  /// marginal devices can force a tier via `--dart-define=SYNDAI_MODEL_TIER`.
  static Future<double?> _totalRamGb() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final mb = a.physicalRamSize; // int, MB
        if (mb > 0) return mb / 1024.0;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        final mb = i.physicalRamSize; // int, MB
        if (mb > 0) return mb / 1024.0;
      } else if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        final bytes = m.memorySize; // int, bytes
        if (bytes > 0) return bytes / (1024.0 * 1024.0 * 1024.0);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Pure decision function: resolve a tier from inputs. Exposed for testing.
///
/// * [ramGb] total physical RAM in GB, or null if unknown.
/// * [override] compile-time override, case-insensitive `"e2b"` or `"e4b"`.
///   Wins over [ramGb] when set.
ModelTier pickTier(double? ramGb, {String? override}) {
  final o = (override ?? '').toLowerCase();
  if (o == 'e4b') return ModelTier.e4b;
  if (o == 'e2b') return ModelTier.e2b;
  if (ramGb == null) return ModelTier.e2b; // safer default
  return ramGb >= 12.0 ? ModelTier.e4b : ModelTier.e2b;
}
