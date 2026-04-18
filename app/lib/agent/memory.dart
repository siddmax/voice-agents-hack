import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

const int kMaxFileBytes = 50 * 1024;

const List<String> _bootstrapFiles = [
  'AGENT.md',
  'INDEX.md',
  'identity/user.md',
  'preferences/general.md',
];

final List<RegExp> _secretPatterns = [
  RegExp(r'sk-[A-Za-z0-9]{16,}'),
  RegExp(r'Bearer [A-Za-z0-9_.\-]{20,}'),
  RegExp(r'-----BEGIN (?:RSA |EC |)PRIVATE KEY-----'),
  RegExp(r'AKIA[0-9A-Z]{16}'),
];

class MemoryException implements Exception {
  final String message;
  MemoryException(this.message);
  @override
  String toString() => 'MemoryException: $message';
}

/// MemoryVault is a hierarchical markdown tree rooted at `<docs>/memory/`.
/// The legacy class name `Memory` is preserved for callers; internals changed.
class Memory {
  final Directory root;

  Memory._(this.root);

  static Future<Memory> open({
    Directory? dir,
    Future<String> Function(String)? loadBootstrap,
  }) async {
    final base = dir ?? await getApplicationDocumentsDirectory();
    final root = Directory('${base.path}/memory');
    final legacy = File('${base.path}/memory.md');
    final vault = Memory._(root);

    if (!await root.exists()) {
      await root.create(recursive: true);
      await vault._bootstrap(loadBootstrap);
    }
    if (await legacy.exists()) {
      await vault._migrateLegacy(legacy);
    }
    await vault.rewriteIndex();
    return vault;
  }

  Future<void> _bootstrap(Future<String> Function(String)? loader) async {
    final load = loader ?? _defaultAssetLoader;
    for (final path in _bootstrapFiles) {
      final f = File('${root.path}/$path');
      if (await f.exists()) continue;
      try {
        final content = await load(path);
        await f.parent.create(recursive: true);
        await _atomicWrite(f, content);
      } catch (_) {
        // Missing asset is acceptable in tests; skip.
      }
    }
  }

  static Future<String> _defaultAssetLoader(String path) =>
      rootBundle.loadString('assets/memory_bootstrap/$path');

  Future<void> _migrateLegacy(File legacy) async {
    final target = File('${root.path}/Notes.md');
    if (!await target.exists()) {
      final content = await legacy.readAsString();
      await _atomicWrite(target, content);
    }
    await legacy.delete();
  }

  // ---- path safety ----

