import 'package:flutter/material.dart';

import '../app.dart';
import '../services/server_runs.dart';
import '../services/site_checks.dart';
import 'i18n/i18n.dart';
import 'server_run_artifacts.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/sheet.dart';

Future<void> showSiteCheckSheet(BuildContext context) =>
    showNymSheet<void>(context, (_) => const SiteCheckSheet());

class SiteCheckSheet extends StatefulWidget {
  const SiteCheckSheet({super.key});

  @override
  State<SiteCheckSheet> createState() => _SiteCheckSheetState();
}

class _SiteCheckSheetState extends State<SiteCheckSheet> {
  final _url = TextEditingController();
  String? _status;
  bool _warn = false;
  bool _busy = false;
  double _override = 0;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  double _max(SiteCheckInfo info) => _override > info.maxCredits ? _override : info.maxCredits;

  void _say(String text, {bool warn = false}) => setState(() {
        _status = text;
        _warn = warn;
      });

  Future<void> _go() async {
    final app = AppScope.read(context);
    final info = app.siteCheck;
    final url = _url.text.trim();
    if (!SiteChecks.looksLikeAddress(url)) {
      _say(t('Enter a full http or https address.'), warn: true);
      return;
    }
    final conv = app.current;
    final max = _max(info);
    if (!await app.serverRunCapGate(conv, max)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    _say(t('Checking {url} in a headless browser…', {'url': url}));
    final res = await app.runSiteCheck(conv, url, max);
    if (!mounted) return;
    setState(() => _busy = false);
    final data = res.data;
    if (res.status == 200) {
      Navigator.pop(context);
      return;
    }
    if (res.status == 402 && data['error'] == 'price-changed' && data['maxCredits'] is num) {
      setState(() => _override = (data['maxCredits'] as num).toDouble());
      _say(t('The price went up since this was shown. Check it and run again.'), warn: true);
      return;
    }
    if (res.status == 402 && data['noCredits'] == true) {
      final text = await app.serverRunNoCredits(conv, data);
      if (!mounted) return;
      _say(text, warn: true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(text),
        action: SnackBarAction(label: t('Buy'), onPressed: () => showCreditsSheet(context)),
      ));
      return;
    }
    if (res.status == 503 && data['available'] == false) await app.refreshRunner();
    if (!mounted) return;
    final said = data['error'];
    _say(said is String && said.isNotEmpty ? said : t('The site check could not start.'), warn: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppScope.of(context);
    final info = app.siteCheck;
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Check a site'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              t('A fresh headless browser opens the public address you give and reports console errors, failed requests, load times, web app checks and a quick accessibility scan, with desktop and phone screenshots. Private, local and Nymbot addresses are refused. You pay for the browser time, never more than the price shown.'),
              style: hint,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('site-check-url'),
              controller: _url,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: t('Address'), hintText: 'https://example.com'),
              onSubmitted: (_) => _busy ? null : _go(),
            ),
            const SizedBox(height: 10),
            if (info.surcharge > 1) ...serverRunSurchargeLines(context, info.creditsPerMinute),
            Text(
              t('Up to {credits} Pro credits', {'credits': ServerRuns.credits(_max(info))}),
              key: const ValueKey('site-check-price'),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!,
                  key: const ValueKey('site-check-status'),
                  style: TextStyle(fontSize: 12, color: _warn ? theme.colorScheme.error : theme.hintColor)),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('site-check-go'),
                  onPressed: _busy ? null : _go,
                  child: Text(t('Check')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
