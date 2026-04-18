// Shared data model for user-configured MCP servers. Lane B persists these
// from the settings screen, Lane C reads them to build the tool registry.

class McpServerConfig {
  final String id;
  final String name;
  final String url;
  final String? bearerToken;
  final Map<String, String> extraHeaders;
  final bool enabled;

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.bearerToken,
    this.extraHeaders = const {},
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'bearerToken': bearerToken,
        'extraHeaders': extraHeaders,
        'enabled': enabled,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        bearerToken: j['bearerToken'] as String?,
        extraHeaders:
            Map<String, String>.from(j['extraHeaders'] as Map? ?? const {}),
        enabled: j['enabled'] as bool? ?? true,
      );
}
