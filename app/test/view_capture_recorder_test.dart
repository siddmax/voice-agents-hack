import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/view_capture_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ViewCaptureRecorder (platform channel)', () {
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

    test('start is a no-op after warmUp', () async {
      await recorder.warmUp();
      final result = await recorder.start();
      expect(result, isTrue);
      expect(recorder.isRecording, isTrue);
      expect(log, ['warmUp']);
    });

    test('start primes capture when warmUp has not run yet', () async {
      final result = await recorder.start();
      expect(result, isTrue);
      expect(recorder.isRecording, isTrue);
      expect(recorder.isWarmed, isTrue);
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
      final path = await recorder.stop();
      expect(path, isNull);
      expect(recorder.lastError, contains('not ready'));
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
              throw PlatformException(
                code: 'FLUSH_ERROR',
                message: 'No frames',
              );
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

    test(
      'failed start priming still allows best-effort stop fallback',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              log.add(call.method);
              switch (call.method) {
                case 'warmUp':
                  return false;
                case 'flush':
                  return '/tmp/fallback.mp4';
                default:
                  return null;
              }
            });
        recorder = ViewCaptureRecorder();

        final started = await recorder.start();
        final path = await recorder.stop();

        expect(started, isTrue);
        expect(path, '/tmp/fallback.mp4');
        expect(log, ['warmUp', 'flush']);
      },
    );
  });

  group('FakeViewCaptureRecorder', () {
    test('is not warmed before warmUp', () {
      final recorder = FakeViewCaptureRecorder();
      expect(recorder.isWarmed, isFalse);
    });

    test('is warmed after warmUp', () async {
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
      final recorder = FakeViewCaptureRecorder()
        ..nextWarmUp = false
        ..nextPath = null;
      await recorder.start();
      expect(await recorder.stop(), isNull);
      expect(recorder.lastError, contains('initial frame'));
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
  });
}
