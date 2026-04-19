import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:syndai/cactus/model_downloader.dart';
import 'package:syndai/cactus/model_tier.dart';

/// Tiny [http.BaseClient] whose `send` is controlled by a closure.
class _FakeClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest req) handler;
  _FakeClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

/// Build a minimal valid zip containing a few files.
List<int> _buildZip() {
  final archive = Archive();
  archive.addFile(
      ArchiveFile('config.txt', 11, utf8.encode('hello world')));
  archive.addFile(
      ArchiveFile('weights.bin', 8, List<int>.generate(8, (i) => i)));
  return ZipEncoder().encode(archive)!;
}

Stream<List<int>> _chunked(List<int> bytes, {int chunkSize = 32}) async* {
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, bytes.length);
    yield bytes.sublist(i, end);
    // Yield to the event loop so the progress debounce can fire.
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Directory> _tmpDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

void main() {
  group('ModelDownloader', () {
    test('emits progress → extracting → done and writes target dir',
        () async {
      final dir = await _tmpDir('mdl_ok_');
      final zipBytes = _buildZip();

      final client = _FakeClient((req) async {
        expect(req.url.toString(), contains('gemma-4-e2b-it'));
        if (req.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: zipBytes.length,
          );
        }
        return http.StreamedResponse(
          _chunked(zipBytes),
          200,
          contentLength: zipBytes.length,
        );
      });

      final events = <DownloadEvent>[];
      final targetDir =
          Directory('${dir.path}/${ModelDownloader.dirNameForTier(ModelTier.e2b)}');

      await for (final ev in ModelDownloader().download(
        tier: ModelTier.e2b,
        destination: dir,
        client: client,
      )) {
        events.add(ev);
        // Before DownloadDone fires, the target dir must not exist yet
        // (atomic rename).
        if (ev is! DownloadDone) {
          expect(await targetDir.exists(), isFalse,
              reason: 'target dir should not exist before DownloadDone');
        }
      }

      expect(events.whereType<DownloadProgress>().isNotEmpty, isTrue);
      expect(events.whereType<DownloadExtracting>().length, 1);
      expect(events.last, isA<DownloadDone>());

      final done = events.last as DownloadDone;
      expect(done.modelPath, targetDir.path);
      expect(await File('${targetDir.path}/config.txt').readAsString(),
          'hello world');
      // .tmp-*.zip cleaned up.
      expect(await File('${dir.path}/.tmp-e2b.zip').exists(), isFalse);
      expect(await Directory('${dir.path}/.tmp-e2b').exists(), isFalse);

      await dir.delete(recursive: true);
    });

    test('resumes from partial .tmp zip using Range: header', () async {
      final dir = await _tmpDir('mdl_resume_');
      final zipBytes = _buildZip();

      // Pre-seed the first N bytes into the tmp zip.
      final prefixLen = (zipBytes.length / 3).floor();
      final tmpZip = File('${dir.path}/.tmp-e2b.zip');
      await tmpZip.writeAsBytes(zipBytes.sublist(0, prefixLen));

      var sawRangeHeader = false;
      final client = _FakeClient((req) async {
        if (req.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: zipBytes.length,
          );
        }
        final rh = req.headers['Range'] ?? req.headers['range'];
        sawRangeHeader = rh != null && rh.startsWith('bytes=$prefixLen-');
        final rest = zipBytes.sublist(prefixLen);
        return http.StreamedResponse(
          _chunked(rest),
          206,
          contentLength: rest.length,
          headers: {
            'content-range':
                'bytes $prefixLen-${zipBytes.length - 1}/${zipBytes.length}',
          },
        );
      });

      final events = <DownloadEvent>[];
      await for (final ev in ModelDownloader().download(
        tier: ModelTier.e2b,
        destination: dir,
        client: client,
      )) {
        events.add(ev);
      }

      expect(sawRangeHeader, isTrue,
          reason: 'downloader must send Range header for partial zip');
      expect(events.last, isA<DownloadDone>());
      final targetDir = Directory(
          '${dir.path}/${ModelDownloader.dirNameForTier(ModelTier.e2b)}');
      expect(await File('${targetDir.path}/config.txt').readAsString(),
          'hello world');

      await dir.delete(recursive: true);
    });

    test('cleans up .tmp extract dir when the HTTP stream throws', () async {
      final dir = await _tmpDir('mdl_fail_');

      final client = _FakeClient((req) async {
        if (req.method == 'HEAD') {
          return http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: 9999,
          );
        }
        final ctl = StreamController<List<int>>();
        scheduleMicrotask(() {
          ctl.add(List<int>.filled(16, 0));
          ctl.addError(const SocketException('boom'));
          ctl.close();
        });
        return http.StreamedResponse(ctl.stream, 200, contentLength: 9999);
      });

      final events = <DownloadEvent>[];
      await for (final ev in ModelDownloader().download(
        tier: ModelTier.e2b,
        destination: dir,
        client: client,
      )) {
        events.add(ev);
      }

      expect(events.last, isA<DownloadFailed>());
      final targetDir = Directory(
          '${dir.path}/${ModelDownloader.dirNameForTier(ModelTier.e2b)}');
      expect(await targetDir.exists(), isFalse);
      expect(await Directory('${dir.path}/.tmp-e2b').exists(), isFalse);
      // On a transient failure we keep the partial zip for resume.
      // (It's fine if the file exists or doesn't — test both artefacts
      //  separately here.)

      await dir.delete(recursive: true);
    });

    test('existingModelPath returns path when directory is non-empty, '
        'else null', () async {
      final dir = await _tmpDir('mdl_exists_');

      expect(
        await ModelDownloader.existingModelPath(
          tier: ModelTier.e2b,
          destination: dir,
        ),
        isNull,
      );

      final target = Directory(
          '${dir.path}/${ModelDownloader.dirNameForTier(ModelTier.e2b)}');
      await target.create(recursive: true);
      // Empty directory is treated as missing.
      expect(
        await ModelDownloader.existingModelPath(
          tier: ModelTier.e2b,
          destination: dir,
        ),
        isNull,
      );

      await File('${target.path}/config.txt').writeAsString('x');
      expect(
        await ModelDownloader.existingModelPath(
          tier: ModelTier.e2b,
          destination: dir,
        ),
        target.path,
      );

      await dir.delete(recursive: true);
    });

    test('short-circuits to DownloadDone when model already installed',
        () async {
      final dir = await _tmpDir('mdl_short_');
      final target = Directory(
          '${dir.path}/${ModelDownloader.dirNameForTier(ModelTier.e4b)}');
      await target.create(recursive: true);
      await File('${target.path}/config.txt').writeAsString('x');

      var called = 0;
      final client = _FakeClient((req) async {
        called++;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
      });

      final events = await ModelDownloader()
          .download(
              tier: ModelTier.e4b, destination: dir, client: client)
          .toList();

      expect(called, 0, reason: 'no HTTP call expected on existing install');
      expect(events, hasLength(1));
      expect(events.single, isA<DownloadDone>());

      await dir.delete(recursive: true);
    });
  });
}
