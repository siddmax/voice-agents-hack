import 'dart:io';

import 'package:path_provider/path_provider.dart';

const _stub = '''# Syndai memory

## Identity

## Preferences

## Notes
''';

class Memory {
  final File _file;
  String _cache;

  Memory._(this._file, this._cache);

  static Future<Memory> open({Directory? dir}) async {
    final d = dir ?? await getApplicationDocumentsDirectory();
    final f = File('${d.path}/memory.md');
    if (!await f.exists()) {
      await f.writeAsString(_stub);
    }
    final contents = await f.readAsString();
    return Memory._(f, contents);
  }

  String readAll() => _cache;

  Future<void> append(String section, String content) async {
    final header = '## $section';
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    final lines = _cache.split('\n');
    final idx = lines.indexWhere((l) => l.trim() == header);
    if (idx == -1) {
      _cache =
          '${_cache.trimRight()}\n\n$header\n$trimmed\n';
    } else {
      // Insert right after the header and any immediately following blank line.
      var insertAt = idx + 1;
      if (insertAt < lines.length && lines[insertAt].trim().isEmpty) {
        insertAt += 1;
      }
      lines.insert(insertAt, trimmed);
      _cache = lines.join('\n');
    }
    await _file.writeAsString(_cache);
  }
}
