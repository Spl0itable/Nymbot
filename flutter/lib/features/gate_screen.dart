import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../services/nostr/event_signer.dart';
import '../state/app_controller.dart';
import '../state/identity.dart';
import 'i18n/i18n.dart';

const String nymbotWordmark = r'''
                                  ##\                  ##\
                                  ## |                 ## |
#######\  ##\   ##\ ######\####\  #######\   ######\ ######\
##  __##\ ## |  ## |##  _##  _##\ ##  __##\ ##  __##\\_##  _|
## |  ## |## |  ## |## / ## / ## |## |  ## |## /  ## | ## |
## |  ## |## |  ## |## | ## | ## |## |  ## |## |  ## | ## |##\
## |  ## |\####### |## | ## | ## |#######  |\######  | \####  |
\__|  \__| \____## |\__| \__| \__|\_______/  \______/   \____/
          ##\   ## |
          \######  |
           \______/''';

/// Onboarding, and the one-time reveal of the two things nobody can reissue.
class GateScreen extends StatefulWidget {
  const GateScreen({super.key});

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  /// How far to look for the epoch an account's announced key sits at.
  static const int _epochScan = 12;

  final _nsec = TextEditingController();
  bool _importing = false;
  bool _revealing = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nsec.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final app = AppScope.read(context);
    try {
      await app.identity.generate();
      // A key nobody has seen before cannot already have a root, so there is
      // nothing to ask D1 — only a row to write, so the next device to sign in
      // finds it and asks for the code instead of minting a second one.
      final root = app.identity.root;
      if (root != null) {
        unawaited(app.storage
            .publishPqRootRecord(app.identity.signer, root)
            .catchError((_) => false));
      }
      setState(() => _revealing = true);
    } catch (e) {
      setState(() => _error = t('Could not create a key.'));
    }
  }

  /// Signing in with a key that has been used before.
  ///
  /// The account is asked what it already holds BEFORE this device decides what
  /// post-quantum root to give it: minting one unasked is wrong for a key that
  /// has been used, since the announcement is replaceable and a second root
  /// published over the first strands every settings row, every synced
  /// conversation and every reply sealed to the one it replaced.
  Future<void> _import() async {
    final app = AppScope.read(context);
    Uint8List sk;
    try {
      sk = app.identity.readSecret(_nsec.text);
    } catch (e) {
      setState(() => _error =
          e is FormatException ? e.message : t('That key could not be read.'));
      return;
    }

    setState(() {
      _error = null;
      _busy = true;
    });
    final AccountRoot probe;
    try {
      probe = await app.probeAccountRoot(LocalSigner(sk));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    if (!probe.present && probe.announced == null) {
      try {
        await app.identity.import(_nsec.text);
      } catch (e) {
        setState(() => _error = t('That key could not be read.'));
        return;
      }
      if (!mounted) return;
      // Neither source answered. Minting waits — a second root published over
      // the first strands every settings row, every synced conversation and
      // every reply sealed to the one it replaced. Sign in without one; the
      // first launch that reaches the worker settles it. Not locked either:
      // nothing says the account HAS a root, only that nobody could be asked.
      if (!probe.read) {
        app.identity.rootLocked = false;
        app.signIn();
        return;
      }
      // D1 answered and holds nothing, and the relays advertise nothing: a key
      // that has never used Nymbot or Nymchat. One is minted now and shown, the
      // same reveal a brand new key gets, because it is the same thing to lose.
      await app.mintAndRecordRoot();
      if (!mounted) return;
      setState(() => _revealing = true);
      return;
    }

    final linked = await _askForCode(probe);
    if (!mounted) return;
    try {
      await app.identity.import(
        _nsec.text,
        root: linked?.root,
        epoch: linked?.epoch ?? 0,
      );
    } catch (e) {
      setState(() => _error = t('That key could not be read.'));
      return;
    }
    app.signIn();
  }

  /// The prompt: this account already has a root, and this device does not have
  /// it. Null when the user carried on without it — signed in, nothing minted,
  /// and the code can be pasted in Identity later.
  Future<({Uint8List root, int epoch})?> _askForCode(AccountRoot probe) async {
    final field = TextEditingController();
    String? error;
    final result = await showDialog<({Uint8List root, int epoch})?>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => AlertDialog(
          title: Text(t('This key already has a post-quantum root')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('Your settings and conversations are sealed to it, and '
                    'so are your replies. Paste the recovery code from the '
                    'device that made it — Identity → Post-quantum root, in '
                    'Nymbot or Nymchat.\n\nWithout it this device can still '
                    'chat, but it cannot open anything the other one saved.')),
                const SizedBox(height: 14),
                TextField(
                  controller: field,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: t('Recovery code'),
                    hintText: 'nympq1…',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text(t('Carry on without it')),
            ),
            FilledButton(
              onPressed: () {
                final typed = field.text.trim();
                // Either way of saying "not now".
                if (typed.isEmpty) {
                  Navigator.of(context).pop(null);
                  return;
                }
                final checked = _checkCode(typed, probe);
                if (checked == null) {
                  setSheet(() => error = _codeError(typed, probe));
                  return;
                }
                Navigator.of(context).pop(checked);
              },
              child: Text(t('Link this device')),
            ),
          ],
        ),
      ),
    );
    field.dispose();
    return result;
  }

  /// The root a pasted code carries, once it is the one this account uses, and
  /// the epoch of it the account currently advertises.
  ({Uint8List root, int epoch})? _checkCode(String typed, AccountRoot probe) {
    final root = Identity.rootFromCode(typed);
    if (root == null) return null;
    // The record is the account's own statement of which root it uses: exact,
    // and epoch-free.
    final recorded = probe.fingerprint;
    if (recorded != null && Identity.fingerprintOfCode(typed) != recorded) {
      return null;
    }
    // The root is one thing; which epoch of it the account currently advertises
    // is another.
    final announced = probe.announced;
    if (announced != null) {
      for (var epoch = 0; epoch <= _epochScan; epoch++) {
        final derived = Identity.kemForCode(typed, epoch);
        if (derived != null && _sameBytes(derived, announced)) {
          return (root: root, epoch: epoch);
        }
      }
      if (recorded == null) return null;
    }
    return (root: root, epoch: 0);
  }

  String _codeError(String typed, AccountRoot probe) {
    if (Identity.rootFromCode(typed) == null) {
      return t('That is not a recovery code. It starts with nympq1.');
    }
    if (probe.fingerprint != null) {
      return t('That code does not match the root this account recorded. '
          'Check you copied it from the right account.');
    }
    return t('That code does not match the key this account advertises. '
        'Check you copied it from the right account.');
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: _revealing ? _reveal(app) : _welcome(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wordmark(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          nymbotWordmark,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 5.6,
            height: 1.06,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _welcome() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _wordmark(context),
          const SizedBox(height: 20),
          Text(
            t('A private AI assistant. There is no account to make — a key on this '
            'device is the whole of it.'),
          ),
          const SizedBox(height: 20),
          if (!_importing) ...[
            FilledButton(onPressed: _generate, child: Text(t('Create a key'))),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => setState(() => _importing = true),
              child: Text(t('I already have one')),
            ),
          ] else ...[
            TextField(
              controller: _nsec,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: t('Your private key'),
                hintText: 'nsec1…',
              ),
              onSubmitted: (_) => _import(),
            ),
            const SizedBox(height: 6),
            Text(
              t('The same key you use in Nymchat, or any other Nostr app. It stays '
              'on this device.'),
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _import,
              child: Text(t('Sign in')),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _importing = false),
              child: Text(t('Back')),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            Text(
              t('Checking whether this key already has a post-quantum root…'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: NymbotColors.danger)),
          ],
        ],
      );

  Widget _reveal(AppController app) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Back these up now'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            t('Nobody can reissue either of these — not even us. Without them, this '
            'identity, its history and any credits on it are gone.'),
          ),
          const SizedBox(height: 18),
          _copyRow(t('Private key (nsec)'), app.identity.nsec),
          const SizedBox(height: 14),
          _copyRow(t('Post-quantum recovery code'), app.identity.rootCode),
          const SizedBox(height: 6),
          Text(
            t('The second one seeds the key that makes your messages '
            'quantum-resistant. Paste it into another device — or into Nymchat — '
            'to link it to this account.'),
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: app.signIn,
            child: Text(t('I have saved them')),
          ),
        ],
      );

  Widget _copyRow(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: t('Copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t('Copied.'))),
                  );
                },
              ),
            ],
          ),
        ],
      );
}
