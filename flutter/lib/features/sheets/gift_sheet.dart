import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/gifts.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import 'sheet.dart';
import '../nym_glyph.dart';

Future<void> showGiftSheet(BuildContext context) =>
    showNymSheet<void>(context, (_) => const GiftSheet());

Future<void> showRedeemGiftSheet(BuildContext context, {String prefill = ''}) =>
    showNymSheet<void>(context, (_) => RedeemGiftSheet(prefill: prefill));

class GiftSheet extends StatefulWidget {
  const GiftSheet({super.key});

  @override
  State<GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<GiftSheet> {
  final _amount = TextEditingController();
  String _tier = 'standard';
  ({String tier, int amount, String code})? _pending;
  ({String code, GiftRecord gift})? _made;
  List<GiftRecord> _gifts = const [];
  Map<String, String> _codes = const {};
  String? _status;
  bool _warn = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _tier = app.proTier ? 'pro' : 'standard';
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int _most(AppController app) =>
      Gifts.available(_tier == 'pro' ? app.proBalance : app.standardBalance);

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    await app.refreshBalance();
    final gifts = await app.listGifts();
    final codes = await app.giftCodes();
    if (!mounted) return;
    setState(() {
      if (gifts != null) _gifts = gifts;
      _codes = codes;
    });
  }

  void _say(String? text, {bool warn = false}) => setState(() {
        _status = text;
        _warn = warn;
      });

