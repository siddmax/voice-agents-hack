import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mcp_config.dart';

class McpServerStore extends ChangeNotifier {
  static const _prefsKey = 'mcp.servers';

  final List<McpServerConfig> _servers = [];
  bool _loaded = false;

  List<McpServerConfig> get servers => List.unmodifiable(_servers);
  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _servers.clear();
    if (raw == null) {
      _servers.add(_linearExample());
      await _persist(prefs);
    } else {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final e in decoded) {
          _servers.add(McpServerConfig.fromJson(e as Map<String, dynamic>));
        }
      } catch (err) {
        debugPrint('McpServerStore: failed to decode, resetting. $err');
        _servers.add(_linearExample());
        await _persist(prefs);
      }
    }
    _loaded = true;
    notifyListeners();
  }

  McpServerConfig? byId(String id) {
    for (final s in _servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> add(McpServerConfig cfg) async {
    _servers.add(cfg);
    await _save();
  }

  Future<void> update(McpServerConfig cfg) async {
    final i = _servers.indexWhere((s) => s.id == cfg.id);
    if (i == -1) return;
    _servers[i] = cfg;
    await _save();
  }

  Future<void> delete(String id) async {
    _servers.removeWhere((s) => s.id == id);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
    notifyListeners();
  }

  Future<void> _persist(SharedPreferences prefs) async {
    final encoded = jsonEncode(_servers.map((s) => s.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  static McpServerConfig _linearExample() => const McpServerConfig(
        id: 'linear-example',
        name: 'Linear',
        url: 'https://mcp.linear.app/sse',
        bearerToken: '',
        enabled: false,
      );
}
