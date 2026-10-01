import '../features/i18n/i18n.dart';

class SiteCheckInfo {
  const SiteCheckInfo({
    this.available = false,
    this.creditsPerMinute = 0,
    this.minCredits = 0,
    this.maxCredits = 0,
    this.timeoutSec = 60,
    this.surcharge = 1,
  });

  final bool available;
  final double creditsPerMinute;
  final double minCredits;
  final double maxCredits;
  final int timeoutSec;
  final double surcharge;

  static SiteCheckInfo fromJson(Object? raw) {
    if (raw is! Map || raw['available'] != true) return const SiteCheckInfo();
    double n(Object? v) => v is num && v > 0 ? v.toDouble() : 0;
    final timeout = raw['timeoutSec'];
    return SiteCheckInfo(
      available: n(raw['maxCredits']) > 0,
      creditsPerMinute: n(raw['creditsPerMinute']),
      minCredits: n(raw['minCredits']),
      maxCredits: n(raw['maxCredits']),
      timeoutSec: timeout is num && timeout > 0 ? timeout.toInt() : 60,
      surcharge: n(raw['surcharge']) > 1 ? n(raw['surcharge']) : 1,
    );
  }
}

class SiteChecks {
  SiteChecks._();

  static final _address = RegExp(r'^https?://\S+$', caseSensitive: false);

  static bool looksLikeAddress(String text) => _address.hasMatch(text.trim());

  static String _md(Object? text) {
    final s = '${text ?? ''}'.replaceAll(RegExp(r'[`\r\n]+'), ' ');
    return '`${s.length > 300 ? s.substring(0, 300) : s}`';
  }

  static String _int(Object? v) => '${v is num ? v.round() : 0}';

  static List<String> stepsFrom(Object? raw) {
    final out = <String>[];
    for (final s in (raw is List ? raw.take(20) : const [])) {
      if (s is! Map) continue;
      final parts = <String>['${s['action'] ?? ''}'];
      for (final k in ['selector', 'key', 'url']) {
        final v = s[k];
        if (v != null && '$v'.isNotEmpty) parts.add('$v'.length > 120 ? '$v'.substring(0, 120) : '$v');
      }
      final text = s['text'];
      if (text != null && '$text'.isNotEmpty) parts.add('"${'$text'.length > 80 ? '$text'.substring(0, 80) : text}"');
      if (s['ms'] != null) parts.add(t('{n} ms', {'n': s['ms'] is num ? (s['ms'] as num).floor() : 0}));
      out.add(parts.join(' '));
    }
    return out;
  }

  static String reportMarkdown(String url, Map<String, dynamic> out, double credits) {
    final r = out['report'] is Map ? (out['report'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final shown = url.isNotEmpty ? url : '${r['url'] ?? ''}';
    final lines = <String>['**${t('Site check of {url}', {'url': shown.replaceAll(RegExp(r'[*`]'), '')})}**', ''];
    if (r['timedOut'] == true) {
      lines.add(t('The check stopped at its time limit.'));
    } else if (out['ok'] == true) {
      lines.add(t('Loaded with status {status}: {title}', {
        'status': r['status'] == null ? '?' : '${r['status']}',
        'title': _md(r['title'] ?? ''),
      }));
    } else {
      final error = r['error'];
      lines.add(t('The check did not finish: {error}', {
        'error': _md(error == null || '$error'.isEmpty ? t('unknown error') : error),
      }));
    }
    lines.add('');
    final tm = r['timings'];
    if (tm is Map) {
      lines.add('- ${t('Timings: first byte {ttfb} ms, content loaded {dcl} ms, fully loaded {load} ms', {
        'ttfb': _int(tm['ttfbMs']),
        'dcl': _int(tm['domContentLoadedMs']),
        'load': _int(tm['loadMs']),
      })}');
    }
    void list(String Function(String n) label, List items, Object? count, String Function(Map it) fmt) {
      final total = count is num && count > items.length ? count.toInt() : items.length;
      lines.add('- ${label('$total')}');
      for (final it in items.take(5)) {
        if (it is Map) lines.add('  - ${fmt(it)}');
      }
    }

    List listOf(Object? v) => v is List ? v : const [];
    list((n) => t('Console errors: {n}', {'n': n}), [
      ...listOf(r['console']),
      for (final e in listOf(r['pageErrors'])) {'text': e},
    ], r['consoleErrorCount'], (it) => _md(it['text']));
    list((n) => t('Failed requests: {n}', {'n': n}), listOf(r['failedRequests']), r['failedCount'],
        (it) => '${_md(it['url'])} (${it['status'] != null ? '${it['status']}' : '${it['error'] ?? ''}'})');
    list((n) => t('Blocked requests: {n}', {'n': n}), listOf(r['blocked']), r['blockedCount'],
        (it) => '${_md(it['url'])} — ${it['reason'] ?? ''}');
    final pwa = r['pwa'];
    if (pwa is Map) {
      final m = pwa['manifest'] is Map ? pwa['manifest'] as Map : const {};
      final sw = pwa['serviceWorker'] is Map ? pwa['serviceWorker'] as Map : const {};
      final offline = pwa['offline'] is Map ? pwa['offline'] as Map : null;
      final installable = pwa['installable'] is Map ? pwa['installable'] as Map : const {};
      lines.add('- ${t('Web app manifest: {state}', {'state': m['ok'] == true ? t('valid') : (m['found'] == true ? t('has problems') : t('missing'))})}');
      lines.add('- ${t('Service worker: {state}', {'state': sw['registered'] == true ? t('registered') : t('not registered')})}');
      lines.add('- ${t('Reloads offline: {state}', {'state': offline == null || offline['tested'] != true ? t('not tested') : (offline['ok'] == true ? t('yes') : t('no'))})}');
      lines.add('- ${t('Installable: {state}', {'state': installable['ready'] == true ? t('yes') : t('no')})}');
    }
    final a = r['a11y'];
    if (a is Map) {
      lines.add('- ${t('Accessibility: {images} images without alt text, {fields} unlabeled fields, {buttons} unnamed buttons, {links} unnamed links', {
        'images': '${a['imagesWithoutAlt'] ?? 0}',
        'fields': '${a['inputsWithoutLabel'] ?? 0}',
        'buttons': '${a['buttonsWithoutName'] ?? 0}',
        'links': '${a['linksWithoutName'] ?? 0}',
      })}');
      if ('${a['lang'] ?? ''}'.isEmpty) lines.add('- ${t('The page has no lang attribute.')}');
    }
    for (final s in listOf(r['steps'])) {
      if (s is! Map) continue;
      final head = t('Step {n}: {action}', {'n': '${s['i']}', 'action': '${s['action'] ?? ''}'});
      final tail = s['ok'] == true
          ? '✓'
          : '✗${s['error'] != null && '${s['error']}'.isNotEmpty ? ' ${_md(s['error'])}' : (s['skipped'] == true ? ' ${t('skipped')}' : '')}';
      lines.add('- $head $tail');
    }
    for (final shot in listOf(out['screenshots'])) {
      final u = shot is Map ? shot['url'] : null;
      if (u is String && u.startsWith('https://')) lines.addAll(['', u]);
    }
    lines.addAll(['', t('Charged {credits} Pro credits', {'credits': decimalFigure(credits, 3)})]);
    return lines.join('\n');
  }
}
