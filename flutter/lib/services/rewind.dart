import '../models/conversation.dart';
import 'git_review.dart';

class RewindItem {
  RewindItem({
    required this.id,
    required this.kind,
    required this.msgId,
    this.repo = '',
    this.branch = '',
    this.base = '',
    this.paths = const [],
    this.job,
    this.connector = '',
    this.tool = '',
    this.args = '',
    this.at = 0,
    this.count = 0,
    required this.can,
    this.why = '',
    this.mark,
    this.number = 0,
    this.sha = '',
    this.url = '',
    this.provider = '',
    this.isJob = false,
  });

  final String id;
  final String kind;
  final String msgId;
  final String repo;
  final String branch;
  final String base;
  final List<String> paths;
  final Map<String, dynamic>? job;
  final String connector;
  final String tool;
  final String args;
  final int at;
  final int count;
  final bool can;
  final String why;
  final Map<String, dynamic>? mark;
  final int number;
  final String sha;
  final String url;
  final String provider;
  final bool isJob;
}

class RewindStep {
  RewindStep(this.item, {this.skip});

  final RewindItem item;
  final String? skip;
}

class RewindResult {
  RewindResult(this.item,
      {required this.ok,
      this.skipped,
      this.error = '',
      this.gone = false,
      this.moved = false,
      this.got});

  final RewindItem item;
  final bool ok;
  final String? skipped;
  final String error;
  final bool gone;
  final bool moved;
  final Map<String, dynamic>? got;
}

class RewindRefused implements Exception {
  RewindRefused(this.message, {this.gone = false, this.moved = false});

  final String message;
  final bool gone;
  final bool moved;

  @override
  String toString() => message;
}

class Rewind {
  Rewind._();

  static final _sha = RegExp(r'^[0-9a-fA-F]{40,64}$');

  static List<ChatMessage> after(List<ChatMessage> list, String msgId) {
    final at = list.indexWhere((m) => m.id == msgId);
    return at < 0 ? const [] : list.sublist(at + 1);
  }

  static List<Map<String, dynamic>> _marks(Map<String, dynamic>? mark) => marksOf(mark);

  static List<Map<String, dynamic>> _closable(Map<String, dynamic> x) {
    final out = <Map<String, dynamic>>[];
    final job = x['job'];
    final jobNo = job is Map ? pullNumberOf(job['pull']) : 0;
    if (job is Map &&
        jobNo > 0 &&
        job['branch'] is String &&
        job['merged'] != true &&
        job['closed'] != true &&
        job['deleted'] != true &&
        job['done'] != false) {
      out.add({
        'number': jobNo,
        'url': '${(job['pull'] as Map)['url'] ?? ''}',
        'branch': job['branch'],
        'sha': '${job['sha'] ?? ''}',
        'job': true,
      });
    }
    for (final p in (x['prs'] as List?) ?? const []) {
      if (p is! Map) continue;
      final n = pullNumberOf(p);
      final head = p['head'];
      if (n == 0 || n == jobNo || head is! String || head.isEmpty) continue;
      if (p['closed'] == true || p['merged'] == true) continue;
      out.add({'number': n, 'url': '${p['url'] ?? ''}', 'branch': head, 'sha': '', 'job': false});
    }
    return out;
  }

  static Set<String> picks(List<RewindItem> items) => {
        for (final i in items)
          if (i.can && i.kind != 'revert') i.id,
      };

  static bool _open(Object? job) =>
      job is Map &&
      job['branch'] is String &&
      (job['branch'] as String).isNotEmpty &&
      job['merged'] != true &&
      job['deleted'] != true;

  static List<RewindItem> effects(List<ChatMessage> dropped) {
    final out = <RewindItem>[];
    for (final m in dropped) {
      final mark = m.checkpoint;
      for (final x in _marks(mark)) {
        final repo = x['repo'] as String;
        final branch = x['branch'] is String ? x['branch'] as String : '';
        final paths = [
          for (final p in (x['paths'] is List ? x['paths'] as List : const []))
            if (p is String) p,
        ];
        if (paths.isNotEmpty) {
          final can = x['undoable'] == true && x['undone'] != true;
          out.add(RewindItem(
            id: 'files:${m.id}:$repo',
            kind: 'files',
            msgId: m.id,
            repo: repo,
            branch: branch,
            paths: paths,
            mark: x,
            can: can,
            why: can ? '' : (x['undone'] == true ? 'undone' : 'unrecorded'),
          ));
        }
        final job = x['job'];
        if (_open(job)) {
          final j = {'repo': repo, ...(job as Map).cast<String, dynamic>()};
          final can = _sha.hasMatch('${j['sha'] ?? ''}');
          out.add(RewindItem(
            id: 'branch:${m.id}:$repo:${j['branch']}',
            kind: 'branch',
            msgId: m.id,
            repo: repo,
            branch: '${j['branch']}',
            base: '${j['base'] ?? ''}',
            job: j,
            can: can,
            why: can ? '' : 'unrecorded',
          ));
        }
        for (final p in _closable(x)) {
          final isJob = p['job'] == true;
          final can = !isJob || _sha.hasMatch('${p['sha']}');
          out.add(RewindItem(
            id: 'pull:${m.id}:$repo:${p['number']}',
            kind: 'pull',
            msgId: m.id,
            repo: repo,
            branch: '${p['branch']}',
            sha: '${p['sha']}',
            number: p['number'] as int,
            url: '${p['url']}',
            isJob: isJob,
            can: can,
            why: can ? '' : 'unrecorded',
          ));
        }
        final n = job is Map ? pullNumberOf(job['pull']) : 0;
        if (job is Map &&
            n > 0 &&
            job['merged'] == true &&
            job['reverted'] == null &&
            job['branch'] is String) {
          final sha = '${job['sha'] ?? ''}';
          final recorded = _sha.hasMatch(sha);
          final provider = '${x['provider'] ?? ''}';
          final can = recorded && canRevertOn(provider);
          out.add(RewindItem(
            id: 'revert:${m.id}:$repo:$n',
            kind: 'revert',
            msgId: m.id,
            repo: repo,
            provider: provider.isEmpty ? 'github' : provider,
            branch: '${job['branch']}',
            base: '${job['base'] ?? ''}',
            sha: sha,
            number: n,
            url: '${(job['pull'] as Map)['url'] ?? ''}',
            can: can,
            why: can ? '' : (recorded ? 'forge' : 'unrecorded'),
          ));
        }
      }
      for (final a in m.actions) {
        final tool = a['tool'];
        if (tool is! String || tool.isEmpty) continue;
        out.add(RewindItem(
          id: 'connector:${m.id}:${out.length}',
          kind: 'connector',
          msgId: m.id,
          connector: '${a['connector'] ?? ''}',
          tool: tool,
          args: '${a['args'] ?? ''}',
          at: a['at'] is num ? (a['at'] as num).toInt() : 0,
          can: false,
          why: 'final',
        ));
      }
      if (m.serverRuns.isNotEmpty) {
        out.add(RewindItem(
          id: 'run:${m.id}',
          kind: 'run',
          msgId: m.id,
          count: m.serverRuns.length,
          can: false,
          why: 'sandboxed',
        ));
      }
    }
    return out;
  }

