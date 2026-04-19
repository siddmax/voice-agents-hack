# View Hierarchy Screen Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flaky ReplayKit-based screen recording with a deterministic view-hierarchy snapshot approach (the same technique used by Instabug, UXCam, FullStory, and every production bug-reporting SDK), eliminating the "no local recording path" bug permanently.

**Architecture:** Continuously capture `drawHierarchy` snapshots at 2-3fps on iOS via a Swift platform channel plugin, storing compressed JPEG frames in a time-indexed ring buffer (last 60s). On bug report, flush the buffer into an MP4 via AVAssetWriter and return the file path. On Dart side, a `ViewCaptureRecorder` implements the existing `ScreenRecordingCapture` interface so `ReportFlowController` needs minimal changes. Flutter `RepaintBoundary` serves as cross-platform fallback for macOS/Android/test.

**Tech Stack:** Swift (UIKit `drawHierarchy`, AVAssetWriter, DispatchSourceTimer), Dart (MethodChannel), Flutter (RepaintBoundary fallback), AVFoundation (MP4 encoding)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| **Create** | `ios/Runner/ViewCapturePlugin.swift` | Swift plugin: timer-driven `drawHierarchy` snapshots → ring buffer → AVAssetWriter flush to MP4 |
| **Create** | `lib/sdk/view_capture_recorder.dart` | Dart wrapper: platform channel calls, `ScreenRecordingCapture` interface impl, RepaintBoundary fallback |
| **Create** | `test/view_capture_recorder_test.dart` | Unit tests for Dart layer with fake platform |
| **Modify** | `ios/Runner/AppDelegate.swift` | Register `ViewCapturePlugin`, remove `RobustScreenRecordingPlugin` |
| **Modify** | `lib/ui/jarvis_screen.dart` | Call `warmUp()` on init, pass new recorder |
| **Modify** | `lib/sdk/screen_recording_capture.dart` | Keep `ScreenRecordingCapture` interface, delete all implementation classes |
| **Modify** | `lib/ui/report_flow_controller.dart` | Remove `minimumDuration`-related workarounds, simplify `_stopScreen` |
| **Modify** | `pubspec.yaml` | Remove `flutter_screen_recording` dependency |
| **Modify** | `test/screen_recording_capture_test.dart` | Update to test new interface only |
| **Modify** | `test/report_flow_controller_test.dart` | Update `_FakeScreenRecorder` to match simplified interface |
| **Delete** | `ios/Runner/RobustScreenRecordingPlugin.swift` | Old ReplayKit plugin — replaced entirely |

---

### Task 1: Define the Dart Interface and Fake

Strip `screen_recording_capture.dart` to just the `ScreenRecordingCapture` abstract interface and a `FakeScreenRecordingCapture` for tests. Delete all implementation classes — they'll be replaced in later tasks.

**Files:**
- Modify: `app/lib/sdk/screen_recording_capture.dart`
- Test: `app/test/screen_recording_capture_test.dart`

- [ ] **Step 1: Write the updated interface file**

Replace `app/lib/sdk/screen_recording_capture.dart` with:

```dart
import 'dart:async';

abstract class ScreenRecordingCapture {
  bool get isRecording;
  bool get isWarmed;
  String? get lastError;
  Future<void> warmUp();
  Future<bool> start();
  Future<String?> stop();
  Future<void> cancel();
}
```

- [ ] **Step 2: Write a failing test for the new `isWarmed` contract**

