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

class ForgeTree {
  const ForgeTree({
    required this.branch,
    required this.paths,
    this.partial = false,
  });

  final String branch;
  final List<String> paths;
  final bool partial;
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

  static const _treePageMax = 10;
  static const _treePageSize = 100;

  static String _apiBase(String provider, String host) {
    switch (provider) {
      case 'github':
        final h = _clean(host.isEmpty ? 'github.com' : host);
        return h == 'github.com' ? 'https://api.github.com' : 'https://$h/api/v3';
      case 'gitlab':
        return 'https://${_clean(host.isEmpty ? 'gitlab.com' : host)}/api/v4';
      case 'codeberg':
        return 'https://${_clean(host.isEmpty ? 'codeberg.org' : host)}/api/v1';
      case 'gitea':
        return 'https://${_clean(host)}/api/v1';
      case 'bitbucket':
        return 'https://api.bitbucket.org/2.0';
      default:
        throw const ForgeException(ForgeFailure.unsupported);
    }
  }

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

  static Future<ForgeTree> tree({
    required String provider,
    required String token,
    required String repo,
    String host = '',
    String branch = '',
    http.Client? client,
  }) async {
    if (!supported.contains(provider)) {
      throw const ForgeException(ForgeFailure.unsupported);
    }
    if (token.isEmpty) throw const ForgeException(ForgeFailure.noToken);
    if (repo.isEmpty) throw const ForgeException(ForgeFailure.failed);
    if (needsHost(provider) && host.trim().isEmpty) {
      throw const ForgeException(ForgeFailure.noHost);
    }
    final base = _apiBase(provider, host.trim());
    final headers = _headers(provider, token);
    final http.Client c = client ?? http.Client();

    Future<dynamic> ask(String path) async {
      final uri = Uri.parse(path.startsWith('http') ? path : '$base$path');
      http.Response res;
      try {
        res = await c.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      } catch (_) {
        throw const ForgeException(ForgeFailure.unreachable);
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const ForgeException(ForgeFailure.denied);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw const ForgeException(ForgeFailure.failed);
      }
      try {
        return jsonDecode(res.body);
      } catch (_) {
        throw const ForgeException(ForgeFailure.failed);
      }
    }

    try {
      final on = branch.isEmpty
          ? await _defaultBranch(provider, repo, ask)
          : branch;
      if (on.isEmpty) throw const ForgeException(ForgeFailure.failed);
      return await _treeOf(provider, repo, on, ask);
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<String> _defaultBranch(
      String provider, String repo, Future<dynamic> Function(String) ask) async {
    switch (provider) {
      case 'gitlab':
        final body = await ask('/projects/${Uri.encodeComponent(repo)}');
        return body is Map ? (body['default_branch'] as String? ?? '') : '';
      case 'bitbucket':
        final body = await ask('/repositories/$repo');
        final main = body is Map ? body['mainbranch'] : null;
        return main is Map ? (main['name'] as String? ?? '') : '';
      default:
        final body = await ask('/repos/$repo');
        return body is Map ? (body['default_branch'] as String? ?? '') : '';
    }
  }

  static List<String> _blobs(dynamic rows, String type) {
    final out = <String>[];
    if (rows is! List) return out;
    for (final row in rows) {
      if (row is! Map) continue;
      if (row['type'] != type) continue;
      final path = row['path'];
      if (path is String && path.isNotEmpty) out.add(path);
    }
    return out;
  }

  static Future<ForgeTree> _treeOf(String provider, String repo, String branch,
      Future<dynamic> Function(String) ask) async {
    switch (provider) {
      case 'gitlab':
        {
          final project = Uri.encodeComponent(repo);
          final paths = <String>[];
          for (var page = 1; page <= _treePageMax; page++) {
            final body = await ask('/projects/$project/repository/tree'
                '?recursive=true&per_page=$_treePageSize&page=$page'
                '&ref=${Uri.encodeComponent(branch)}');
            final rows = body is List ? body : const [];
            paths.addAll(_blobs(rows, 'blob'));
            if (rows.length < _treePageSize) {
              return ForgeTree(branch: branch, paths: paths);
            }
          }
          return ForgeTree(branch: branch, paths: paths, partial: true);
        }
      case 'bitbucket':
        {
          final paths = <String>[];
          var next = '/repositories/$repo/src/${Uri.encodeComponent(branch)}/'
              '?max_depth=100&pagelen=100'
              '&fields=values.path,values.type,next';
          for (var page = 1; page <= _treePageMax; page++) {
            final body = await ask(next);
            paths.addAll(_blobs(body is Map ? body['values'] : null, 'commit_file'));
            final more = body is Map ? body['next'] : null;
            if (more is! String || more.isEmpty) {
              return ForgeTree(branch: branch, paths: paths);
            }
            next = more;
          }
          return ForgeTree(branch: branch, paths: paths, partial: true);
        }
      default:
        {
          var ref = branch;
          if (provider != 'github') {
            try {
              final head =
                  await ask('/repos/$repo/branches/${Uri.encodeComponent(branch)}');
              final commit = head is Map ? head['commit'] : null;
              final id = commit is Map ? commit['id'] : null;
              if (id is String && id.isNotEmpty) ref = id;
            } catch (_) {
              ref = branch;
            }
          }
          final query = provider == 'github'
              ? '?recursive=1'
              : '?recursive=true&per_page=1000';
          final body =
              await ask('/repos/$repo/git/trees/${Uri.encodeComponent(ref)}$query');
          final rows = body is Map ? body['tree'] : null;
          return ForgeTree(
            branch: branch,
            paths: _blobs(rows, 'blob'),
            partial: body is Map && body['truncated'] == true,
          );
        }
    }
  }
}
