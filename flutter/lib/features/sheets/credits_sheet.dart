import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../config.dart';
import '../../core/theme/theme.dart';
import '../../services/nostr/event_signer.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import '../purchase_policy.dart';

Future<void> showCreditsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CreditsSheet(),
    );

class _CreditsSheet extends StatefulWidget {
  const _CreditsSheet();

  @override
  State<_CreditsSheet> createState() => _CreditsSheetState();
}

class _CreditsSheetState extends State<_CreditsSheet> {
  final _amount = TextEditingController(text: '50');
  String _tier = 'standard';
  String? _invoice;
  String? _invoiceId;
  String? _status;
  bool _warn = false;
  bool _busy = false;
  Timer? _poll;
  EventSigner? _signer;

  @override
  void initState() {
    super.initState();
    _tier = AppScope.read(context).proTier ? 'pro' : 'standard';
  }

  @override
  void dispose() {
    _poll?.cancel();
    _amount.dispose();
    super.dispose();
  }

  int get _credits => int.tryParse(_amount.text) ?? 0;
  int get _sats => _credits * (NymbotConfig.satsPerCredit[_tier] ?? 10);

  Future<void> _buy() async {
    final app = AppScope.read(context);
    if (_credits <= 0) {
      setState(() {
        _status = t('Enter how many credits to buy.');
        _warn = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = t('Creating an invoice…');
      _warn = false;
    });
    final useAnon = (app.current?.anon ?? false) && app.anon.ready;
    final signer = useAnon ? await app.anon.signer() : app.identity.signer;
    final res = await app.api
        .createInvoice(signer, amountSats: _sats, tier: _tier);
    if (!mounted) return;
    final pr = res.data['pr'] as String?;
    if (pr == null) {
      setState(() {
        _busy = false;
        _status = (res.data['error'] as String?) ?? 'Could not create an invoice.';
        _warn = true;
      });
      return;
    }
    setState(() {
      _busy = false;
      _invoice = pr;
      _invoiceId = res.data['invoiceId'] as String?;
      _signer = signer;
      _status = t('Pay {sats} sats. This updates the moment it settles.',
          {'sats': figure(_sats)});
    });
    _startPolling(signer);
  }

  Future<void> _claim(EventSigner signer, String id) async {
    final app = AppScope.read(context);
    final claim = await app.api.claimCredits(signer, id);
    if (!mounted) return;
    final error = claim.data['error'] as String?;
    if (error == null) {
      setState(() {
        _status = t('Credited. Balance: {balance}.',
            {'balance': figure(claim.data['balance'])});
        _warn = false;
        _invoice = null;
      });
      await app.refreshBalance();
    } else {
      setState(() {
        _status = error;
        _warn = !error.toLowerCase().contains('already claimed');
      });
    }
  }

  Future<void> _checkPaid() async {
    final app = AppScope.read(context);
    final id = _invoiceId;
    final signer = _signer;
    if (id == null || signer == null || _busy) return;
    setState(() {
      _busy = true;
      _status = t('Checking your payment…');
      _warn = false;
    });
    final check = await app.api.checkInvoice(signer, id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (check.data['paid'] == true) {
      _poll?.cancel();
      await _claim(signer, id);
      return;
    }
    setState(() {
      _status = (check.data['error'] as String?) ??
          t('Not paid yet. Finish paying in your wallet, then tap it again.');
      _warn = true;
    });
  }

  void _startPolling(EventSigner signer) {
    final app = AppScope.read(context);
    final id = _invoiceId;
    if (id == null) return;
    var ticks = 0;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (++ticks > 60) {
        timer.cancel();
        setState(() {
          _status = t('Still waiting on this payment. If you have paid, tap '
              'I\u2019ve paid — otherwise create a new invoice.');
          _warn = true;
        });
        return;
      }
      if (_busy) return;
      final check = await app.api.checkInvoice(signer, id);
      if (check.data['paid'] != true) return;
      timer.cancel();
      await _claim(signer, id);
    });
  }

  /// What the account holds right now, read through [AppScope.of] so a purchase
  /// that lands while this is open is reflected here rather than only behind
  /// it. This is the section a buyer is looking at when the credits arrive.
  Widget _balances(BuildContext context, AppController app) {
    Widget cell(String label, int? value, bool active, {bool freeTier = false}) {
      final free = app.freeLeft;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
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
                    : t('{n} credits', {'n': figure(value)}),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              // With nothing to spend, the day's allowance is what is left —
              // which is a thing still working, where a zero is a wall.
              if (freeTier && (value ?? 0) == 0 && free != null)
                Text(t('{n} free left today', {'n': figure(free)}),
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cell(t('Standard'), app.standardBalance, _tier == 'standard',
            freeTier: true),
        const SizedBox(width: 8),
        cell(t('Pro'), app.proBalance, _tier == 'pro'),
      ],
    );
  }

  /// Where credits are bought on a platform that cannot sell them here.
  /// Deliberately a STATEMENT: no button, no tappable link, nothing that reads
  /// as a call to action pointing at an outside purchase — see
  /// purchase_policy.dart.
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
    // Subscribed, not read: the balances below have to follow a purchase that
    // lands while this sheet is still open.
    final app = AppScope.of(context);
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
            const SizedBox(height: 12),
            _balances(context, app),
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
            const SizedBox(height: 6),
            if (_credits > 0)
              Text(
                _tier == 'pro'
                    ? (_credits == 1
                        ? t('1 Pro credit = {sats} sats', {'sats': figure(_sats)})
                        : t('{n} Pro credits = {sats} sats',
                            {'n': figure(_credits), 'sats': figure(_sats)}))
                    : (_credits == 1
                        ? t('1 credit = {sats} sats', {'sats': figure(_sats)})
                        : t('{n} credits = {sats} sats',
                            {'n': figure(_credits), 'sats': figure(_sats)})),
                style: const TextStyle(fontSize: 12),
              ),
            if (_invoice != null) ...[
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: _invoice!.toUpperCase(),
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
                      icon: const Icon(Icons.copy, size: 16),
                      label: Text(t('Copy invoice')),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _invoice!));
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
                      icon: const Icon(Icons.bolt, size: 16),
                      label: Text(t('Open wallet')),
                      onPressed: () => launchUrl(
                        Uri.parse('lightning:${_invoice!}'),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _warn ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            if (_invoice == null)
              FilledButton(
                onPressed: _busy ? null : _buy,
                child: Text(t('Create invoice')),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _checkPaid,
                      child: Text(t('I\u2019ve paid')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _buy,
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