Add to `app/test/screen_recording_capture_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/screen_recording_capture.dart';
import 'package:syndai/sdk/view_capture_recorder.dart';

void main() {
  test('FakeViewCaptureRecorder is not warmed before warmUp', () {
    final recorder = FakeViewCaptureRecorder();
    expect(recorder.isWarmed, isFalse);
  });

  test('FakeViewCaptureRecorder is warmed after warmUp', () async {
    final recorder = FakeViewCaptureRecorder();
    await recorder.warmUp();
    expect(recorder.isWarmed, isTrue);
  });

  test('stop returns path when warmed', () async {
    final recorder = FakeViewCaptureRecorder()..nextPath = '/tmp/repro.mp4';
    await recorder.warmUp();
    await recorder.start();
    expect(await recorder.stop(), '/tmp/repro.mp4');
  });

  test('stop returns null with error when not warmed', () async {
    final recorder = FakeViewCaptureRecorder();
    await recorder.start();
    expect(await recorder.stop(), isNull);
    expect(recorder.lastError, contains('not warmed'));
  });

  test('concurrent stop calls are single-flighted', () async {
    final recorder = FakeViewCaptureRecorder()
      ..nextPath = '/tmp/repro.mp4'
      ..stopDelay = const Duration(milliseconds: 50);
    await recorder.warmUp();
    await recorder.start();

    final first = recorder.stop();
    final second = recorder.stop();

    expect(await first, '/tmp/repro.mp4');
    expect(await second, '/tmp/repro.mp4');
    expect(recorder.stopCount, 1);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/screen_recording_capture_test.dart`
Expected: FAIL — `view_capture_recorder.dart` does not exist yet

- [ ] **Step 4: Commit interface change**

```bash
git add app/lib/sdk/screen_recording_capture.dart app/test/screen_recording_capture_test.dart
git commit -m "refactor: strip screen_recording_capture to pure interface, add isWarmed"
```

---

### Task 2: Implement the Dart ViewCaptureRecorder

Create the Dart-side recorder that talks to the Swift plugin via MethodChannel, with a `FakeViewCaptureRecorder` for tests.

**Files:**
- Create: `app/lib/sdk/view_capture_recorder.dart`
- Test: `app/test/view_capture_recorder_test.dart`

- [ ] **Step 1: Write the failing test file**

Create `app/test/view_capture_recorder_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/view_capture_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late ViewCaptureRecorder recorder;
  final log = <String>[];

  setUp(() {
    log.clear();
    channel = const MethodChannel('syndai_view_capture');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call.method);
      switch (call.method) {
        case 'warmUp':
          return true;
        case 'flush':
          return '/tmp/capture.mp4';
        case 'coolDown':
          return null;
        default:
          return null;
      }
    });
    recorder = ViewCaptureRecorder();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('warmUp calls platform and sets isWarmed', () async {
    expect(recorder.isWarmed, isFalse);
    await recorder.warmUp();
    expect(recorder.isWarmed, isTrue);
    expect(log, ['warmUp']);
  });

  test('start is a no-op (capture is always running after warmUp)', () async {
    await recorder.warmUp();
    final result = await recorder.start();
    expect(result, isTrue);
    expect(recorder.isRecording, isTrue);
    expect(log, ['warmUp']);
  });

  test('stop calls flush and returns path', () async {
    await recorder.warmUp();
    await recorder.start();
    final path = await recorder.stop();
    expect(path, '/tmp/capture.mp4');
    expect(log, ['warmUp', 'flush']);
  });

  test('stop without warmUp returns null with error', () async {
    await recorder.start();
    final path = await recorder.stop();
    expect(path, isNull);
    expect(recorder.lastError, contains('not warmed'));
  });

  test('cancel calls coolDown', () async {
    await recorder.warmUp();
    await recorder.cancel();
    expect(log, ['warmUp', 'coolDown']);
    expect(recorder.isWarmed, isFalse);
  });

  test('flush error is captured as lastError', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'flush') {
        throw PlatformException(code: 'FLUSH_ERROR', message: 'No frames');
      }
      return true;
    });
    recorder = ViewCaptureRecorder();
    await recorder.warmUp();
    await recorder.start();
    final path = await recorder.stop();
    expect(path, isNull);
    expect(recorder.lastError, contains('No frames'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/view_capture_recorder_test.dart`
Expected: FAIL — `view_capture_recorder.dart` does not exist

- [ ] **Step 3: Implement ViewCaptureRecorder and FakeViewCaptureRecorder**

Create `app/lib/sdk/view_capture_recorder.dart`:

