import 'dart:convert';

import '../features/i18n/i18n.dart';

class PlanLimits {
  static const summary = 600;
  static const items = 20;
  static const item = 120;
  static const changes = 12;
  static const target = 120;
  static const what = 300;
  static const note = 2000;
  static const waitMs = 86400000;

  static Map<String, int> get asMap => {
        'summary': summary,
        'items': items,
        'item': item,
        'changes': changes,
        'target': target,
        'what': what,
        'note': note,
        'waitMs': waitMs,
      };
}

class Plan {
  static final _id = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
  static final _block = RegExp(r'<propose_plan>([\s\S]*?)</propose_plan>');
  static const states = {'waiting', 'sending', 'approved', 'edited', 'rejected', 'revised', 'expired'};
  static const decisions = {'approve', 'reject', 'revise'};
  static const modes = ['always', 'changing', 'never'];

  static String clean(Object? v, [int max = 0]) {
    var s = v is String ? v : '';
    s = s
        .replaceAll(RegExp('[\u0000-\u001f\u007f\u2028\u2029]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^ +| +$'), '');
    if (max > 0 && s.length > max) {
      s = '${s.substring(0, max - 1).replaceAll(RegExp(r' +$'), '')}…';
    }
    return s;
  }

  static String note(Object? v) {
    var s = v is String ? v : '';
    s = s
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp('[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029]'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'^\s+|\s+$'), '');
    if (s.length > PlanLimits.note) {
      s = '${s.substring(0, PlanLimits.note - 1).replaceAll(RegExp(r'\s+$'), '')}…';
    }
    return s;
  }

  static List<String>? items(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > PlanLimits.items) return null;
    final out = <String>[];
    for (final it in raw) {
      final text = clean(it is Map ? it['text'] : it, PlanLimits.item);
      if (text.isEmpty) return null;
      out.add(text);
    }
    return out;
  }

  static Map<String, dynamic> parse(Object? raw) {
    if (raw is! Map) return {'error': 'plan'};
    final summary = clean(raw['summary'], PlanLimits.summary);
    if (summary.isEmpty) return {'error': 'summary'};
    final steps = items(raw['items']);
    if (steps == null) return {'error': 'items'};
    final list = raw['changes'] ?? const [];
    if (list is! List || list.length > PlanLimits.changes) return {'error': 'changes'};
    final changes = <Map<String, dynamic>>[];
    for (final c in list) {
      if (c is! Map) return {'error': 'changes'};
      final target = clean(c['target'], PlanLimits.target);
      final what = clean(c['what'], PlanLimits.what);
      if (target.isEmpty || what.isEmpty) return {'error': 'changes'};
      changes.add({'target': target, 'what': what});
    }
    return {'summary': summary, 'items': steps, 'changes': changes};
  }

  static List<String> itemsOf(Object? raw) => raw is List ? [for (final x in raw) '$x'] : const [];

  static List<Map<String, dynamic>> changesOf(Object? raw) => raw is List
      ? [
          for (final c in raw)
            if (c is Map) c.cast<String, dynamic>()
        ]
      : const [];

  static Map<String, dynamic> decide(Map<String, dynamic> pending, Object? raw) {
    if (raw is! Map) return {'error': 'decision'};
    final d = raw['decision'];
    final decision = d is String && decisions.contains(d) ? d : '';
    if (decision.isEmpty) return {'error': 'decision'};
    final edits = raw['edits'] ?? const <String, dynamic>{};
    if (edits is! Map) return {'error': 'edits'};
    if (edits['note'] != null && edits['note'] is! String) return {'error': 'edits'};
    final said = note(edits['note']);
    if (decision == 'approve') {
      var steps = itemsOf(pending['items']);
      var edited = false;
      if (edits['items'] != null) {
        final got = items(edits['items']);
        if (got == null) return {'error': 'edits'};
        edited = jsonEncode(got) != jsonEncode(steps);
        steps = got;
      }
      return {'decision': 'approve', 'items': steps, 'note': said, 'edited': edited};
    }
    if (edits['items'] != null) return {'error': 'edits'};
    return {'decision': decision, 'note': said};
  }

  static ({String text, Map<String, dynamic>? plan}) take(Object? text) {
    final src = text is String ? text : '';
    String? last;
    for (final m in _block.allMatches(src)) {
      last = m.group(1);
    }
    var rest = src.replaceAll(_block, '');
    final open = rest.indexOf(RegExp(r'<propose_plan\b'));
    if (open != -1) rest = rest.substring(0, open);
    rest = rest.replaceAll(RegExp(r'\n{3,}'), '\n\n').replaceAll(RegExp(r'^\s+|\s+$'), '');
    Map<String, dynamic>? plan;
    if (last != null) {
      Object? obj;
      try {
        obj = jsonDecode(last);
      } catch (_) {
        obj = null;
      }
      final parsed = obj is Map ? parse(obj) : const {'error': 'json'};
      if (parsed['error'] == null && obj is Map && obj['id'] is String && _id.hasMatch(obj['id'] as String)) {
        plan = {
          'id': obj['id'],
          'summary': parsed['summary'],
          'items': parsed['items'],
          'changes': parsed['changes'],
        };
      }
    }
    return (text: rest, plan: plan);
  }

  static String cut(String text) {
    final at = text.toLowerCase().indexOf('<propose_plan');
    return at == -1 ? text : text.substring(0, at).replaceAll(RegExp(r'\s+$'), '');
  }

  static Map<String, dynamic>? record(Map<String, dynamic>? took, Map<String, dynamic>? data, [int? now]) {
    if (took == null || '${took['id'] ?? ''}'.isEmpty) return null;
    final d = data ?? const <String, dynamic>{};
    final p = d['pendingTool'] is Map &&
            (d['pendingTool'] as Map)['kind'] == 'plan' &&
            (d['pendingTool'] as Map)['id'] == took['id']
        ? (d['pendingTool'] as Map)
        : null;
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    final exp = p != null && p['expiresAt'] is num && (p['expiresAt'] as num) > 0
        ? ((p['expiresAt'] as num).toInt() < at + PlanLimits.waitMs
            ? (p['expiresAt'] as num).toInt()
            : at + PlanLimits.waitMs)
        : at + PlanLimits.waitMs;
    final bgRaw = d['background'];
    final bg = bgRaw is Map &&
            bgRaw['waiting'] == true &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch('${bgRaw['runId'] ?? ''}')
        ? '${bgRaw['runId']}'
        : null;
    final tok = d['resumeToken'];
    final token = bg == null && tok is String && RegExp(r'^[0-9a-f]{32,64}$', caseSensitive: false).hasMatch(tok)
        ? tok
        : null;
    return {
      'id': took['id'],
      'summary': took['summary'],
      'items': took['items'],
      'changes': took['changes'],
      'plain': bg == null && token == null,
      'token': token,
      'runId': bg,
      'expiresAt': exp,
      'state': 'waiting',
    };
  }

  static String? stateOf(Map<String, dynamic>? p, [int? now]) {
    if (p == null) return null;
    final s = states.contains(p['state']) ? p['state'] as String : 'waiting';
    final exp = p['expiresAt'];
    if ((s == 'waiting' || s == 'sending') &&
        exp is num &&
        exp > 0 &&
        (now ?? DateTime.now().millisecondsSinceEpoch) >= exp) {
      return 'expired';
    }
    if (s == 'waiting' && p['plain'] == true) return 'expired';
    return s;
  }

  static String? stageOf(Map<String, dynamic>? p, [int? now]) {
    switch (stateOf(p, now)) {
      case 'approved':
        return 'approved';
      case 'edited':
        return 'edited';
      case 'rejected':
        return 'rejected';
      case 'expired':
        return 'expired';
      case 'revised':
        return null;
      default:
        return 'proposed';
    }
  }

  static bool pending(Map<String, dynamic>? p, [int? now]) => stateOf(p, now) == 'waiting';

  static List<({String target, List<String> what})> grouped(Object? changes) {
    final out = <({String target, List<String> what})>[];
    for (final c in changesOf(changes)) {
      final target = '${c['target'] ?? ''}';
      final what = '${c['what'] ?? ''}';
      final at = out.indexWhere((g) => g.target == target);
      if (at >= 0) {
        out[at].what.add(what);
      } else {
        out.add((target: target, what: [what]));
      }
    }
    return out;
  }

  static int hoursLeft(Map<String, dynamic> p, [int? now]) {
    final exp = (p['expiresAt'] as num?)?.toInt() ?? 0;
    final left = exp - (now ?? DateTime.now().millisecondsSinceEpoch);
    return left <= 0 ? 0 : (left / 3600000).ceil();
  }

  static String textFor(Map<String, dynamic> got) {
    final said = '${got['note'] ?? ''}';
    switch (got['decision']) {
      case 'reject':
        return said.isNotEmpty ? t('Rejected the plan: {reason}', {'reason': said}) : t('Rejected the plan.');
      case 'revise':
        return said.isNotEmpty ? t('Revise the plan: {text}', {'text': said}) : t('Revise the plan.');
    }
    if (got['edited'] == true) {
      final steps = itemsOf(got['items']);
      return '${t('Approved the plan with edits:')}\n${[for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n')}${said.isNotEmpty ? '\n\n$said' : ''}';
    }
    return said.isNotEmpty ? t('Approved the plan. {note}', {'note': said}) : t('Approved the plan.');
  }

  static Map<String, dynamic> keptFor(Map<String, dynamic> got) {
    switch (got['decision']) {
      case 'reject':
        return {'state': 'rejected', 'note': got['note'], 'error': ''};
      case 'revise':
        return {'state': 'revised', 'note': got['note'], 'error': ''};
    }
    return {
      'state': got['edited'] == true ? 'edited' : 'approved',
      'approvedItems': got['items'],
      'note': got['note'],
      'error': '',
    };
  }

  static Map<String, dynamic> bodyFor(Map<String, dynamic> p, Map<String, dynamic> got) {
    final said = '${got['note'] ?? ''}';
    return {
      'id': p['id'],
      'decision': got['decision'],
      if (got['decision'] == 'approve' && got['edited'] == true)
        'edits': {'items': got['items'], 'note': said}
      else if (said.isNotEmpty)
        'edits': {'note': said},
    };
  }

  static String statusText(Map<String, dynamic> p, String? state) {
    switch (state) {
      case 'approved':
        return t('Approved. Nymbot carried on with this plan.');
      case 'edited':
        return t('Approved with your edits. Nymbot carried on with them.');
      case 'rejected':
        return t('Rejected. Nothing was changed.');
      case 'revised':
        return t('Sent back for a revised plan.');
      case 'expired':
        return p['plain'] == true
            ? t('This plan can no longer be approved. Ask again to start it fresh.')
            : t('The plan was not approved within 24 hours, so this task stopped. Ask again to start it fresh.');
      case 'sending':
        return t('Sending your decision…');
      default:
        return p['error'] is String ? p['error'] as String : '';
    }
  }

  static ({String label, String state, String detail, List<String> children})? taskItem(Map<String, dynamic>? p, [int? now]) {
    if (p == null) return null;
    final summary = '${p['summary'] ?? ''}';
    final steps = itemsOf(p['approvedItems'] ?? p['items']);
    if (summary.isEmpty || itemsOf(p['items']).isEmpty) return null;
    final s = stateOf(p, now);
    final label = s == 'waiting' || s == 'sending'
        ? t('Plan waiting for your approval: {summary}', {'summary': summary})
        : s == 'rejected'
            ? t('Plan rejected: {summary}', {'summary': summary})
            : s == 'expired'
                ? t('Plan expired: {summary}', {'summary': summary})
                : s == 'revised'
                    ? t('Plan sent back for revision: {summary}', {'summary': summary})
                    : t('Plan approved: {summary}', {'summary': summary});
    final targets = [for (final g in grouped(p['changes'])) g.target];
    return (
      label: label,
      state: s == 'waiting' || s == 'sending'
          ? 'waiting'
          : (s == 'expired' ? 'stopped' : (s == 'rejected' || s == 'revised' ? 'skipped' : 'done')),
      detail: targets.isEmpty ? '' : t('Changes: {targets}', {'targets': targets.take(4).join(', ')}),
      children: steps.take(6).toList(),
    );
  }
}
