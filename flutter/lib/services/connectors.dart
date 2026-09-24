import '../features/i18n/i18n.dart';
import '../models/connector.dart';
import 'account_sync.dart';
import 'chat_engine.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'server_runs.dart';

class Connectors {
  static String? checkUrl(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return t('That is not a valid URL.');
    if (u.scheme != 'https') return t('Connectors must use https.');
    if (u.userInfo.isNotEmpty) {
      return t('Put credentials in the token or header fields, not in the URL.');
    }
    final host = u.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        !host.contains('.') ||
        host.contains(':') ||
        RegExp(r'^(10|127|0)\.').hasMatch(host) ||
        RegExp(r'^192\.168\.').hasMatch(host) ||
        RegExp(r'^169\.254\.').hasMatch(host) ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) {
      return t('That address is local or private, and the worker cannot reach it.');
    }
    return null;
  }

  static String? formProblem(McpConnector c) {
    if (c.name.trim().isEmpty) return t('Give the connector a name.');
    final bad = checkUrl(c.url);
    if (bad != null) return bad;
    if (c.auth == 'bearer' && c.token.isEmpty) {
      return t('Paste the token, or pick no authentication.');
    }
    if (c.auth == 'header' &&
        (!RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(c.headerName) || c.headerValue.isEmpty)) {
      return t('A header needs a name (letters, digits and dashes) and a value.');
    }
    return null;
  }

  static List<McpConnector> forChat(List<McpConnector> all, List<String> ids) {
    final out = <McpConnector>[];
    for (final id in ids) {
      for (final c in all) {
        if (c.id == id && c.usable && !out.contains(c)) out.add(c);
      }
      if (out.length >= McpConnector.maxPerChat) break;
    }
    return out;
  }

  static List<McpConnector> keepSecrets(List<McpConnector> mine,
      List<Map<String, dynamic>> merged, List<Map<String, dynamic>> theirs) {
    final byId = {for (final c in mine) c.id: c.toJson()};
    final came = {
      for (final c in theirs)
        if (c['id'] is String) c['id'] as String: c
    };
    return [
      for (final c in merged)
        () {
          final id = c['id'] as String?;
          final held = byId[id];
          final heldRow =
              held != null && held['secretElsewhere'] == true ? {...held, 'url': ''} : held;
          final kept = AccountSync.pickSecret(heldRow, came[id], McpConnector.secretBundle,
              'secretAt', McpConnector.secretFields);
          final from = kept['from'] == 'theirs' ? came[id] : held;
          final copy = {...c};
          for (final f in McpConnector.secretFields) {
            final v = kept[f] as String;
            if (v.isNotEmpty) {
              copy[f] = v;
            } else {
              copy.remove(f);
            }
          }
          final at = kept['secretAt'] as int;
          if (at > 0) {
            copy['secretAt'] = at;
          } else {
            copy.remove('secretAt');
          }
          final url = from == null ? null : from['url'];
          if (url is String && url.isNotEmpty) {
            copy['url'] = url;
            if (from!['secretElsewhere'] == true) {
              copy['secretElsewhere'] = true;
            } else {
              copy.remove('secretElsewhere');
            }
          }
          return McpConnector.fromJson(copy);
        }()
    ];
  }

  static Future<List<ConnectorTool>> probe(
      NymbotApi api, EventSigner signer, McpConnector c,
      {List<ConnectorTool>? before}) async {
    final payload = c.toPayload()..remove('tools');
    final res = await api.call('mcp-probe', signer,
        extra: {'server': payload}, timeout: const Duration(seconds: 45));
    final data = res.data;
    if (res.status >= 400 || data['error'] != null || data['ok'] != true) {
      throw ChatFailure((data['error'] as String?) ?? t('The connector could not be reached.'));
    }
    final was = {for (final tool in before ?? const <ConnectorTool>[]) tool.name: tool.enabled};
    return [
      for (final raw in (data['tools'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ConnectorTool(
          name: raw['name'] as String? ?? '',
          description: raw['description'] as String? ?? '',
          confirm: raw['confirm'] == true,
          readOnly: raw['readOnly'] == true,
          destructive: raw['destructive'] == true,
          enabled: was[raw['name']] ?? true,
        )
    ];
  }

  static const argsKept = 20000;

  static McpConnector? connectorFor(List<McpConnector> all, Map<String, dynamic>? p) {
    if (p == null) return null;
    final id = '${p['connectorId'] ?? ''}';
    if (id.isNotEmpty) {
      for (final c in all) {
        if (c.id == id) return c;
      }
    }
    final name = '${p['connector'] ?? ''}';
    if (name.isEmpty) return null;
    final named = all.where((c) => c.name == name).toList();
    return named.length == 1 ? named.single : null;
  }

  static Map<String, dynamic>? pendingFrom(Map<String, dynamic> data) {
    final p = data['pendingTool'];
    final token = data['resumeToken'];
    if (p is! Map || token is! String || token.isEmpty) return null;
    if (p['kind'] == 'server-run') return ServerRuns.pendingFrom(p, token);
    final raw = '${p['args'] ?? '{}'}';
    final args = raw.length > argsKept ? raw.substring(0, argsKept) : raw;
    final length = p['argsLength'];
    return {
      'kind': 'mcp',
      'id': '${p['id'] ?? ''}',
      'tool': '${p['tool'] ?? ''}',
      'connector': '${p['connector'] ?? ''}',
      'connectorId': '${p['connectorId'] ?? ''}',
      'args': args,
      'argsLength': length is num && length > 0 ? length.floor() : raw.length,
      'destructive': p['destructive'] == true,
      if (p['team'] == true) 'team': true,
      'token': token,
      'state': 'waiting',
    };
  }

  static TurnStep? step(Map<String, dynamic> s) {
    final connector = s['connector'];
    if (connector is! String || connector.isEmpty) return null;
    final kind = s['kind'] == 'tool' ? 'connector-tool' : 'connector';
    final tool = '${s['tool'] ?? ''}';
    final target = '${s['target'] ?? ''}';
    return (
      n: (s['n'] as num?)?.toInt() ?? 0,
      kind: kind,
      text: kind == 'connector-tool' && target.isNotEmpty ? '$tool — $target' : tool,
      tool: connector,
      call: 0,
      of: 0,
      flag: false,
    );
  }

  static String progressLine(TurnStep step) {
    if (step.kind == 'connector') {
      return t('Connecting to {connector}', {'connector': step.tool});
    }
    return t('{connector}: {tool}', {'connector': step.tool, 'tool': step.text});
  }
}
