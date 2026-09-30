import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../config.dart';
import '../../core/theme/theme.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import '../purchase_policy.dart';
import 'sheet.dart';
import '../nym_glyph.dart';

Future<void> showCreditsSheet(BuildContext context,
        {int? credits, String? reason, bool toAnon = false}) =>
    showNymSheet<void>(
      context,
      (_) => _CreditsSheet(credits: credits, reason: reason, toAnon: toAnon),
    );

class _CreditsSheet extends StatefulWidget {
  const _CreditsSheet({this.credits, this.reason, this.toAnon = false});

  final int? credits;
  final String? reason;
  final bool toAnon;

  @override
  State<_CreditsSheet> createState() => _CreditsSheetState();
}

class _CreditsSheetState extends State<_CreditsSheet> {
  final _amount = TextEditingController(text: '50');
  String _tier = 'standard';
  late bool _toAnon = widget.toAnon;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    final held = app.invoice;
    if (held != null) {
      _tier = held.tier;
      _amount.text = '${held.credits}';
    } else {
      _tier = app.proTier ? 'pro' : 'standard';
      app.invoiceStatus = null;
      final credits = widget.credits;
      if (credits != null && credits > 0) _amount.text = '$credits';
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _credits => int.tryParse(_amount.text) ?? 0;
  int get _sats => _credits * (NymbotConfig.satsPerCredit[_tier] ?? 10);

  String _priceLine(AppController app) {
    final line = _tier == 'pro'
        ? (_credits == 1
            ? t('1 Pro credit = {sats} sats', {'sats': figure(_sats)})
            : t('{n} Pro credits = {sats} sats',
                {'n': figure(_credits), 'sats': figure(_sats)}))
        : (_credits == 1
            ? t('1 credit = {sats} sats', {'sats': figure(_sats)})
            : t('{n} credits = {sats} sats',
                {'n': figure(_credits), 'sats': figure(_sats)}));
    final got = app.creditsCredited(_credits, _tier);
    if (got <= _credits) return line;
    final pct = ((got / _credits - 1) * 100).round();
    return '$line '
        '${t('— you get {n}, with the {pct}% bulk bonus', {'n': figure(got), 'pct': '$pct'})}';
  }

  String _pricingNote() => _tier == 'pro'
      ? t('Every reply is metered on the tokens it uses, so an ordinary '
          'question costs a fraction of a credit. Context you have already '
          'sent is billed at a tenth of the fresh rate.')
      : t('Every reply is metered on the tokens it uses, so a short question '
          'costs a fraction of a credit. Coding and reasoning questions cost '
          'more, because they are routed to bigger models.');

  Future<void> _buy() =>
      AppScope.read(context).createInvoice(_credits, _tier, toAnon: _toAnon);

  Future<void> _checkPaid() =>
      AppScope.read(context).checkInvoice(manual: true);

  /// Read via [AppScope.of] so a purchase landing while open shows here.
  Widget _balances(BuildContext context, AppController app, {bool pick = false}) {
    Widget cell(String tier, String label, double? value, {bool freeTier = false}) {
      final free = app.freeLeft;
      final active = _tier == tier;
      final radius = BorderRadius.circular(10);
      final body = Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: active
                ? NymbotColors.lightning
                : Theme.of(context).dividerColor,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor)),
            const SizedBox(height: 2),
            Text(
              value == null
                  ? '—'
                  : t('{n} credits', {'n': creditFigure(value)}),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (freeTier && (value ?? 0) == 0 && free != null)
              Text(t('{n} free left today', {'n': figure(free)}),
                  style: TextStyle(
                      fontSize: 11, color: Theme.of(context).hintColor)),
          ],
        ),
      );
      return Expanded(
        child: Semantics(
          button: pick,
          selected: active,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: radius,
            child: pick
                ? InkWell(
                    key: ValueKey('credit-balance-$tier'),
                    borderRadius: radius,
                    mouseCursor: SystemMouseCursors.click,
                    onTap: () => setState(() => _tier = tier),
                    child: body,
                  )
                : body,
          ),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cell('standard', t('Standard'), app.standardBalance, freeTier: true),
          const SizedBox(width: 8),
          cell('pro', t('Pro'), app.proBalance),
        ],
      ),
    );
  }

  /// Must stay a plain statement with no tap target; see purchase_policy.dart.
  Widget _purchasesDisabledNote(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Text(
        t('Nymbot credits cannot be purchased in this app. Credits are bought '
            'from the Nymbot web app in your browser. Credits you already have '
            'work here as usual.'),
        style: TextStyle(fontSize: 12, height: 1.45, color: Theme.of(context).hintColor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Subscribed so balances follow a purchase that lands while the sheet is open.
    final app = AppScope.of(context);
    final invoice = app.invoice?.pr;
    final paid = app.invoice?.paid ?? false;
    final busy = app.invoiceBusy;
    final status = app.invoiceStatus;
    if (creditPurchasesDisabled) {
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('Nymbot credits'),
                  style: Theme.of(context).textTheme.titleMedium),
              if (widget.reason != null) ...[
                const SizedBox(height: 8),
                Text(widget.reason!,
                    key: const ValueKey('credits-reason'),
                    style: const TextStyle(fontSize: 13, height: 1.35)),
              ],
              const SizedBox(height: 12),
              _balances(context, app),
              const SizedBox(height: 12),
              _purchasesDisabledNote(context),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Buy credits'), style: Theme.of(context).textTheme.titleMedium),
            if (widget.reason != null) ...[
              const SizedBox(height: 8),
              Text(widget.reason!,
                  key: const ValueKey('credits-reason'),
                  style: const TextStyle(fontSize: 13, height: 1.35)),
            ],
            const SizedBox(height: 12),
            _balances(context, app, pick: true),
            const SizedBox(height: 12),
            Text(
              t('Standard picks a model for you, per question. Pro answers with '
                  'the one frontier model you choose. Separate balances, and '
                  'neither converts into the other.'),
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'standard', label: Text(t('Standard · 10 sats'))),
                ButtonSegment(value: 'pro', label: Text(t('Pro · 100 sats'))),
              ],
              selected: {_tier},
              onSelectionChanged: (s) => setState(() => _tier = s.first),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final n in const [10, 25, 50, 100, 250, 500])
                  ActionChip(
                    label: Text('$n'),
                    onPressed: () => setState(() => _amount.text = '$n'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t('Credits')),
              onChanged: (_) => setState(() {}),
            ),
            if (invoice == null && !app.spendingAnon)
              SwitchListTile(
                key: const ValueKey('credits-to-anon'),
                contentPadding: EdgeInsets.zero,
                value: _toAnon,
                onChanged: (on) => setState(() => _toAnon = on),
                title: Text(t('Put them on a throwaway key, not your nym'),
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    t('Your nym never touches the payment. Spend them from an '
                        'anonymous chat.'),
                    style: const TextStyle(fontSize: 11)),
              ),
            const SizedBox(height: 6),
            if (_credits > 0) ...[
              Text(_priceLine(app), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Text(_pricingNote(), style: const TextStyle(fontSize: 11)),
            ],
            if (invoice != null) ...[
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: invoice.toUpperCase(),
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const NymGlyph('copy', size: 16),
                      label: Text(t('Copy invoice')),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: invoice));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t('Copied.'))),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const NymGlyph('wallet', size: 16),
                      label: Text(t('Open wallet')),
                      onPressed: () => launchUrl(
                        Uri.parse('lightning:$invoice'),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: app.invoiceWarn
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            if (invoice == null)
              FilledButton(
                onPressed: busy ? null : _buy,
                child: Text(t('Create invoice')),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : _checkPaid,
                      child: Text(paid ? t('Add my credits') : t('I\u2019ve paid')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy || paid ? null : _buy,
                      child: Text(t('New invoice')),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