  Future<void> _make() async {
    final app = AppScope.read(context);
    final problem = Gifts.problem(_amount.text, _tier, _most(app), app.giftMinimum);
    if (problem != null) {
      _say(problem, warn: true);
      return;
    }
    final n = int.parse(_amount.text.trim());
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Gift {what}?', {'what': Gifts.credits(_tier, n)})),
        content: Text(t('They leave your balance now. You get a link and a code that anyone can claim once. If nobody claims it, cancel it to get them back, or they come back by themselves after {days} days.',
            {'days': figure(app.giftTtlDays)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
          FilledButton(
            key: const ValueKey('gift-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Make the gift')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final held = _pending;
    final ask = held != null && held.tier == _tier && held.amount == n
        ? held
        : (tier: _tier, amount: n, code: Gifts.newCode());
    _pending = ask;
    setState(() => _busy = true);
    _say(t('Making the gift…'));
    final res = await app.makeGift(tier: ask.tier, amount: ask.amount, code: ask.code);
    if (!mounted) return;
    setState(() => _busy = false);
    final gift = res.gift;
    if (gift == null) {
      _say(res.error, warn: true);
      return;
    }
    _pending = null;
    _amount.clear();
    setState(() => _made = (code: ask.code, gift: gift));
    _say(t('Done. Send the link or the code to whoever it is for.'));
    await _refresh();
  }

  Future<void> _cancel(GiftRecord g) async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Cancel this gift?')),
        content: Text(t('{what} go back onto your balance, and the link and code stop working.',
            {'what': Gifts.credits(g.tier, g.amount)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Keep it'))),
          FilledButton(
            key: const ValueKey('gift-cancel-confirm'),
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Cancel gift')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final res = await app.cancelGift(g);
    if (!mounted) return;
    if (res.ok && _made?.gift.id == g.id) setState(() => _made = null);
    _say(res.message, warn: !res.ok);
    await _refresh();
  }

  Widget _madeBox(BuildContext context) {
    final made = _made!;
    final link = Gifts.link(made.code);
    const mono = TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 12);
    return Container(
      key: const ValueKey('gift-made'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('A gift of {what}. It can be claimed once, until {date}.', {
              'what': Gifts.credits(made.gift.tier, made.gift.amount),
              'date': Gifts.day(made.gift.expiresAt),
            }),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.white,
              child: QrImageView(data: link, size: 200, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 10),
          SelectableText(link, key: const ValueKey('gift-link'), style: mono),
          const SizedBox(height: 6),
          SelectableText(made.code, key: const ValueKey('gift-code'), style: mono),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                icon: const NymGlyph('copy', size: 16),
                label: Text(t('Copy the link')),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  _say(t('Copied.'));
                },
              ),
              OutlinedButton.icon(
                icon: const NymGlyph('copy', size: 16),
                label: Text(t('Copy the code')),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: made.code));
                  _say(t('Copied.'));
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.ios_share, size: 16),
                label: Text(t('Share')),
                onPressed: () => Share.share(
                  '${t('A gift of {what} on Nymbot. Open the link to add them to your balance.', {'what': Gifts.credits(made.gift.tier, made.gift.amount)})}\n$link',
                  subject: t('A Nymbot gift'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t('Anyone with the link or the code can claim it, so send it only to the person it is for.'),
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, GiftRecord g) {
    final code = _codes[g.id];
    return Container(
      key: ValueKey('gift-row-${g.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(Gifts.credits(g.tier, g.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(Gifts.stateLine(g),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ],
          ),
          if (g.open && code != null)
            TextButton(
              key: ValueKey('gift-show-${g.id}'),
              onPressed: () => setState(() => _made = (code: code, gift: g)),
              child: Text(t('Show')),
            ),
          if (g.open)
            TextButton(
              key: ValueKey('gift-cancel-${g.id}'),
              onPressed: () => _cancel(g),
              child: Text(t('Cancel gift')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final most = _most(app);
    final floor = Gifts.minOf(_tier, app.giftMinimum);
    final hint = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Gift an amount'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(t('Choose how many of your credits to give. You get a link, a code and a QR code, and whoever uses it first adds the credits to their own balance.')),
            const SizedBox(height: 6),
            Text(
              t('Your balance: {standard} credits · {pro} Pro credits', {
                'standard': creditFigure(app.standardBalance ?? 0),
                'pro': creditFigure(app.proBalance ?? 0),
              }),
              style: hint,
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              key: const ValueKey('gift-tier'),
              segments: [
                ButtonSegment(value: 'standard', label: Text(t('Standard'))),
                ButtonSegment(value: 'pro', label: Text(t('Pro'))),
              ],
              selected: {_tier},
              onSelectionChanged: (s) => setState(() {
                _tier = s.first;
                _pending = null;
                _status = null;
              }),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in Gifts.presets[_tier]!)
                  ChoiceChip(
                    key: ValueKey('gift-preset-$n'),
                    label: Text(figure(n)),
                    selected: _amount.text.trim() == '$n',
                    onSelected: n > most
                        ? null
                        : (_) => setState(() {
                              _amount.text = '$n';
                              _status = null;
                            }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('gift-amount'),
              controller: _amount,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: t('Credits')),
              onChanged: (_) => setState(() => _status = null),
            ),
            const SizedBox(height: 4),
            Text(
              t('At least {min}, at most the {most} you have free to give.',
                  {'min': figure(floor), 'most': figure(most)}),
              style: hint,
            ),
            if (_made != null) _madeBox(context),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!,
                  key: const ValueKey('gift-status'),
                  style: TextStyle(fontSize: 13, color: _warn ? NymbotColors.danger : null)),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                TextButton(
                  key: const ValueKey('gift-redeem-open'),
                  onPressed: () => showRedeemGiftSheet(context),
                  child: Text(t('Redeem a gift…')),
                ),
                FilledButton(
                  key: const ValueKey('gift-make'),
                  onPressed: _busy ? null : _make,
                  child: Text(t('Make the gift')),
                ),
              ],
            ),
            if (_gifts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(t('Your gifts'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              for (final g in _gifts) _row(context, g),
            ],
          ],
        ),
      ),
    );
  }
}

class RedeemGiftSheet extends StatefulWidget {
  const RedeemGiftSheet({super.key, this.prefill = ''});

  final String prefill;

  @override
  State<RedeemGiftSheet> createState() => _RedeemGiftSheetState();
}

class _RedeemGiftSheetState extends State<RedeemGiftSheet> {
  late final TextEditingController _code = TextEditingController(text: widget.prefill);
  String _what = '';
  String? _status;
  bool _warn = false;
  bool _ready = false;
  bool _busy = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.prefill.isNotEmpty) unawaited(_peek());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _peek() async {
    final code = Gifts.codeOf(_code.text);
    final seq = ++_seq;
    if (code == null) {
      setState(() {
        _ready = false;
        _what = _code.text.trim().isEmpty ? '' : t('That does not look like a gift link or code.');
      });
      return;
    }
    setState(() => _what = t('Looking it up…'));
    final res = await AppScope.read(context).peekGift(code);
    if (!mounted || seq != _seq) return;
    final g = res.gift;
    setState(() {
      _ready = false;
      if (g == null) {
        _what = res.error ?? t('That gift could not be looked up.');
      } else if (g.own) {
        _what = t('This is your own gift of {what}.', {'what': Gifts.credits(g.tier, g.amount)});
      } else if (g.state == 'redeemed') {
        _what = t('This gift has already been claimed.');
      } else if (g.state == 'canceled') {
        _what = t('Whoever made this gift canceled it.');
      } else if (g.state == 'expired') {
        _what = t('This gift expired and went back to whoever made it.');
      } else {
        _what = t('A gift of {what}, waiting to be claimed.', {'what': Gifts.credits(g.tier, g.amount)});
        _ready = true;
      }
    });
  }

  Future<void> _redeem() async {
    final code = Gifts.codeOf(_code.text);
    if (code == null) return;
    setState(() {
      _busy = true;
      _status = t('Adding it to your balance…');
      _warn = false;
    });
    final res = await AppScope.read(context).redeemGift(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = res.message;
      _warn = !res.ok;
      if (res.ok) {
        _ready = false;
        _what = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('Redeem a gift'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(t('Paste the gift link or code someone sent you. The credits go onto this key\'s balance.')),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('redeem-code'),
            controller: _code,
            autocorrect: false,
            decoration: InputDecoration(labelText: t('Gift link or code')),
            onChanged: (_) => _peek(),
          ),
          if (_what.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_what, key: const ValueKey('redeem-what')),
          ],
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(_status!,
                key: const ValueKey('redeem-status'),
                style: TextStyle(color: _warn ? NymbotColors.danger : null)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('redeem-go'),
            onPressed: _ready && !_busy ? _redeem : null,
            child: Text(t('Add to my balance')),
          ),
        ],
      ),
    );
  }
}