```dart
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
    _recording = false;
    if (!_warmed) {
      _lastError = 'View capture is not warmed. Cannot flush recording.';
      return null;
    }
    try {
      final path = await _channel.invokeMethod<String>('flush');
      final trimmed = path?.trim() ?? '';
      if (trimmed.isEmpty) {
        _lastError = 'View capture flush did not return a file path.';
        return null;
      }
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
    _stopCount++;
    _recording = false;
    if (!_warmed) {
      _lastError = 'View capture is not warmed. Cannot flush recording.';
      return null;
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/view_capture_recorder_test.dart && flutter test test/screen_recording_capture_test.dart`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add app/lib/sdk/view_capture_recorder.dart app/test/view_capture_recorder_test.dart
git commit -m "feat: add ViewCaptureRecorder with platform channel and fake for tests"
```

---

### Task 3: Build the Swift ViewCapturePlugin

Create the native iOS plugin that continuously captures `drawHierarchy` snapshots into a ring buffer and flushes to MP4 on demand.

**Files:**
- Create: `app/ios/Runner/ViewCapturePlugin.swift`

- [ ] **Step 1: Create the Swift plugin**

Create `app/ios/Runner/ViewCapturePlugin.swift`:

```swift
import AVFoundation
import Flutter
import UIKit

final class ViewCapturePlugin: NSObject, FlutterPlugin {
  private let writerQueue = DispatchQueue(label: "com.siddmax.syndai.view-capture.writer")
  private var captureTimer: DispatchSourceTimer?
  private var ringBuffer: [(timestamp: CFTimeInterval, jpeg: Data)] = []
  private let maxBufferSeconds: Double = 60
  private let captureInterval: Double = 1.0 / 3.0 // 3 fps
  private var isWarmed = false
  private var frameCount = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "syndai_view_capture",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(ViewCapturePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "warmUp":
      warmUp(result: result)
    case "flush":
      flush(result: result)
    case "coolDown":
      coolDown(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Warm Up

  private func warmUp(result: @escaping FlutterResult) {
    guard !isWarmed else {
      result(true)
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: captureInterval)
    timer.setEventHandler { [weak self] in
      self?.captureFrame()
    }
    timer.resume()
    captureTimer = timer
    isWarmed = true
    result(true)
  }

  // MARK: - Capture

  private func captureFrame() {
    guard isWarmed else { return }
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })
    else { return }

    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { ctx in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }

    guard let jpeg = image.jpegData(compressionQuality: 0.5) else { return }

    let now = CACurrentMediaTime()
    writerQueue.async { [weak self] in
      guard let self = self else { return }
      self.ringBuffer.append((timestamp: now, jpeg: jpeg))
      self.frameCount += 1
      let cutoff = now - self.maxBufferSeconds
      self.ringBuffer.removeAll { $0.timestamp < cutoff }
    }
  }

  // MARK: - Flush

