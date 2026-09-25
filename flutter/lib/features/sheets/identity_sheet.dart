import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/theme.dart';
import '../../services/nickname.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import '../secret_guard.dart';
import '../vault_dialog.dart';
import 'gift_sheet.dart';
import 'sheet.dart';
import '../nym_glyph.dart';

Future<void> showIdentitySheet(BuildContext context) => showNymSheet<void>(
      context,
      (_) => const _IdentitySheet(),
    );

class _IdentitySheet extends StatefulWidget {
  const _IdentitySheet();

  @override
  State<_IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends State<_IdentitySheet> {
  final _link = TextEditingController();
  late final _nickname =
      TextEditingController(text: AppScope.read(context).nickname);
  String? _nicknameStatus;
  bool _showNsec = false;
  // The recovery code derives the post-quantum key, so it grants the account
  // the same way the nsec does and is covered the same way — a shoulder or a
  // screen share reads one as easily as the other.
  bool _showRoot = false;
  String? _status;
  bool _warn = false;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final ok = await AppScope.read(context).store.vault.biometrics.available();
    if (mounted && ok != _bioAvailable) setState(() => _bioAvailable = ok);
  }

  @override
  void dispose() {
    _link.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _saveNickname(AppController app, String value) async {
    final saved = await app.setNickname(value);
    if (!mounted) return;
    setState(() {
      _nickname.text = saved;
      _nicknameStatus = saved.isNotEmpty ? t('Nickname saved.') : t('Nickname cleared.');
    });
  }

  Future<void> _copy(String value, {bool secret = false}) async {
    if (secret) {
      await SecretScreen.copy(value);
    } else {
      await Clipboard.setData(ClipboardData(text: value));
    }
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
            if (_showNsec || _showRoot) const SecretGuard(),
            Text(t('Identity'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              identity.hasNsec
                  ? t('Your key lives on this device and nowhere else.')
                  : t('Your private key stays in your signer. This device asks it to sign and decrypt for you.'),
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            Text(
              t('Signed in with: {method}', {'method': signInMethodLabel(identity.method)}),
              key: const ValueKey('identity-method'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('identity-nickname'),
                    controller: _nickname,
                    maxLength: Nickname.max,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: t('Nickname'),
                      counterText: '',
                    ),
                    onSubmitted: (v) => _saveNickname(app, v),
                  ),
                ),
                TextButton(
                  key: const ValueKey('identity-nickname-save'),
                  onPressed: () => _saveNickname(app, _nickname.text),
                  child: Text(t('Save')),
                ),
                TextButton(
                  key: const ValueKey('identity-nickname-clear'),
                  onPressed: () => _saveNickname(app, ''),
                  child: Text(t('Clear')),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t('Shown on your messages and here instead of the generated name. Only you see it: it syncs between your devices end-to-end encrypted, and is never published or sent to the model. Anonymous chats always show Anon.'),
              style: const TextStyle(fontSize: 11),
            ),
            if (_nicknameStatus != null) ...[
              const SizedBox(height: 4),
              Text(_nicknameStatus!,
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).colorScheme.primary)),
            ],
            const SizedBox(height: 14),
            _row(
              t('Public key (npub)'),
              identity.npub,
              actions: [
                IconButton(
                  icon: const NymGlyph('copy', size: 18),
                  tooltip: t('Copy the npub'),
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
                  icon: const NymGlyph('copy', size: 18),
                  tooltip: t('Copy the hex key'),
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
            if (!identity.hasNsec) ...[
              Text(
                t('There is no nsec on this device to back up or export: it never leaves your signer. Back up your key there.'),
                key: const ValueKey('identity-no-nsec'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('identity-disconnect'),
                onPressed: () => _disconnect(app),
                child: Text(t('Disconnect signer…')),
              ),
            ] else ...[
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
                    icon: const NymGlyph('copy', size: 18),
                    tooltip: t('Copy the private key'),
                    onPressed: () => _copy(identity.nsec, secret: true),
                  ),
                ],
              ),
            ],
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
                  icon: const NymGlyph('copy', size: 18),
                  tooltip: t('Copy the recovery code'),
                  onPressed: () => _copy(identity.rootCode, secret: true),
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
                final code = _link.text.trim();
                if (code.isEmpty) return;
                setState(() {
                  _status = t('Checking the code against the account…');
                  _warn = false;
                });
                final verdict = await app.checkRootCode(code);
                if (!mounted) return;
                try {
                  if (verdict.status == 'invalid') {
                    throw const FormatException('not a code');
                  }
                  if (verdict.status == 'same') {
                    setState(() {
                      _status = t('This device already uses that code.');
                      _warn = false;
                    });
                    return;
                  }
                  if (verdict.status == 'mismatch') {
                    if (verdict.announcedOnly) {
                      setState(() {
                        _status = t('That code does not match the key this '
                            'account advertises. Check you copied it from '
                            'the right account.');
                        _warn = true;
                      });
                      return;
                    }
                    final replace = await _confirmReplace();
                    if (!mounted) return;
                    if (!replace) {
                      setState(() {
                        _status = t('That code does not match the root this '
                            'account recorded. Check you copied it from the '
                            'right account.');
                        _warn = true;
                      });
                      return;
                    }
                    final replaced = await app.replaceRootCode(code);
                    if (!mounted) return;
                    setState(() {
                      _status = replaced
                          ? t('Replaced. This account now uses the code you '
                              'pasted.')
                          : t('The code could not be saved to your account '
                              'right now. Check your connection and try '
                              'again.');
                      _warn = !replaced;
                      if (replaced) _link.clear();
                    });
                    return;
                  }
                  final linked = await app.linkRootCode(code, verdict);
                  if (!mounted) return;
                  if (!linked) throw const FormatException('not a code');
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
            Text(t('Identity encryption'),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              app.store.vault.biometric
                  ? t('On. Your saved key is encrypted, and Nymbot asks for your '
                      'biometrics each time it opens.')
                  : app.store.vault.enabled
                  ? t('On. Your saved key is encrypted, and Nymbot asks for your '
                      'passphrase each time it opens.')
                  : t("Off. Add a passphrase so your saved key can't be read "
                      'from this device without unlocking.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (!app.store.vault.enabled)
              OutlinedButton(
                key: const ValueKey('vault-enable'),
                onPressed: () => _vault(app, VaultAction.enable),
                child: Text(t('Turn on…')),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (app.store.vault.biometric)
                    OutlinedButton(
                      key: const ValueKey('vault-use-passphrase'),
                      onPressed: () => _vault(app, VaultAction.usePassphrase),
                      child: Text(t('Use a passphrase instead…')),
                    )
                  else ...[
                    OutlinedButton(
                      key: const ValueKey('vault-change'),
                      onPressed: () => _vault(app, VaultAction.change),
                      child: Text(t('Change passphrase…')),
                    ),
                    if (_bioAvailable)
                      OutlinedButton(
                        key: const ValueKey('vault-use-biometric'),
                        onPressed: () => _vault(app, VaultAction.useBiometric),
                        child: Text(t('Use biometrics instead…')),
                      ),
                  ],
                  TextButton(
                    key: const ValueKey('vault-disable'),
                    onPressed: () => _vault(app, VaultAction.disable),
                    child: Text(t('Turn off…')),
                  ),
                ],
              ),
            const Divider(height: 32),
            TextButton(
              key: const ValueKey('open-gift'),
              onPressed: () => showGiftSheet(context),
              child: Text(t('Gift an amount…')),
            ),
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
                  style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 12),
                ),
              ),
              ...actions,
            ],
          ),
        ],
      );

  Future<void> _vault(AppController app, VaultAction action) async {
    final done = await showVaultDialog(context, app.store.vault, action,
        biometricAvailable: _bioAvailable);
    if (!done || !mounted) return;
    setState(() {});
    final bio = app.store.vault.biometric;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (action) {
        VaultAction.enable when bio => t("Identity encryption is on. You'll be asked for "
            'your biometrics next time Nymbot opens.'),
        VaultAction.enable => t("Identity encryption is on. You'll be asked for "
            'your passphrase next time Nymbot opens.'),
        VaultAction.change => t('Passphrase changed.'),
        VaultAction.disable => t('Identity encryption is off.'),
        VaultAction.useBiometric => t('Nymbot will ask for your biometrics from now on.'),
        VaultAction.usePassphrase => t('Nymbot will ask for your passphrase from now on.'),
      }),
    ));
  }

  Future<void> _transfer(AppController app) async {
    final said = await moveWholeBalance(context, app);
    if (said == null || !mounted) return;
    setState(() {
      _status = said.message;
      _warn = !said.ok;
    });
  }

  Future<bool> _confirmReplace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Replace the recovery code?')),
        content: Text(
          t('This code does not match the recovery code the account currently '
              'uses.\n\nIf the current code was created by mistake, you can '
              'replace it with this one. Every device on this account — Nymbot '
              'or Nymchat — will then need this code, and anything sealed to '
              'the current code stays readable only on devices that still '
              'hold it.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Keep the current code'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Replace')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _disconnect(AppController app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Disconnect your signer?')),
        content: Text(t('This device forgets the connection and everything it saved. Your synced settings and conversations stay with your account and come back when you sign in again. Keep your post-quantum recovery code: you will need it on the way back in.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Disconnect')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await app.disconnectSigner();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
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

String signInMethodLabel(String method) => switch (method) {
      'nip46' => t('Remote signer (NIP-46)'),
      'nip55' => t('Signer app (NIP-55)'),
      _ => t('Private key on this device'),
    };

String? pubkeyFrom(String text) {
  final raw = text.trim();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) return raw.toLowerCase();
  if (raw.toLowerCase().startsWith('npub1')) {
    try {
      return decodeNpub(raw.toLowerCase());
    } catch (_) {
      return null;
    }
  }
  return null;
}

Future<({bool ok, String message})?> moveWholeBalance(
    BuildContext context, AppController app,
    {String prefill = ''}) async {
  final controller = TextEditingController(text: prefill);
  final target = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t('Move your whole balance')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Every credit on this key moves to the key you name. There is '
              'no undo.')),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: t('Recipient public key'),
              hintText: t('npub, or 64 hex characters'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(t('Move')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (target == null || target.isEmpty) return null;
  final key = pubkeyFrom(target);
  if (key == null) {
    return (
      ok: false,
      message: t('That is not a public key. Paste an npub or a 64-character '
          'hex key.'),
    );
  }
  final res = await app.api.transferCredits(app.identity.signer, key);
  await app.refreshBalance();
  final error = res.data['error'] as String?;
  return (ok: error == null, message: error ?? t('Moved.'));
}
