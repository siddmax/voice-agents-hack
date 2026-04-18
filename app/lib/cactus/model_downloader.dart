import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

import 'model_tier.dart';

/// Events emitted by [ModelDownloader.download].
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

/// Downloads Cactus-Compute's pre-converted Gemma 4 INT4 weights on first
/// launch into the app's documents directory.
///
/// URL pattern confirmed against `cactus/python/src/downloads.py`:
///   `https://huggingface.co/Cactus-Compute/<ModelId>/resolve/main/weights/<file>.zip`
///
/// The zip contains the weight files at the archive root. We atomically
/// extract into `<destination>/gemma-4-<tier>-it/` so interrupted downloads
/// don't leave a half-populated directory that would fool `existingModelPath`.
class ModelDownloader {
  /// HuggingFace zip URLs. `apple` variant is what the cactus CLI grabs first
  /// for macOS/iOS; it's also what we use for Android — the INT4 layout is the
  /// same. (If Android-specific builds show up later we can branch here.)
  static const _e2bUrl =
      'https://huggingface.co/Cactus-Compute/gemma-4-E2B-it/resolve/main/weights/gemma-4-e2b-it-int4-apple.zip';
  static const _e4bUrl =
      'https://huggingface.co/Cactus-Compute/gemma-4-E4B-it/resolve/main/weights/gemma-4-e4b-it-int4-apple.zip';

  static String urlForTier(ModelTier tier) =>
      tier == ModelTier.e4b ? _e4bUrl : _e2bUrl;

  /// Directory name used for the final extracted model.
  static String dirNameForTier(ModelTier tier) =>
      'gemma-4-${tier == ModelTier.e4b ? 'e4b' : 'e2b'}-it';

  /// Returns the on-disk model path for the given tier if it already exists
  /// and is non-empty, else null.
  static Future<String?> existingModelPath({
    required ModelTier tier,
    required Directory destination,
  }) async {
    final dir = Directory('${destination.path}/${dirNameForTier(tier)}');
    if (!await dir.exists()) return null;
    final hasContent = await dir.list().any((_) => true);
    return hasContent ? dir.path : null;
  }

  /// Stream the download/verify/extract lifecycle for [tier], materialising
  /// the model in [destination]. Supports resumption via HTTP `Range:` if
  /// a partial `.tmp-<tier>.zip` exists from a previous run.
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

    // Fast path: already installed.
    final existing =
        await existingModelPath(tier: tier, destination: destination);
    if (existing != null) {
      yield DownloadDone(existing);
      if (ownedClient) httpClient.close();
      return;
    }

    try {
      await destination.create(recursive: true);
      if (await tmpExtractDir.exists()) {
        await tmpExtractDir.delete(recursive: true);
      }

      // ---- Download phase (resumable) ----
      int startByte = 0;
      if (await tmpZip.exists()) {
        startByte = await tmpZip.length();
      }

      final url = urlForTier(tier);
      final req = http.Request('GET', Uri.parse(url));
      if (startByte > 0) {
        req.headers['Range'] = 'bytes=$startByte-';
      }

      final resp = await httpClient.send(req);

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException(
            'Unexpected status ${resp.statusCode} for $url');
      }

      // Compute total bytes: if resumed (206), Content-Range tells us the
      // complete size; otherwise Content-Length is the total.
      int totalBytes = 0;
      final contentRange = resp.headers['content-range'];
      if (resp.statusCode == 206 && contentRange != null) {
        final slash = contentRange.lastIndexOf('/');
        if (slash >= 0) {
          totalBytes = int.tryParse(contentRange.substring(slash + 1)) ?? 0;
        }
      } else {
        totalBytes = resp.contentLength ?? 0;
        if (startByte > 0 && resp.statusCode == 200) {
          // Server ignored our Range header — restart from scratch.
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

      yield DownloadProgress(received, totalBytes == 0 ? received : totalBytes);

      // ---- Verify + Extract phase ----
      yield const DownloadVerifying();
      // (Hash verification is a v2 item per plan; we only check size here.)
      final zipSize = await tmpZip.length();
      if (totalBytes > 0 && zipSize != totalBytes) {
        throw StateError(
            'Downloaded zip size $zipSize != expected $totalBytes');
      }

      yield const DownloadExtracting();
      await tmpExtractDir.create(recursive: true);
      final inputStream = InputFileStream(tmpZip.path);
      try {
        final archive = ZipDecoder().decodeBuffer(inputStream);
        for (final entry in archive.files) {
          final outPath = '${tmpExtractDir.path}/${entry.name}';
          if (entry.isFile) {
            final f = File(outPath);
            await f.parent.create(recursive: true);
            final out = OutputFileStream(outPath);
            try {
              entry.writeContent(out);
            } finally {
              await out.close();
            }
          } else {
            await Directory(outPath).create(recursive: true);
          }
        }
      } finally {
        await inputStream.close();
      }

      // ---- Atomic rename ----
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await tmpExtractDir.rename(targetDir.path);

      if (await tmpZip.exists()) {
        await tmpZip.delete();
      }

      yield DownloadDone(targetDir.path);
    } catch (e) {
      // Cleanup partial extract; keep the .tmp-*.zip around so a retry can
      // resume via Range. (If the zip itself is corrupt, delete it too.)
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
