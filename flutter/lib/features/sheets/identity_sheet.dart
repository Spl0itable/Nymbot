import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';

Future<void> showIdentitySheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _IdentitySheet(),
    );

class _IdentitySheet extends StatefulWidget {
  const _IdentitySheet();

  @override
  State<_IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends State<_IdentitySheet> {
  final _link = TextEditingController();
  bool _showNsec = false;
  // The recovery code derives the post-quantum key, so it grants the account
  // the same way the nsec does and is covered the same way — a shoulder or a
  // screen share reads one as easily as the other.
  bool _showRoot = false;
  String? _status;
  bool _warn = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Copied.'))));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final identity = app.identity;

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
            Text('Identity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Your key lives on this device and nowhere else.'),
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            _row(
              t('Public key (npub)'),
              identity.npub,
              actions: [
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copy(identity.npub),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row(
              t('Public key (hex)'),
              identity.pubkey,
              actions: [
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copy(identity.pubkey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t('Both are the same key in two spellings, and both are safe to '
                  'share — they are how somebody addresses you.'),
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 12),
            _row(
              t('Private key (nsec)'),
              _showNsec ? identity.nsec : '•' * 24,
              actions: [
                IconButton(
                  icon: Icon(_showNsec ? Icons.visibility_off : Icons.visibility, size: 18),
                  tooltip: _showNsec ? t('Hide') : t('Show'),
                  onPressed: () => setState(() => _showNsec = !_showNsec),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copy(identity.nsec),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row(
              t('Post-quantum recovery code'),
              _showRoot ? identity.rootCode : '•' * 24,
              actions: [
                IconButton(
                  icon: Icon(_showRoot ? Icons.visibility_off : Icons.visibility,
                      size: 18),
                  tooltip: _showRoot ? t('Hide') : t('Show'),
                  onPressed: () => setState(() => _showRoot = !_showRoot),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copy(identity.rootCode),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              identity.rootLocked
                  ? t('This account already advertises another device\'s key. Paste '
                      'that device\'s code below to link this one; until then '
                      'replies come back without the post-quantum layer.')
                  : t('Paste this into another device — or into Nymchat — so both '
                      'hold the same post-quantum key.'),
              style: TextStyle(
                fontSize: 11,
                color: identity.rootLocked ? NymbotColors.lightning : null,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _link,
              decoration: InputDecoration(
                labelText: t('Link this device to an existing code'),
                hintText: 'nympq1…',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                try {
                  await identity.adoptRootCode(_link.text);
                  final kem = identity.kem;
                  if (kem != null) {
                    await app.pq
                        .announce(identity.signer, kem, epoch: identity.epoch);
                  }
                  if (!mounted) return;
                  setState(() {
                    _status = t('Linked. This device now derives the same '
                        'post-quantum key.');
                    _warn = false;
                    _link.clear();
                  });
                } catch (_) {
                  if (!mounted) return;
                  setState(() {
                    _status = t('That does not look like a recovery code.');
                    _warn = true;
                  });
                }
              },
              child: Text(t('Link')),
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
            const Divider(height: 32),
            TextButton(
              onPressed: () => _transfer(app),
              child: Text(t('Move my whole balance…')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: NymbotColors.danger),
              onPressed: () => _wipe(app),
              child: Text(t('Wipe this device')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {required List<Widget> actions}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  maxLines: 2,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              ...actions,
            ],
          ),
        ],
      );

  Future<void> _transfer(AppController app) async {
    final controller = TextEditingController();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Move your whole balance')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: t('Recipient public key'),
            hintText: t('64 hex characters'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(t('Move')),
          ),
        ],
      ),
    );
    if (target == null || target.isEmpty) return;
    final res = await app.api.transferCredits(app.identity.signer, target.toLowerCase());
    if (!mounted) return;
    setState(() {
      _status = (res.data['error'] as String?) ?? t('Moved.');
      _warn = res.data['error'] != null;
    });
    await app.refreshBalance();
  }

  Future<void> _wipe(AppController app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Wipe this device?')),
        content: Text(
          t('Your key, every conversation, and any credits on a throwaway key. '
          'This cannot be undone.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Wipe')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.wipe();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }
}
