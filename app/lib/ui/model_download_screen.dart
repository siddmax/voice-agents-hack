import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../cactus/model_downloader.dart';
import '../cactus/model_tier.dart';

/// First-launch screen that downloads the Gemma 4 weights for the detected
/// [ModelTier]. On completion it pushes the main app screen (currently a
/// Placeholder — Track J will wire in JarvisScreen at integration).
class ModelDownloadScreen extends StatefulWidget {
  final ModelTier tier;
  final Directory destination;

  /// Called when the download finishes; receives the extracted model path.
  /// Parent can rebuild the app with a real agent factory.
  final ValueChanged<String>? onReady;

  /// Injection seam for tests.
  final ModelDownloader? downloader;

  const ModelDownloadScreen({
    super.key,
    required this.tier,
    required this.destination,
    this.onReady,
    this.downloader,
  });

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  StreamSubscription<DownloadEvent>? _sub;

  int _bytesReceived = 0;
  int _totalBytes = 0;
  bool _extracting = false;
  bool _verifying = false;
  bool _cancelled = false;
  String? _error;
  String? _donePath;

  DateTime? _lastProgressAt;
  int _lastProgressBytes = 0;
  double _bytesPerSec = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _start() {
    _sub?.cancel();
    setState(() {
      _bytesReceived = 0;
      _totalBytes = 0;
      _extracting = false;
      _verifying = false;
      _cancelled = false;
      _error = null;
      _donePath = null;
      _bytesPerSec = 0;
      _lastProgressAt = null;
      _lastProgressBytes = 0;
    });
    final dl = widget.downloader ?? ModelDownloader();
    _sub = dl
        .download(tier: widget.tier, destination: widget.destination)
        .listen(_onEvent, onError: (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    });
  }

  void _onEvent(DownloadEvent ev) {
    if (!mounted) return;
    switch (ev) {
      case DownloadProgress(:final bytesReceived, :final totalBytes):
        final now = DateTime.now();
        if (_lastProgressAt != null) {
          final dt = now.difference(_lastProgressAt!).inMilliseconds;
          if (dt > 0) {
            final dBytes = bytesReceived - _lastProgressBytes;
            _bytesPerSec = (dBytes * 1000) / dt;
          }
        }
        _lastProgressAt = now;
        _lastProgressBytes = bytesReceived;
        setState(() {
          _bytesReceived = bytesReceived;
          _totalBytes = totalBytes;
          _verifying = false;
          _extracting = false;
        });
      case DownloadVerifying():
        setState(() {
          _verifying = true;
          _extracting = false;
        });
      case DownloadExtracting():
        setState(() {
          _extracting = true;
          _verifying = false;
        });
      case DownloadDone(:final modelPath):
        setState(() => _donePath = modelPath);
        widget.onReady?.call(modelPath);
      case DownloadFailed(:final reason):
        setState(() => _error = reason);
    }
  }

  void _cancel() {
    _sub?.cancel();
    setState(() => _cancelled = true);
  }

  String _fmtMb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  String _fmtEta() {
    if (_bytesPerSec <= 0 || _totalBytes <= 0) return '—';
    final remaining = _totalBytes - _bytesReceived;
    if (remaining <= 0) return '0s';
    final secs = (remaining / _bytesPerSec).round();
    if (secs < 60) return '${secs}s';
    final m = secs ~/ 60;
    final s = secs % 60;
    return '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final tierLabel = widget.tier == ModelTier.e4b ? 'E4B' : 'E2B';
    final sizeHint = widget.tier == ModelTier.e4b ? '~2.5 GB' : '~1.5 GB';
    final theme = Theme.of(context);

    Widget body;
    if (_error != null) {
      body = _RetryState(
        title: 'Download failed',
        message: _error!,
        onRetry: _start,
      );
    } else if (_cancelled) {
      body = _RetryState(
        title: 'Cancelled',
        message: 'Tap to retry.',
        onRetry: _start,
      );
    } else if (_donePath != null) {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline, size: 72),
          const SizedBox(height: 16),
          Text('Model ready', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(_donePath!, style: theme.textTheme.bodySmall),
        ],
      );
    } else if (_extracting || _verifying) {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _extracting ? 'Verifying & extracting' : 'Verifying',
            style: theme.textTheme.titleMedium,
          ),
        ],
      );
    } else {
      final fraction = _totalBytes > 0 ? _bytesReceived / _totalBytes : null;
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Syndai',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Setting up Syndai',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 32),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 16),
            Text(
              'Downloading Gemma 4 $tierLabel · '
              '${_fmtMb(_bytesReceived)} MB / '
              '${_totalBytes > 0 ? _fmtMb(_totalBytes) : sizeHint} · '
              '${(_bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s · '
              'ETA ${_fmtEta()}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _cancel,
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(child: Center(child: body)),
    );
  }
}

class _RetryState extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _RetryState({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              size: 64, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