  File resolveSafe(String path) {
    if (path.isEmpty) {
      throw MemoryException('path is empty');
    }
    if (path.contains('\u0000')) {
      throw MemoryException('path contains null byte');
    }
    if (path.startsWith('/')) {
      throw MemoryException('path must be relative');
    }
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.any((s) => s == '..' || s == '.')) {
      throw MemoryException('path traversal not allowed');
    }
    final normalized = segments.map((s) {
      final isLast = s == segments.last;
      return isLast ? _normalizeFilename(s) : _slug(s);
    }).join('/');
    final full = '${root.path}/$normalized';
    final rootPath = root.absolute.path;
    final target = File(full).absolute.path;
    if (!target.startsWith(rootPath)) {
      throw MemoryException('path escapes root');
    }
    return File(full);
  }

  String _normalizeFilename(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return _slug(name);
    final base = name.substring(0, dot);
    final ext = name.substring(dot + 1);
    // Preserve well-known uppercase stems so INDEX.md / AGENT.md round-trip.
    if (base == base.toUpperCase() && RegExp(r'^[A-Z0-9_]+$').hasMatch(base)) {
      return '$base.${_slug(ext)}';
    }
    return '${_slug(base)}.${_slug(ext)}';
  }

  static String _slug(String s) {
    final ascii = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return ascii.isEmpty ? 'untitled' : ascii;
  }

  // ---- validations ----

  void _scanSecrets(String content) {
    for (final re in _secretPatterns) {
      if (re.hasMatch(content)) {
        throw MemoryException('content rejected: matches secret pattern');
      }
    }
  }

  void _checkSize(int bytes) {
    if (bytes > kMaxFileBytes) {
      throw MemoryException('file exceeds 50KB cap ($bytes bytes)');
    }
  }

  // ---- atomic IO ----

  Future<void> _atomicWrite(File f, String content) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  // ---- tool operations ----

  Future<String> view(String path, {List<int>? viewRange}) async {
    final f = resolveSafe(path);
    if (await FileSystemEntity.isDirectory(f.path)) {
      throw MemoryException('path is a directory');
    }
    if (!await f.exists()) {
      throw MemoryException('file not found: $path');
    }
    final content = await f.readAsString();
    if (viewRange == null) return content;
    if (viewRange.length != 2) {
      throw MemoryException('view_range must be [start, end]');
    }
    final lines = content.split('\n');
    final start = (viewRange[0] - 1).clamp(0, lines.length);
    final end = viewRange[1].clamp(start, lines.length);
    return lines.sublist(start, end).join('\n');
  }

  Future<void> create(String path, String content) async {
    final f = resolveSafe(path);
    if (await f.exists()) {
      throw MemoryException('file already exists: $path');
    }
    _scanSecrets(content);
    _checkSize(content.length);
    await _atomicWrite(f, content);
    await rewriteIndex();
  }

  Future<void> append(String path, String content) async {
    final f = resolveSafe(path);
    final existing = await f.exists() ? await f.readAsString() : '';
    final sep = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    final combined = '$existing$sep$content${content.endsWith('\n') ? '' : '\n'}';
    _scanSecrets(combined);
    _checkSize(combined.length);
    final existed = await f.exists();
    await _atomicWrite(f, combined);
    if (!existed) await rewriteIndex();
  }

  Future<void> strReplace(String path, String oldStr, String newStr) async {
    final f = resolveSafe(path);
    if (!await f.exists()) {
      throw MemoryException('file not found: $path');
    }
    final content = await f.readAsString();
    final first = content.indexOf(oldStr);
    if (first < 0) throw MemoryException('old_str not found');
    final second = content.indexOf(oldStr, first + 1);
    if (second >= 0) throw MemoryException('old_str not unique');
    final replaced = content.replaceFirst(oldStr, newStr);
    _scanSecrets(replaced);
    _checkSize(replaced.length);
    await _atomicWrite(f, replaced);
  }

  Future<void> delete(String path) async {
    final f = resolveSafe(path);
    if (await FileSystemEntity.isDirectory(f.path)) {
      throw MemoryException('cannot delete directory');
    }
    if (!await f.exists()) {
      throw MemoryException('file not found: $path');
    }
    final name = f.uri.pathSegments.last;
    if (name == 'AGENT.md') {
      throw MemoryException('AGENT.md is read-only');
    }
    await f.delete();
    await rewriteIndex();
  }

  Future<List<Map<String, dynamic>>> search(String query, {String? path}) async {
    final lower = query.toLowerCase();
    final results = <Map<String, dynamic>>[];
    final scope = path == null ? root : Directory(resolveSafe(path).path);
    if (!await scope.exists()) return results;
    await for (final e in scope.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        final content = await e.readAsString();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].toLowerCase().contains(lower)) {
            final rel = e.path.substring(root.path.length + 1);
            results.add({
              'path': rel,
              'line': i + 1,
              'preview': lines[i].trim(),
            });
          }
        }
      } catch (_) {}
    }
    return results;
  }

  // ---- INDEX.md maintenance ----

  Future<void> rewriteIndex() async {
    final index = File('${root.path}/INDEX.md');
    final entries = <String>[];
    if (await root.exists()) {
      final children = await root.list(followLinks: false).toList();
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final e in children) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name == 'INDEX.md') continue;
        if (e is File) {
          final summary = await _inferSummary(e);
          entries.add('- $name — $summary');
        } else if (e is Directory) {
          final count = await e
              .list(recursive: true, followLinks: false)
              .where((x) => x is File)
              .length;
          entries.add('- $name/ — ($count files)');
        }
      }
    }
    final body = '# Memory Index\n\n${entries.join('\n')}\n';
    await _atomicWrite(index, body);
  }

  Future<String> _inferSummary(File f) async {
    try {
      final lines = (await f.readAsString()).split('\n');
      for (final l in lines) {
        final t = l.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('#')) continue;
        return t.length > 80 ? '${t.substring(0, 80)}...' : t;
      }
    } catch (_) {}
    return '(empty)';
  }

  // ---- prompt injection ----

  /// Returns the content injected into the system prompt every turn:
  /// AGENT.md + INDEX.md + identity/user.md + preferences/general.md.
  Future<String> readInjected() async {
    final buf = StringBuffer();
    for (final path in ['AGENT.md', 'INDEX.md', 'identity/user.md', 'preferences/general.md']) {
      final f = File('${root.path}/$path');
      if (await f.exists()) {
        buf.writeln('### $path');
        buf.writeln(await f.readAsString());
        buf.writeln();
      }
    }
    return buf.toString();
  }

  /// Synchronous cached version used by PromptAssembler's `readMemory`
  /// callback. Cache is refreshed via [refreshInjectedCache].
  String _injectedCache = '';
  String readAll() => _injectedCache;

  Future<void> refreshInjectedCache() async {
    _injectedCache = await readInjected();
  }
}
