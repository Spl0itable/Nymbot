import 'dart:convert';

import 'package:http/http.dart' as http;

/// One repository a token can reach, as the forge described it.
class ForgeRepo {
  const ForgeRepo({
    required this.repo,
    this.branch = '',
    this.private = false,
    this.description = '',
  });

  final String repo;
  final String branch;
  final bool private;
  final String description;
}

/// Why an attempt to list repositories failed, in terms a reader can act on.
enum ForgeFailure { noToken, noHost, unsupported, denied, unreachable, failed }

class ForgeException implements Exception {
  const ForgeException(this.reason);

  final ForgeFailure reason;

  @override
  String toString() => 'ForgeException(${reason.name})';
}

/// Asking a forge what a token can see, from the device that holds the token.
/// The request goes straight from here to the forge: the token is not sent to
/// the Nymbot worker, and never to a relay.
class GitForge {
  const GitForge._();

  static const supported = {'github', 'gitlab', 'gitea', 'codeberg', 'bitbucket'};

  /// Only a self-hosted forge has no default host worth guessing.
  static bool needsHost(String provider) => provider == 'gitea';

  static String _clean(String host) =>
      host.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');

  static Uri _url(String provider, String host) {
    switch (provider) {
      case 'github':
        final h = _clean(host.isEmpty ? 'github.com' : host);
        final base = h == 'github.com' ? 'https://api.github.com' : 'https://$h/api/v3';
        return Uri.parse('$base/user/repos?per_page=100&sort=updated'
            '&affiliation=owner,collaborator,organization_member');
      case 'gitlab':
        final h = _clean(host.isEmpty ? 'gitlab.com' : host);
        return Uri.parse('https://$h/api/v4/projects'
            '?membership=true&per_page=100&order_by=last_activity_at');
      case 'codeberg':
        final h = _clean(host.isEmpty ? 'codeberg.org' : host);
        return Uri.parse('https://$h/api/v1/user/repos?limit=100');
      case 'gitea':
        return Uri.parse('https://${_clean(host)}/api/v1/user/repos?limit=100');
      case 'bitbucket':
        return Uri.parse('https://api.bitbucket.org/2.0/repositories'
            '?role=member&pagelen=100&sort=-updated_on');
      default:
        throw const ForgeException(ForgeFailure.unsupported);
    }
  }

  static Map<String, String> _headers(String provider, String token) {
    switch (provider) {
      case 'github':
        return {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        };
      case 'gitlab':
        return {'PRIVATE-TOKEN': token};
      case 'bitbucket':
        return {'Authorization': 'Bearer $token'};
      default:
        return {'Authorization': 'token $token'};
    }
  }

  static List<ForgeRepo> parse(String provider, dynamic body) {
    List<dynamic> rows;
    if (provider == 'bitbucket') {
      rows = (body is Map && body['values'] is List) ? body['values'] as List : const [];
    } else {
      rows = body is List ? body : const [];
    }
    final out = <ForgeRepo>[];
    for (final row in rows) {
      if (row is! Map) continue;
      switch (provider) {
        case 'gitlab':
          final name = row['path_with_namespace'];
          if (name is! String || name.isEmpty) continue;
          out.add(ForgeRepo(
            repo: name,
            branch: (row['default_branch'] as String?) ?? '',
            private: row['visibility'] != 'public',
            description: (row['description'] as String?) ?? '',
          ));
        case 'bitbucket':
          final name = row['full_name'];
          if (name is! String || name.isEmpty) continue;
          final main = row['mainbranch'];
          out.add(ForgeRepo(
            repo: name,
            branch: main is Map ? (main['name'] as String?) ?? '' : '',
            private: row['is_private'] == true,
            description: (row['description'] as String?) ?? '',
          ));
        default:
          final name = row['full_name'];
          if (name is! String || name.isEmpty) continue;
          out.add(ForgeRepo(
            repo: name,
            branch: (row['default_branch'] as String?) ?? '',
            private: row['private'] == true,
            description: (row['description'] as String?) ?? '',
          ));
      }
    }
    out.sort((a, b) => a.repo.compareTo(b.repo));
    return out;
  }

  static Future<List<ForgeRepo>> listRepos({
    required String provider,
    required String token,
    String host = '',
    http.Client? client,
  }) async {
    if (!supported.contains(provider)) {
      throw const ForgeException(ForgeFailure.unsupported);
    }
    if (token.isEmpty) throw const ForgeException(ForgeFailure.noToken);
    if (needsHost(provider) && host.trim().isEmpty) {
      throw const ForgeException(ForgeFailure.noHost);
    }
    final http.Client c = client ?? http.Client();
    http.Response res;
    try {
      res = await c
          .get(_url(provider, host.trim()), headers: _headers(provider, token))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const ForgeException(ForgeFailure.unreachable);
    } finally {
      if (client == null) c.close();
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const ForgeException(ForgeFailure.denied);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw const ForgeException(ForgeFailure.failed);
    }
    try {
      return parse(provider, jsonDecode(res.body));
    } catch (_) {
      throw const ForgeException(ForgeFailure.failed);
    }
  }
}