  static List<RewindStep> plan(List<RewindItem> items, Set<String> picked) {
    final chosen = items.where((i) => i.can && picked.contains(i.id)).toList();
    final gone = {
      for (final i in chosen)
        if (i.kind == 'branch') '${i.repo}\n${i.branch}',
    };
    return [
      for (final i in chosen.reversed)
        if (i.kind == 'files' && gone.contains('${i.repo}\n${i.branch}'))
          RewindStep(i, skip: 'branch')
        else
          RewindStep(i),
    ];
  }

  static Future<List<RewindResult>> run(
    List<RewindStep> steps, {
    required Future<void> Function(RewindItem item) revert,
    required Future<void> Function(RewindItem item) deleteBranch,
    Future<Object?> Function(RewindItem item)? closePull,
    Future<Object?> Function(RewindItem item)? revertPull,
  }) async {
    final out = <RewindResult>[];
    for (final s in steps) {
      if (s.skip != null) {
        out.add(RewindResult(s.item, ok: true, skipped: s.skip));
        continue;
      }
      try {
        Object? got;
        switch (s.item.kind) {
          case 'files':
            await revert(s.item);
          case 'pull':
            if (closePull == null) throw RewindRefused('');
            got = await closePull(s.item);
          case 'revert':
            if (revertPull == null) throw RewindRefused('');
            got = await revertPull(s.item);
          default:
            await deleteBranch(s.item);
        }
        out.add(RewindResult(s.item,
            ok: true, got: got is Map ? got.cast<String, dynamic>() : null));
      } on RewindRefused catch (e) {
        out.add(RewindResult(s.item,
            ok: false, error: e.message, gone: e.gone, moved: e.moved));
      } catch (e) {
        out.add(RewindResult(s.item, ok: false, error: '$e'));
      }
    }
    return out;
  }

  static List<ChatMessage> settled(
      List<ChatMessage> messages, List<RewindResult> results) {
    final byMsg = <String, List<RewindResult>>{};
    for (final r in results) {
      if (!r.ok && !r.gone) continue;
      (byMsg[r.item.msgId] ??= []).add(r);
    }
    return [
      for (final m in messages)
        if (byMsg[m.id] == null || m.checkpoint == null)
          m
        else
          m.copyWith(checkpoint: _fix(m.checkpoint!, byMsg[m.id]!)),
    ];
  }

  static Map<String, dynamic> _fix(
      Map<String, dynamic> mark, List<RewindResult> done) {
    Map<String, dynamic> one(Map<String, dynamic> x) {
      var next = x;
      for (final r in done) {
        final i = r.item;
        if (i.repo != x['repo']) continue;
        if (i.kind == 'files' && r.skipped == null && '${x['branch'] ?? ''}' == i.branch) {
          next = {...next, 'undone': true};
        }
        final job = next['job'];
        if (i.kind == 'branch' && job is Map && job['branch'] == i.branch) {
          next = {
            ...next,
            'job': {...job.cast<String, dynamic>(), 'deleted': true},
          };
        }
        if (i.kind == 'pull' && r.ok) {
          if (i.isJob && job is Map && job['branch'] == i.branch && pullNumberOf(job['pull']) == i.number) {
            next = {
              ...next,
              'job': {...job.cast<String, dynamic>(), 'closed': true},
            };
          } else if (next['prs'] is List) {
            next = {
              ...next,
              'prs': [
                for (final p in next['prs'] as List)
                  if (p is Map && pullNumberOf(p) == i.number)
                    {...p.cast<String, dynamic>(), 'closed': true}
                  else
                    p,
              ],
            };
          }
        }
        if (i.kind == 'revert' && r.ok && job is Map && job['branch'] == i.branch) {
          final got = r.got ?? const <String, dynamic>{};
          final n = pullNumberOf(got['pull']);
          next = {
            ...next,
            'job': {
              ...job.cast<String, dynamic>(),
              'reverted': {
                'branch': '${got['branch'] ?? ''}',
                'base': '${got['base'] ?? ''}',
                'sha': '${got['sha'] ?? ''}',
                'pull': n > 0 ? {'number': n, 'url': '${(got['pull'] as Map)['url'] ?? ''}'} : null,
              },
            },
          };
        }
      }
      return next;
    }

    return patchMarks(mark, one);
  }
}
