import 'package:flutter/material.dart';

import '../../app.dart';
import '../i18n/i18n.dart';

Future<void> showAnonSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AnonSheet(),
    );

class _AnonSheet extends StatefulWidget {
  const _AnonSheet();

  @override
  State<_AnonSheet> createState() => _AnonSheetState();
}

class _AnonSheetState extends State<_AnonSheet> {
  final _amount = TextEditingController();
  String _tier = 'standard';
  String? _status;
  bool _warn = false;
  ({int? anon, int? anonPro, int? identity, int? identityPro})? _balances;

  @override
  void initState() {
    super.initState();
    _loadBalances();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadBalances() async {
    final app = AppScope.read(context);
    int? anon, anonPro, mine, minePro;
    if (app.anon.ready) {
      final res = await app.api.balance(await app.anon.signer());
      if (res.data['error'] == null) {
        anon = (res.data['balance'] as num?)?.toInt();
        anonPro = (res.data['proBalance'] as num?)?.toInt();
      }
    }
    final res = await app.api.balance(app.identity.signer);
    if (res.data['error'] == null) {
      mine = (res.data['balance'] as num?)?.toInt();
      minePro = (res.data['proBalance'] as num?)?.toInt();
    }
    if (!mounted) return;
    setState(() => _balances =
        (anon: anon, anonPro: anonPro, identity: mine, identityPro: minePro));
  }

  Future<void> _move() async {
    final app = AppScope.read(context);
    if (!app.anon.enabled) {
      setState(() {
        _status = t('Turn anonymous mode on first.');
        _warn = true;
      });
      return;
    }
    setState(() {
      _status = t('Moving credits…');
      _warn = false;
    });
    try {
      final credited = await app.anon.moveCredits(
        app.identity.signer,
        int.tryParse(_amount.text) ?? 0,
        _tier,
      );
      if (!mounted) return;
      setState(() {
        // Four whole sentences rather than a stem plus a plural `s`: the
        // agreement rules differ per language and a stem cannot carry them.
        _status = _tier == 'pro'
            ? (credited == 1
                ? t('Moved 1 Pro credit onto the throwaway key.')
                : t('Moved {n} Pro credits onto the throwaway key.', {'n': credited}))
            : (credited == 1
                ? t('Moved 1 credit onto the throwaway key.')
                : t('Moved {n} credits onto the throwaway key.', {'n': credited}));
        _warn = false;
        _amount.clear();
      });
      await _loadBalances();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e is StateError ? e.message : 'Could not move credits.';
        _warn = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final b = _balances;
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
            Text(t('Anonymous chat'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Your chat is already end-to-end encrypted, but Nymbot still sees '
              'which pubkey is talking to it. Turn this on and every message, and '
              'every reply, travels under a throwaway key generated on this '
              'device. Credits move across as blind vouchers Nymbot signs without '
              'seeing, so its own records cannot link the two.'),
              style: TextStyle(fontSize: 12),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: app.anon.enabled,
              title: Text(t('Route new chats through a throwaway key'),
                  style: TextStyle(fontSize: 13)),
              onChanged: (v) async {
                await app.setAnonEnabled(v);
                if (mounted) setState(() {});
                await _loadBalances();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: app.settings.anonAutoTop,
              title: Text(t('Keep it topped up automatically'),
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                t('When the throwaway key runs low, move credits across without '
                    'asking. Same blind vouchers, same unlinkability — it just '
                    'saves doing it by hand before every chat.'),
                style: const TextStyle(fontSize: 11),
              ),
              onChanged: (v) async {
                app.settings.anonAutoTop = v;
                await app.saveSettings(app.settings);
                if (v) {
                  final messenger = ScaffoldMessenger.of(context);
                  final moved = await app.autoTopUp();
                  if (moved != null) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(app.describeTopUp(moved))),
                    );
                  }
                }
                await _loadBalances();
              },
            ),
            if (app.settings.anonAutoTop) ...[
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: '${app.settings.anonAutoTopFloor}',
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: t('Top up below')),
                      onChanged: (v) {
                        final n = int.tryParse(v) ?? 0;
                        app.settings.anonAutoTopFloor = n < 0 ? 0 : n;
                        app.saveSettings(app.settings);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      initialValue: '${app.settings.anonAutoTopAmount}',
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: t('Move each time')),
                      onChanged: (v) {
                        final n = int.tryParse(v) ?? 1;
                        app.settings.anonAutoTopAmount = n < 1 ? 1 : n;
                        app.saveSettings(app.settings);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: app.settings.anonAutoTopTier,
                decoration: InputDecoration(labelText: t('Which balance')),
                items: [
                  DropdownMenuItem(
                      value: 'both', child: Text(t('Standard and Pro'))),
                  DropdownMenuItem(
                      value: 'standard', child: Text(t('Standard only'))),
                  DropdownMenuItem(value: 'pro', child: Text(t('Pro only'))),
                ],
                onChanged: (v) async {
                  app.settings.anonAutoTopTier = v ?? 'both';
                  await app.saveSettings(app.settings);
                },
              ),
              const SizedBox(height: 10),
            ],
            if (b != null) ...[
              Text(
                  t('Your nym: {standard} standard · {pro} Pro',
                      {'standard': b.identity ?? '–', 'pro': b.identityPro ?? '–'}),
                  style: const TextStyle(fontSize: 12)),
              Text(
                  t('Throwaway key: {standard} standard · {pro} Pro',
                      {'standard': b.anon ?? '–', 'pro': b.anonPro ?? '–'}),
                  style: const TextStyle(fontSize: 12)),
            ] else
              Text(t('Checking balances…'), style: TextStyle(fontSize: 12)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: t('Credits')),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _tier,
                  items: [
                    DropdownMenuItem(value: 'standard', child: Text(t('Standard'))),
                    DropdownMenuItem(value: 'pro', child: Text(t('Pro'))),
                  ],
                  onChanged: (v) => setState(() => _tier = v ?? 'standard'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _move, child: Text(t('Move'))),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t('Spends that many credits from your nym and mints the same value '
              'onto the throwaway key. Nymbot signs the vouchers blind, so it '
              'cannot match what it spent to what it later accepts.'),
              style: TextStyle(fontSize: 11),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _warn ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(t('Rotate the throwaway key?')),
                    content: Text(
                      t('Its balance moves across, which shows Nymbot one anonymous '
                      'key paying another.'),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(t('Cancel'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(t('Rotate'))),
                    ],
                  ),
                );
                if (ok != true) return;
                await app.anon.rotate();
                await _loadBalances();
              },
              child: Text(t('Rotate the key')),
            ),
          ],
        ),
      ),
    );
  }
}
