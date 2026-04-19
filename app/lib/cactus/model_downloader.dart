import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

import 'model_tier.dart';

sealed class DownloadEvent {
  const DownloadEvent();
}

class DownloadProgress extends DownloadEvent {
  final int bytesReceived;
  final int totalBytes;
  const DownloadProgress(this.bytesReceived, this.totalBytes);

  double get fraction => totalBytes == 0 ? 0 : bytesReceived / totalBytes;
}

class DownloadVerifying extends DownloadEvent {
  const DownloadVerifying();
}

class DownloadExtracting extends DownloadEvent {
  const DownloadExtracting();
}

class DownloadDone extends DownloadEvent {
  final String modelPath;
  const DownloadDone(this.modelPath);
}

class DownloadFailed extends DownloadEvent {
  final String reason;
  const DownloadFailed(this.reason);
}

class ModelDownloader {
  static const _e2bUrl =
      'https://huggingface.co/Cactus-Compute/gemma-4-E2B-it/resolve/main/weights/gemma-4-e2b-it-int4-apple.zip';
  static const _e4bUrl =
      'https://huggingface.co/Cactus-Compute/gemma-4-E4B-it/resolve/main/weights/gemma-4-e4b-it-int4-apple.zip';

  static const _e2bZipSize = 4679429616; // bytes, from HuggingFace
  static const _e4bZipSize = 8500000000; // approximate

  static String urlForTier(ModelTier tier) =>
      tier == ModelTier.e4b ? _e4bUrl : _e2bUrl;

  static String dirNameForTier(ModelTier tier) =>
      'gemma-4-${tier == ModelTier.e4b ? 'e4b' : 'e2b'}-it';

  static int expectedZipSize(ModelTier tier) =>
      tier == ModelTier.e4b ? _e4bZipSize : _e2bZipSize;

  static Future<String?> existingModelPath({
    required ModelTier tier,
    required Directory destination,
  }) async {
    final dir = Directory('${destination.path}/${dirNameForTier(tier)}');
    if (!await dir.exists()) return null;
    final hasContent = await dir.list().any((_) => true);
    return hasContent ? dir.path : null;
  }

  /// Checks available disk space. Returns null if check fails.
  static Future<int?> _availableDiskBytes(String path) async {
    try {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) return null;
      // dart:io doesn't expose statvfs; use 'df' on Apple/Linux.
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).split('\n');
      if (lines.length < 2) return null;
      final parts = lines[1].split(RegExp(r'\s+'));
      if (parts.length < 4) return null;
      final availKb = int.tryParse(parts[3]);
      return availKb == null ? null : availKb * 1024;
    } catch (_) {
      return null;
    }
  }

  Stream<DownloadEvent> download({
    required ModelTier tier,
    required Directory destination,
    http.Client? client,
  }) async* {
    final ownedClient = client == null;
    final httpClient = client ?? http.Client();

    final tierName = tier == ModelTier.e4b ? 'e4b' : 'e2b';
    final targetDir =
        Directory('${destination.path}/${dirNameForTier(tier)}');
    final tmpZip = File('${destination.path}/.tmp-$tierName.zip');
    final tmpExtractDir =
        Directory('${destination.path}/.tmp-$tierName');

    final existing =
        await existingModelPath(tier: tier, destination: destination);
    if (existing != null) {
      yield DownloadDone(existing);
      if (ownedClient) httpClient.close();
      return;
    }

    try {
      await destination.create(recursive: true);

      // ---- Disk space check ----
      final needed = expectedZipSize(tier) * 2.2; // zip + extracted + margin
      final available = await _availableDiskBytes(destination.path);
      if (available != null && available < needed) {
        final needGb = (needed / (1024 * 1024 * 1024)).toStringAsFixed(1);
        final haveGb = (available / (1024 * 1024 * 1024)).toStringAsFixed(1);
        throw StateError(
            'Not enough disk space: need ~${needGb}GB, only ${haveGb}GB available');
      }

      if (await tmpExtractDir.exists()) {
        await tmpExtractDir.delete(recursive: true);
      }

      // ---- Download phase (resumable) ----
      int startByte = 0;
      final tmpZipExists = await tmpZip.exists();
      if (tmpZipExists) {
        startByte = await tmpZip.length();
      }

      final url = urlForTier(tier);

      int? remoteSize;
      try {
        final headResp =
            await httpClient.send(http.Request('HEAD', Uri.parse(url)));
        await headResp.stream.drain<void>();
        remoteSize = headResp.contentLength;
      } catch (_) {}

      final alreadyComplete =
          tmpZipExists && remoteSize != null && startByte >= remoteSize;

      if (!alreadyComplete) {
        final req = http.Request('GET', Uri.parse(url));
        if (startByte > 0) {
          req.headers['Range'] = 'bytes=$startByte-';
        }

        var resp = await httpClient.send(req);

        if (resp.statusCode == 416 && startByte > 0) {
          await resp.stream.drain<void>();
          await tmpZip.delete();
          startByte = 0;
          final retryReq = http.Request('GET', Uri.parse(url));
          resp = await httpClient.send(retryReq);
        }

        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw HttpException(
              'Unexpected status ${resp.statusCode} for $url');
        }

        int totalBytes = 0;
        final contentRange = resp.headers['content-range'];
        if (resp.statusCode == 206 && contentRange != null) {
          final slash = contentRange.lastIndexOf('/');
          if (slash >= 0) {
            totalBytes =
                int.tryParse(contentRange.substring(slash + 1)) ?? 0;
          }
        } else {
          totalBytes = resp.contentLength ?? 0;
          if (startByte > 0 && resp.statusCode == 200) {
            await tmpZip.writeAsBytes(const <int>[], flush: true);
            startByte = 0;
          }
        }

        final sink = tmpZip.openWrite(
          mode: startByte > 0 ? FileMode.append : FileMode.write,
        );

        var received = startByte;
        DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
        yield DownloadProgress(received, totalBytes);

        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastEmit).inMilliseconds >= 250) {
            lastEmit = now;
            yield DownloadProgress(received, totalBytes);
          }
        }
        await sink.flush();
        await sink.close();

        yield DownloadProgress(
            received, totalBytes == 0 ? received : totalBytes);
      }

      // ---- Verify ----
      yield const DownloadVerifying();
      final zipSize = await tmpZip.length();
      final expectedSize = remoteSize ?? 0;
      if (expectedSize > 0 && zipSize != expectedSize) {
        throw StateError(
            'Downloaded zip size $zipSize != expected $expectedSize');
      }

      // ---- Extract in background isolate ----
      yield const DownloadExtracting();
      await tmpExtractDir.create(recursive: true);
      await Isolate.run(() {
        extractFileToDisk(tmpZip.path, tmpExtractDir.path);
      });

      // ---- Atomic rename ----
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await tmpExtractDir.rename(targetDir.path);

      if (await tmpZip.exists()) {
        await tmpZip.delete();
      }

      // Exclude from iCloud backup on iOS/macOS.
      try {
        await Process.run('setxattr', [
          '-w',
          'com.apple.MobileBackup',
          '1',
          targetDir.path,
        ]);
      } catch (_) {}

      yield DownloadDone(targetDir.path);
    } catch (e) {
      try {
        if (await tmpExtractDir.exists()) {
          await tmpExtractDir.delete(recursive: true);
        }
      } catch (_) {}
      if (e is StateError || e is ArchiveException) {
        try {
          if (await tmpZip.exists()) await tmpZip.delete();
        } catch (_) {}
      }
      yield DownloadFailed(e.toString());
    } finally {
      if (ownedClient) httpClient.close();
    }
  }
}
