import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/workspace.dart';
import '../state/store.dart';
import 'git_forge.dart';

class RepoMapEntry {
  RepoMapEntry({
    required this.at,
    required this.usedAt,
    required this.branch,
    required this.paths,
    this.dropped = 0,
    this.total = 0,
    this.partial = false,
    this.failed = false,
  });

  final int at;
  int usedAt;
  final String branch;
  final List<String> paths;
  final int dropped;
  final int total;
  final bool partial;
  final bool failed;

  Map<String, dynamic> toJson() => {
        'at': at,
        'usedAt': usedAt,
        'branch': branch,
        'paths': paths,
        'dropped': dropped,
        'total': total,
        'partial': partial,
        'failed': failed,
      };

  static RepoMapEntry fromJson(Map<String, dynamic> j) => RepoMapEntry(
        at: (j['at'] as num?)?.toInt() ?? 0,
        usedAt: (j['usedAt'] as num?)?.toInt() ?? 0,
        branch: j['branch'] as String? ?? '',
        paths: (j['paths'] as List?)?.whereType<String>().toList() ?? const [],
        dropped: (j['dropped'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        partial: j['partial'] == true,
        failed: j['failed'] == true,
      );
}

class RepoMap {
  RepoMap(this.store, {this.client});

  final Store store;
  final http.Client? client;

  static const cacheKey = 'repoMaps';
  static const freshFor = Duration(hours: 2);
  static const retryAfter = Duration(minutes: 5);
  static const keepMaps = 12;
  static const filesPerRepo = 500;
  static const dirNamesMax = 24;
  static const blockMax = 12000;
  static const readyWithin = Duration(milliseconds: 2500);

  static const _skipDirs = {
    'node_modules', '.git', 'dist', 'build', 'out', 'target', '.next',
    '.nuxt', '.svelte-kit', '.cache', '.parcel-cache', 'coverage',
    '__pycache__', '.venv', 'venv', 'Pods', '.dart_tool', '.gradle',
    '.idea', '.vscode', 'bower_components', '.terraform', 'DerivedData',
    '.pub-cache', '.mypy_cache', '.pytest_cache', '.tox', '.expo', '.angular',
  };

  static const _skipFiles = {
    'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'npm-shrinkwrap.json',
    'pubspec.lock', 'Cargo.lock', 'composer.lock', 'Gemfile.lock',
    'poetry.lock', 'go.sum', 'Podfile.lock', 'mix.lock', 'flake.lock',
    '.DS_Store',
  };

  static const _stopTerms = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'can', 'could',
    'did', 'do', 'does', 'file', 'files', 'for', 'from', 'had', 'has', 'have',
    'how', 'i', 'if', 'in', 'is', 'it', 'its', 'me', 'my', 'not', 'of', 'on',
    'or', 'our', 'please', 'so', 'than', 'that', 'the', 'their', 'them',
    'then', 'there', 'these', 'they', 'this', 'to', 'was', 'we', 'were',
    'what', 'when', 'where', 'which', 'who', 'why', 'will', 'with', 'would',
    'you', 'your',
  };

  final Map<String, Future<void>> _running = {};
  Map<String, RepoMapEntry>? _memo;
  String _blockSig = '';
  String _blockText = '';

  static String keyFor(GitRepo repo) => [
        repo.provider.isEmpty ? 'github' : repo.provider,
        repo.host,
        repo.repo,
        repo.branch,
        repo.paths,
      ].join('|');

  Map<String, RepoMapEntry> _held() {
    final memo = _memo;
    if (memo != null) return memo;
    final out = <String, RepoMapEntry>{};
    final raw = store.getString(cacheKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is Map<String, dynamic>) {
              out[k] = RepoMapEntry.fromJson(v);
            }
          });
        }
      } catch (_) {
        out.clear();
      }
    }
    _memo = out;
    return out;
  }

  Future<void> _store(Map<String, RepoMapEntry> all) {
    _memo = all;
    return store.setString(cacheKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Future<void> _keep(Map<String, RepoMapEntry> all) {
    if (all.length <= keepMaps) return _store(all);
    final keys = all.keys.toList()
      ..sort((a, b) => (all[b]!.usedAt == 0 ? all[b]!.at : all[b]!.usedAt)
          .compareTo(all[a]!.usedAt == 0 ? all[a]!.at : all[a]!.usedAt));
    final out = <String, RepoMapEntry>{};
    for (final k in keys.take(keepMaps)) {
      out[k] = all[k]!;
    }
    return _store(out);
  }

  static List<String> _scopes(GitRepo? repo) => (repo?.paths ?? '')
      .split(RegExp(r'[,\s]+'))
      .where((p) => p.isNotEmpty)
      .map((p) => p.replaceFirst(RegExp(r'^/+'), ''))
      .toList();

  static bool _inScope(String path, List<String> only) {
    if (only.isEmpty) return true;
    for (final p in only) {
      if (path == p) return true;
      if (path.startsWith(p.endsWith('/') ? p : '$p/')) return true;
    }
    return false;
  }

  static bool ignorable(String path) {
    final parts = path.split('/');
    if (_skipFiles.contains(parts.last)) return true;
    for (var i = 0; i < parts.length - 1; i++) {
      if (_skipDirs.contains(parts[i])) return true;
    }
    return false;
  }

  static int _depthOf(String path) {
    var n = 0;
    for (var i = 0; i < path.length; i++) {
      if (path[i] == '/') n++;
    }
    return n;
  }

  static int _byName(String a, String b) {
    final plain = a.toLowerCase().compareTo(b.toLowerCase());
    return plain != 0 ? plain : a.compareTo(b);
  }

  static ({List<String> paths, int dropped, int total}) usable(
      List<String> files, GitRepo? repo) {
    final only = _scopes(repo);
    final rows = <String>[];
    for (final path in files) {
      if (path.isEmpty || path.endsWith('/')) continue;
      if (ignorable(path)) continue;
      if (!_inScope(path, only)) continue;
      rows.add(path);
    }
    rows.sort((a, b) {
      final depth = _depthOf(a).compareTo(_depthOf(b));
      return depth != 0 ? depth : _byName(a, b);
    });
    final kept = rows.take(filesPerRepo).toList()..sort(_byName);
    return (paths: kept, dropped: rows.length - kept.length, total: rows.length);
  }

  static Set<String> _termsOf(String query) => query
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_stopTerms.contains(w))
      .toSet();

  static bool _wanted(String name, Set<String> terms) {
    if (terms.isEmpty) return false;
    final plain = name.toLowerCase();
    for (final term in terms) {
      if (plain.contains(term)) return true;
    }
    return false;
  }

  static Map<String, List<String>> group(List<String> paths) {
    final dirs = <String, List<String>>{};
    for (final path in paths) {
      final at = path.lastIndexOf('/');
      final dir = at == -1 ? '' : path.substring(0, at + 1);
      final name = at == -1 ? path : path.substring(at + 1);
      dirs.putIfAbsent(dir, () => <String>[]).add(name);
    }
    return dirs;
  }

  static String render(
      String repo, RepoMapEntry entry, int budget, Set<String> terms,
      {String paths = ''}) {
    final branch = entry.branch.isEmpty ? '' : '@${entry.branch}';
    final scope = paths.isEmpty ? '' : ', paths $paths';
    final plural = entry.total == 1 ? ' file' : ' files';
    final lines = <String>['--- $repo$branch (${entry.total}$plural$scope) ---'];
    var spent = lines.first.length;
    final dirs = group(entry.paths);
    final names = dirs.keys.toList()..sort();
    var skipped = 0;

    for (final dir in names) {
      final all = dirs[dir]!..sort(_byName);
      if (spent >= budget) {
        skipped += all.length;
        continue;
      }
      final ordered = [
        ...all.where((n) => _wanted(n, terms)),
        ...all.where((n) => !_wanted(n, terms)),
      ];
      final shown = ordered.take(dirNamesMax).toList();
      final over = ordered.length - shown.length;
      final line = '${dir.isEmpty ? '(root)' : dir}: ${shown.join(', ')}'
          '${over > 0 ? ', and $over more here' : ''}';
      spent += line.length + 1;
      lines.add(line);
    }

    final unlisted = entry.dropped + skipped;
    if (unlisted > 0) {
      lines.add('$unlisted further files are not named above '
          '— list a directory to see them.');
    }
    if (entry.partial) {
      lines.add('The forge cut this listing short, so it is not every file.');
    }
    return lines.join('\n');
  }

  RepoMapEntry? entry(GitRepo repo) => _held()[keyFor(repo)];

  bool stale(GitRepo repo) {
    final hit = entry(repo);
    if (hit == null) return true;
    final age = DateTime.now().millisecondsSinceEpoch - hit.at;
    return age > (hit.failed ? retryAfter : freshFor).inMilliseconds;
  }

  Future<void> forget(GitRepo repo) {
    final all = _held();
    all.remove(keyFor(repo));
    return _store(all);
  }

  Future<void> forgetAll() => _store(<String, RepoMapEntry>{});

  Future<void> refresh(GitRepo repo) {
    if (repo.token.isEmpty || repo.repo.isEmpty) return Future.value();
    final key = keyFor(repo);
    final already = _running[key];
    if (already != null) return already;
    final run = () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        final read = await GitForge.tree(
          provider: repo.provider.isEmpty ? 'github' : repo.provider,
          token: repo.token,
          repo: repo.repo,
          host: repo.host,
          branch: repo.branch,
          client: client,
        );
        final kept = usable(read.paths, repo);
        final all = _held();
        all[key] = RepoMapEntry(
          at: now,
          usedAt: now,
          branch: read.branch.isEmpty ? repo.branch : read.branch,
          paths: kept.paths,
          dropped: kept.dropped,
          total: kept.total,
          partial: read.partial,
        );
        await _keep(all);
      } catch (_) {
        final all = _held();
        final before = all[key];
        if (before == null || before.paths.isEmpty) {
          all[key] = RepoMapEntry(
            at: now,
            usedAt: now,
            branch: repo.branch,
            paths: const [],
            failed: true,
          );
          await _keep(all);
        }
      } finally {
        _done(key);
      }
    }();
    _running[key] = run;
    return run;
  }

  void _done(String key) {
    _running.remove(key);
  }

  void warm(List<GitRepo> repos) {
    for (final repo in repos) {
      if (stale(repo)) refresh(repo);
    }
  }

  Future<void> touch(List<GitRepo> repos) {
    final all = _held();
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final repo in repos) {
      final hit = all[keyFor(repo)];
      if (hit == null || now - hit.usedAt < 60000) continue;
      hit.usedAt = now;
      changed = true;
    }
    return changed ? _store(all) : Future.value();
  }

  Future<void> ready(List<GitRepo> repos, {Duration? within}) async {
    final list = repos.where((r) => r.repo.isNotEmpty && r.token.isNotEmpty).toList();
    await touch(list);
    final missing = list.where((r) {
      final hit = entry(r);
      return hit == null || (hit.paths.isEmpty && !hit.failed);
    }).toList();
    warm(list);
    if (missing.isEmpty) return;
    final waits = missing
        .map((r) => _running[keyFor(r)])
        .whereType<Future<void>>()
        .toList();
    if (waits.isEmpty) return;
    await Future.any([
      Future.wait(waits),
      Future<void>.delayed(within ?? readyWithin),
    ]);
  }

  bool knows(List<GitRepo> repos) =>
      repos.every((r) => entry(r) != null);

  String block(List<GitRepo> repos, String query) {
    final list = repos.where((r) => r.repo.isNotEmpty).toList();
    if (list.isEmpty) return '';
    final terms = _termsOf(query);
    final all = _held();
    final sig = '${list.map((r) {
      final key = keyFor(r);
      final hit = all[key];
      return '$key:${hit == null ? '0' : '${hit.at}:${hit.paths.length}'}';
    }).join('|')}|${(terms.toList()..sort()).join(',')}';
    if (sig == _blockSig) return _blockText;
    final parts = <String>[];
    final budget = blockMax ~/ list.length;
    for (final repo in list) {
      final hit = all[keyFor(repo)];
      if (hit == null || hit.paths.isEmpty) continue;
      parts.add(render(repo.repo, hit, budget, terms, paths: repo.paths));
    }
    _blockSig = sig;
    _blockText = parts.isEmpty ? '' : _headed(parts);
    return _blockText;
  }

  static String _headed(List<String> parts) {
    return '[repository files]\n'
        'What each repository in scope holds, on the branch named, read from the '
        'forge by this device just now. Each line is a directory, then the files '
        'in it — pictures, video and other assets included, since what a '
        'repository holds is part of the answer even when the file cannot be read '
        'as text. Go straight to the file you want rather than listing '
        'directories to find it. Only dependencies, build output and lockfiles '
        'are left out; a count stands in wherever names are not listed, and the '
        'listing can be a little behind the branch — so a file you expect and do '
        'not see here may still be there. Where a shorter or truncated file list '
        'appears elsewhere in your instructions, prefer this one.\n'
        '${parts.join('\n')}';
  }
}
