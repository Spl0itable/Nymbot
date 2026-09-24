import 'dart:convert';

class ConnectorTool {
  ConnectorTool({
    required this.name,
    this.description = '',
    this.confirm = true,
    this.readOnly = false,
    this.destructive = false,
    this.enabled = true,
  });

  final String name;
  final String description;
  final bool confirm;
  final bool readOnly;
  final bool destructive;
  bool enabled;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'confirm': confirm,
        'readOnly': readOnly,
        'destructive': destructive,
        'enabled': enabled,
      };

  static ConnectorTool fromJson(Map<String, dynamic> j) => ConnectorTool(
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        confirm: j['confirm'] != false,
        readOnly: j['readOnly'] == true,
        destructive: j['destructive'] == true,
        enabled: j['enabled'] != false,
      );
}

class McpConnector {
  McpConnector({
    required this.id,
    required this.name,
    required this.url,
    this.auth = 'none',
    this.token = '',
    this.headerName = '',
    this.headerValue = '',
    this.enabled = true,
    this.tools,
    this.secretElsewhere = false,
    this.secretAt = 0,
    this.allowAll = false,
    List<String>? allowed,
    int? updatedAt,
  })  : allowed = allowed ?? [],
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  String name;
  String url;
  String auth;
  String token;
  String headerName;
  String headerValue;
  bool enabled;
  List<ConnectorTool>? tools;
  bool secretElsewhere;
  int secretAt;
  bool allowAll;
  List<String> allowed;
  int updatedAt;

  static const allowedMax = 500;

  bool alwaysAllows(String tool) => allowAll || allowed.contains(tool);

  void trust(String tool) {
    if (allowAll || tool.isEmpty || allowed.contains(tool)) return;
    allowed = [...allowed, tool];
  }

  static const maxPerChat = 3;

  bool get usable {
    if (!enabled || url.isEmpty || secretElsewhere) return false;
    if (auth == 'bearer' && token.isEmpty) return false;
    if (auth == 'header' && (headerName.isEmpty || headerValue.isEmpty)) return false;
    return true;
  }

  static String publicUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !u.hasScheme) return '';
    return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}${u.path}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'auth': auth,
        'token': token,
        'headerName': headerName,
        'headerValue': headerValue,
        'enabled': enabled,
        if (tools != null) 'tools': tools!.map((t) => t.toJson()).toList(),
        if (secretElsewhere) 'secretElsewhere': true,
        if (secretAt > 0) 'secretAt': secretAt,
        if (allowAll)
          'autoAllow': true
        else if (allowed.isNotEmpty)
          'autoAllow': allowed,
        'updatedAt': updatedAt,
      };

  static const secretFields = ['token', 'headerValue'];
  static const secretBundle = ['url', 'token', 'headerValue'];

  bool sameSecrets(McpConnector other) =>
      url == other.url && token == other.token && headerValue == other.headerValue;

  Map<String, dynamic> toSyncJson() => {
        ...toJson(),
        'token': token,
        'headerValue': headerValue,
        'secretAt': secretAt,
        'tokenElsewhere': token.isNotEmpty || headerValue.isNotEmpty,
      };

  Map<String, dynamic> toPayload() {
    final out = <String, dynamic>{'id': id, 'name': name, 'url': url};
    if (auth == 'bearer' && token.isNotEmpty) out['token'] = token;
    if (auth == 'header' && headerName.isNotEmpty && headerValue.isNotEmpty) {
      out['headers'] = {headerName: headerValue};
    }
    final list = tools;
    if (list != null && list.isNotEmpty && list.any((t) => !t.enabled)) {
      out['tools'] = [for (final t in list) if (t.enabled) t.name];
    }
    if (allowAll) {
      out['autoAllow'] = true;
    } else if (allowed.isNotEmpty) {
      out['autoAllow'] = allowed.take(allowedMax).toList();
    }
    return out;
  }

  static McpConnector fromJson(Map<String, dynamic> j) => McpConnector(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        auth: j['auth'] as String? ?? 'none',
        token: j['token'] as String? ?? '',
        headerName: j['headerName'] as String? ?? '',
        headerValue: j['headerValue'] as String? ?? '',
        enabled: j['enabled'] != false,
        tools: (j['tools'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ConnectorTool.fromJson)
            .toList(),
        secretElsewhere: j['secretElsewhere'] == true,
        secretAt: (j['secretAt'] as num?)?.toInt() ?? 0,
        allowAll: j['autoAllow'] == true,
        allowed: j['autoAllow'] is List
            ? [for (final name in j['autoAllow'] as List) '$name']
            : null,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  static String encodeList(List<McpConnector> list) =>
      jsonEncode(list.map((c) => c.toJson()).toList());

  static List<McpConnector> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(McpConnector.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