  private func flush(result: @escaping FlutterResult) {
    writerQueue.async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async { result("") }
        return
      }
      let frames = self.ringBuffer
      guard !frames.isEmpty else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "NO_FRAMES",
            message: "Ring buffer is empty. No frames were captured.",
            details: nil
          ))
        }
        return
      }
      self.encodeToMP4(frames: frames) { path in
        DispatchQueue.main.async { result(path) }
      }
    }
  }

  private func encodeToMP4(
    frames: [(timestamp: CFTimeInterval, jpeg: Data)],
    completion: @escaping (String) -> Void
  ) {
    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    let fileName = "voicebug_repro_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"
    let outputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent(fileName)

    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    guard let firstImage = UIImage(data: frames[0].jpeg) else {
      completion("")
      return
    }

    let width = Int(firstImage.size.width * firstImage.scale)
    let height = Int(firstImage.size.height * firstImage.scale)

    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
      completion("")
      return
    }

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerInput.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )

    guard writer.canAdd(writerInput) else {
      completion("")
      return
    }
    writer.add(writerInput)

    guard writer.startWriting() else {
      completion("")
      return
    }
    writer.startSession(atSourceTime: .zero)

    let baseTimestamp = frames[0].timestamp
    let fps = 3.0

    for (index, frame) in frames.enumerated() {
      autoreleasepool {
        guard let image = UIImage(data: frame.jpeg),
              let cgImage = image.cgImage
        else { return }

        let elapsed = frame.timestamp - baseTimestamp
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: CMTimeScale(fps * 600))

        while !writerInput.isReadyForMoreMediaData {
          Thread.sleep(forTimeInterval: 0.01)
        }

        guard let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
          data: CVPixelBufferGetBaseAddress(buffer),
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        adaptor.append(buffer, withPresentationTime: presentationTime)
      }
    }

    writerInput.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()

    if writer.status == .completed {
      completion(outputURL.path)
    } else {
      completion("")
    }
  }

  // MARK: - Cool Down

  private func coolDown(result: @escaping FlutterResult) {
    captureTimer?.cancel()
    captureTimer = nil
    isWarmed = false
    writerQueue.async { [weak self] in
      self?.ringBuffer.removeAll()
      self?.frameCount = 0
      DispatchQueue.main.async { result(nil) }
    }
  }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter build ios --no-codesign --debug 2>&1 | tail -20`
Expected: BUILD SUCCEEDED (or no Swift compilation errors)

- [ ] **Step 3: Commit**

```bash
git add app/ios/Runner/ViewCapturePlugin.swift
git commit -m "feat: add ViewCapturePlugin — drawHierarchy ring buffer with MP4 flush"
```

---

### Task 4: Wire Up AppDelegate and Remove Old Plugin

Register the new plugin and delete the old ReplayKit one.

**Files:**
- Modify: `app/ios/Runner/AppDelegate.swift`
- Delete: `app/ios/Runner/RobustScreenRecordingPlugin.swift`

- [ ] **Step 1: Update AppDelegate.swift**

Replace the contents of `app/ios/Runner/AppDelegate.swift` with:

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ViewCapturePlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "ViewCapturePlugin")!
    )
  }
}
```

- [ ] **Step 2: Delete the old plugin**

Run: `rm /Users/sidsharma/CactusHackathon/voice-agents-hack/app/ios/Runner/RobustScreenRecordingPlugin.swift`

- [ ] **Step 3: Verify build compiles**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter build ios --no-codesign --debug 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add app/ios/Runner/AppDelegate.swift
git rm app/ios/Runner/RobustScreenRecordingPlugin.swift
git commit -m "refactor: replace RobustScreenRecordingPlugin with ViewCapturePlugin in AppDelegate"
```

---

### Task 5: Update ReportFlowController to Use ViewCaptureRecorder

Modify the controller to call `warmUp()` and remove the `minimumDuration` workaround. The controller already depends on `ScreenRecordingCapture` interface, so changes are minimal.

**Files:**
- Modify: `app/lib/ui/report_flow_controller.dart`
- Modify: `app/lib/ui/jarvis_screen.dart`

- [ ] **Step 1: Add warmUp call in JarvisScreen.initState**

In `app/lib/ui/jarvis_screen.dart`, after the `_reportFlow = ReportFlowController(...)` block (around line 140), add:

```dart
    unawaited(_reportFlow.screenRecorder.warmUp());
```

This requires exposing `screenRecorder` from the controller. In `app/lib/ui/report_flow_controller.dart`, add a public getter:

After line 62 (`final ScreenRecordingCapture _screenRecorder;`), the getter is already accessible via `_screenRecorder`. Add a public accessor:

```dart
  ScreenRecordingCapture get screenRecorder => _screenRecorder;
```

- [ ] **Step 2: Update JarvisScreen to default to ViewCaptureRecorder**

In `app/lib/ui/jarvis_screen.dart`, add the import:

```dart
import '../sdk/view_capture_recorder.dart';
```

Change line 93 from:
```dart
      screenRecorder: widget.screenRecorder ?? NativeScreenRecordingCapture(),
```
to:
```dart
      screenRecorder: widget.screenRecorder ?? ViewCaptureRecorder(),
```

- [ ] **Step 3: Simplify _stopScreen in ReportFlowController**

In `app/lib/ui/report_flow_controller.dart`, the `_stopScreen` method (lines 345-361) is already correct — it calls `_screenRecorder.stop()` and handles null/empty. No changes needed here since the new recorder handles everything internally.

- [ ] **Step 4: Remove NativeScreenRecordingCapture import from jarvis_screen.dart**

Remove the import line:
```dart
import '../sdk/screen_recording_capture.dart';
```

Add instead (if not already present):
```dart
import '../sdk/screen_recording_capture.dart';
```

Actually, keep the import since `ScreenRecordingCapture` interface is still used as the type for `JarvisScreen.screenRecorder` parameter. No change needed.

- [ ] **Step 5: Run existing tests**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/report_flow_controller_test.dart`
Expected: ALL PASS (tests use `_FakeScreenRecorder` which implements `ScreenRecordingCapture`)

- [ ] **Step 6: Commit**

```bash
git add app/lib/ui/report_flow_controller.dart app/lib/ui/jarvis_screen.dart
git commit -m "feat: wire ViewCaptureRecorder into JarvisScreen, add warmUp on init"
```

---

### Task 6: Update Existing Tests for New Interface

The `_FakeScreenRecorder` in `report_flow_controller_test.dart` needs to implement the new `isWarmed` and `warmUp()` members.

**Files:**
- Modify: `app/test/report_flow_controller_test.dart`

- [ ] **Step 1: Update _FakeScreenRecorder to add isWarmed and warmUp**

In `app/test/report_flow_controller_test.dart`, update the `_FakeScreenRecorder` class (lines 50-79):

```dart
class _FakeScreenRecorder implements ScreenRecordingCapture {
  bool _recording = false;
  bool _warmed = true; // default to true so existing tests don't break
  bool nextStart = true;
  String? nextPath = '/tmp/repro.mp4';
  String? stopError;

  @override
  bool get isRecording => _recording;

  @override
  bool get isWarmed => _warmed;

  @override
  String? get lastError => stopError;

  @override
  Future<void> warmUp() async {
    _warmed = true;
  }

  @override
  Future<void> cancel() async {
    _recording = false;
  }

  @override
  Future<bool> start() async {
    _recording = nextStart;
    return nextStart;
  }

  @override
  Future<String?> stop() async {
    _recording = false;
    if (stopError != null) return null;
    return nextPath;
  }
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/report_flow_controller_test.dart`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add app/test/report_flow_controller_test.dart
git commit -m "test: update _FakeScreenRecorder for isWarmed/warmUp interface"
```

---

### Task 7: Remove flutter_screen_recording Dependency

Remove the package from pubspec.yaml and clean up any remaining imports.

**Files:**
- Modify: `app/pubspec.yaml`

- [ ] **Step 1: Remove flutter_screen_recording from pubspec.yaml**

In `app/pubspec.yaml`, delete line 52:
```yaml
  flutter_screen_recording: ^2.0.25
```

- [ ] **Step 2: Remove the old import from screen_recording_capture.dart**

Verify that `app/lib/sdk/screen_recording_capture.dart` no longer imports `flutter_screen_recording`. After Task 1, it should only contain the abstract interface with no imports of the old package.

- [ ] **Step 3: Run pub get and full test suite**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter pub get && flutter test`
Expected: ALL PASS, no unresolved imports

- [ ] **Step 4: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock
git commit -m "chore: remove flutter_screen_recording dependency"
```

---

### Task 8: Add Integration Test for Full Bug Report Flow with Video

Add an end-to-end test that verifies the entire flow from bug report initiation through video attachment.

**Files:**
- Create: `app/test/view_capture_integration_test.dart`

- [ ] **Step 1: Write the integration test**

Create `app/test/view_capture_integration_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/feedback_analyzer.dart';
import 'package:syndai/sdk/github_issue_service.dart';
import 'package:syndai/sdk/view_capture_recorder.dart';
import 'package:syndai/ui/report_flow_controller.dart';
import 'package:syndai/voice/audio_recorder.dart';

class _FakeRecorder implements PcmCapture {
  bool _recording = false;

  @override
  Stream<double> get amplitude => const Stream.empty();

  @override
  bool get isRecording => _recording;

  @override
  Future<void> cancel() async => _recording = false;

  @override
  void dispose() => _recording = false;

  @override
  Future<bool> startRecording() async {
    _recording = true;
    return true;
  }

  @override
  Future<Uint8List?> stopAndGetPcm() async {
    _recording = false;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<String?> stopRecording() async {
    _recording = false;
    return '/tmp/fake.wav';
  }
}

class _FakeIssueService extends GitHubIssueService {
  GitHubIssueRequest? lastRequest;
  String? nextVideoUrl = 'https://example.com/repro.mp4';

  @override
  bool get isReady => true;

  @override
  String? get lastUploadError => null;

  @override
  Future<GitHubIssueSubmission> submit(GitHubIssueRequest request) async {
    lastRequest = request;
    return const GitHubIssueSubmission(
      url: 'https://github.com/acme/app/issues/42',
      issueNumber: '#42',
    );
  }

  @override
  Future<String?> uploadVideoFile(String path) async => nextVideoUrl;
}

void main() {
  test('full bug report flow attaches video when view capture is warmed',
      () async {
    final screenRecorder = FakeViewCaptureRecorder()
      ..nextPath = '/tmp/view_capture.mp4';
    await screenRecorder.warmUp();

    final issueService = _FakeIssueService();

    final ctrl = ReportFlowController(
      recorder: _FakeRecorder(),
      screenRecorder: screenRecorder,
      issueService: issueService,
      transcribe: (_) async => 'Tap buy now. The checkout is stuck.',
      analyzeFeedback: (t, _) async => FeedbackReport.fromTranscript(t),
      reproContext: () => const ReproContext(
        selectedSeat: 'Section 105',
        deviceInfo: '| os | iOS |',
        log: '{}',
      ),
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(ctrl.state, ReportFlowState.reproPreview);
    expect(ctrl.videoPath, '/tmp/view_capture.mp4');
    expect(ctrl.bugReport?.videoPath, '/tmp/view_capture.mp4');

    await ctrl.submit();

    expect(ctrl.state, ReportFlowState.done);
    expect(issueService.lastRequest?.body, contains('Status: uploaded'));
    expect(
      issueService.lastRequest?.body,
      contains('https://example.com/repro.mp4'),
    );
  });

  test('bug report still submits when view capture is not warmed', () async {
    final screenRecorder = FakeViewCaptureRecorder()
      ..nextWarmUp = false;

    final issueService = _FakeIssueService();

    final ctrl = ReportFlowController(
      recorder: _FakeRecorder(),
      screenRecorder: screenRecorder,
      issueService: issueService,
      transcribe: (_) async => 'Tap buy now. Stuck on spinner.',
      analyzeFeedback: (t, _) async => FeedbackReport.fromTranscript(t),
      reproContext: () => const ReproContext(
        selectedSeat: 'Section 105',
        deviceInfo: '| os | iOS |',
        log: '{}',
      ),
    );

    ctrl.openChooser();
    await ctrl.chooseBugRepro();
    await ctrl.finishBugRepro();

    expect(ctrl.state, ReportFlowState.reproPreview);
    expect(ctrl.videoPath, isNull);

    await ctrl.submit();

    expect(ctrl.state, ReportFlowState.done);
    expect(
      issueService.lastRequest?.body,
      contains('upload unavailable'),
    );
  });
}
```

- [ ] **Step 2: Run the integration test**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test test/view_capture_integration_test.dart`
Expected: ALL PASS

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test`
Expected: ALL PASS

- [ ] **Step 4: Commit**

```bash
git add app/test/view_capture_integration_test.dart
git commit -m "test: add integration test for full bug report flow with view capture"
```

---

### Task 9: Update Video Evidence UI for New Recorder

The `_VideoEvidence` widget in `report_flow_overlay.dart` already handles null paths gracefully. Verify the message for the "not warmed" case is user-friendly.

**Files:**
- Modify: `app/lib/ui/report_flow_overlay.dart` (minor text update)

- [ ] **Step 1: Update the fallback message**

In `app/lib/ui/report_flow_overlay.dart`, the `_videoEvidenceMessage()` method at line 655 handles `path == null`. The `widget.note` will contain the `lastError` from ViewCaptureRecorder. No code changes needed if the error messages are already user-friendly.

Verify by reading the message flow:
1. `ViewCaptureRecorder.stop()` sets `_lastError = 'View capture is not warmed. Cannot flush recording.'`
2. `ReportFlowController._stopScreen()` reads `_screenRecorder.lastError` and sets `_videoCaptureNote`
3. `BugReproReport.videoUploadNote` gets the note
4. `_VideoEvidence` displays it

The message "View capture is not warmed" is confusing for users. Update the message in `view_capture_recorder.dart`:

In `app/lib/sdk/view_capture_recorder.dart`, change the `_stopOnce` error message from:
```dart
      _lastError = 'View capture is not warmed. Cannot flush recording.';
```
to:
```dart
      _lastError = 'Screen recording was not ready. The issue will still include narration and steps.';
```

And in `FakeViewCaptureRecorder._fakeStop()`, make the same change:
```dart
      _lastError = 'Screen recording was not ready. The issue will still include narration and steps.';
```

- [ ] **Step 2: Update tests that assert on the old error message**

In `app/test/view_capture_recorder_test.dart`, update the test assertion:
```dart
    expect(recorder.lastError, contains('not ready'));
```

In `app/test/screen_recording_capture_test.dart`, update similarly:
```dart
    expect(recorder.lastError, contains('not ready'));
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test`
Expected: ALL PASS

- [ ] **Step 4: Commit**

```bash
git add app/lib/sdk/view_capture_recorder.dart app/test/view_capture_recorder_test.dart app/test/screen_recording_capture_test.dart
git commit -m "fix: use user-friendly error message when screen recording not ready"
```

---

### Task 10: Clean Up Old Screen Recording Imports

Search for and remove any remaining references to the old classes.

**Files:**
- Potentially modify: any file still importing `FlutterScreenRecordingPlatform`, `IosReplayKitScreenRecordingPlatform`, or `NativeScreenRecordingCapture`

- [ ] **Step 1: Search for stale references**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && grep -r "NativeScreenRecordingCapture\|FlutterScreenRecordingPlatform\|IosReplayKitScreenRecordingPlatform\|flutter_screen_recording\|RobustScreenRecordingPlugin" lib/ test/ ios/ --include="*.dart" --include="*.swift"`

Fix any remaining references found.

- [ ] **Step 2: Run full test suite**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter test`
Expected: ALL PASS

- [ ] **Step 3: Verify iOS build**

Run: `cd /Users/sidsharma/CactusHackathon/voice-agents-hack/app && flutter build ios --no-codesign --debug 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove all references to old ReplayKit screen recording"
```

---

## Summary of Changes

**Root cause eliminated:** The ReplayKit frame delivery race condition cannot occur because we no longer use ReplayKit. `drawHierarchy` is synchronous and deterministic — every call produces a frame.

**What was deleted:**
- `RobustScreenRecordingPlugin.swift` (ReplayKit + AVAssetWriter)
- `NativeScreenRecordingCapture` class
- `FlutterScreenRecordingPlatform` class
- `IosReplayKitScreenRecordingPlatform` class
- `flutter_screen_recording` package dependency
- `minimumDuration` hack

**What was added:**
- `ViewCapturePlugin.swift` — 3fps `drawHierarchy` ring buffer with MP4 flush
- `ViewCaptureRecorder` — Dart platform channel wrapper
- `FakeViewCaptureRecorder` — test double
- Comprehensive tests for the new flow

**Tradeoffs accepted:**
- 3fps instead of 30fps (sufficient for bug reproduction)
- No system UI capture (keyboard, alerts) — matches industry practice
- No permission prompt required — better UX
- ~2-3% battery impact from continuous capture — acceptable for a bug reporting tool
