import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../config.dart';
import '../core/theme/theme.dart';
import '../services/nickname.dart';
import '../services/nostr/event_signer.dart';
import '../services/nostr/nip46.dart';
import '../services/nostr/nip55.dart';
import '../state/app_controller.dart';
import '../state/identity.dart';
import 'i18n/i18n.dart';
import 'secret_guard.dart';

const String nymbotWordmark = r'''                                  ##\                  ##\
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
  final _nickname = TextEditingController();
  bool _importing = false;
  bool _revealing = false;
  bool _busy = false;
  String? _error;
  final _bunker = TextEditingController();
  final _relay = TextEditingController(text: nip46DefaultRelay);
  bool _remoteOpen = false;
  Nip46Signer? _offer;
  String? _signerStatus;

  @override
  void dispose() {
    _nsec.dispose();
    _nickname.dispose();
    _bunker.dispose();
    _relay.dispose();
    _dropOffer();
    super.dispose();
  }

  void _dropOffer() {
    final offer = _offer;
    _offer = null;
    if (offer != null) unawaited(offer.close());
  }

  void _openAuth(String url) {
    unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
        .catchError((_) => false));
  }

  String _signerError(Object e) =>
      e is SignerFailure ? e.message : t('Could not connect to your signer.');

  Future<void> _connectBunker() async {
    if (_busy) return;
    final app = AppScope.read(context);
    _dropOffer();
    setState(() {
      _error = null;
      _busy = true;
      _signerStatus = t('Waiting for your signer…');
    });
    Nip46Signer signer;
    try {
      signer = await Nip46Signer.bunker(_bunker.text,
          sockets: app.signerSockets, onAuthUrl: _openAuth);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _signerStatus = null;
          _error = _signerError(e);
        });
      }
      return;
    }
    if (!mounted) {
      unawaited(signer.close());
      return;
    }
    await _useSigner(signer);
  }

  Future<void> _showConnectCode() async {
    final app = AppScope.read(context);
    _dropOffer();
    Nip46Signer offer;
    try {
      offer = Nip46Signer.offer(
          relays: [_relay.text], sockets: app.signerSockets);
    } catch (e) {
      setState(() => _error = _signerError(e));
      return;
    }
    offer.onAuthUrl = _openAuth;
    setState(() {
      _offer = offer;
      _error = null;
      _signerStatus = t('Waiting for your signer…');
    });
    try {
      await offer.waitForSigner();
    } catch (e) {
      if (!mounted || !identical(_offer, offer)) return;
      _dropOffer();
      setState(() {
        _signerStatus = null;
        _error = _signerError(e);
      });
      return;
    }
    if (!mounted || !identical(_offer, offer)) return;
    _offer = null;
    setState(() => _busy = true);
    await _useSigner(offer);
  }

  Future<void> _connectApp() async {
    if (_busy) return;
    _dropOffer();
    setState(() {
      _error = null;
      _busy = true;
      _signerStatus = t('Waiting for your signer…');
    });
    Nip55Signer signer;
    try {
      final apps = await Nip55Signer.apps();
      if (apps.isEmpty) {
        throw SignerFailure(t('No signer app is installed. Install one such as Amber, then try again.'));
      }
      final chosen = apps.length == 1 ? apps.single : await _pickApp(apps);
      if (chosen == null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _signerStatus = null;
          });
        }
        return;
      }
      signer = await Nip55Signer.connect(package: chosen.package);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _signerStatus = null;
          _error = _signerError(e);
        });
      }
      return;
    }
    if (!mounted) return;
    await _useSigner(signer);
  }

  Future<SignerApp?> _pickApp(List<SignerApp> apps) => showDialog<SignerApp>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t('Choose a signer app')),
          children: [
            for (final app in apps)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(app),
                child: Text(app.name),
              ),
          ],
        ),
      );

  void _cancelSigner() {
    _dropOffer();
    setState(() {
      _signerStatus = null;
      _busy = false;
    });
  }

  Future<void> _useSigner(RemoteSigner remote) async {
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _signerStatus = null;
    });
    final AccountRoot probe;
    try {
      probe = await app.probeAccountRoot(
          QueuedSigner(remote, waiting: app.identity.waiting));
    } catch (e) {
      unawaited(remote.close());
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _signerError(e);
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) {
      unawaited(remote.close());
      return;
    }
    if (!probe.present && probe.announced == null) {
      await app.identity.useSigner(remote);
      await _takeNickname(app);
      if (!mounted) return;
      if (!probe.read) {
        app.identity.rootLocked = false;
        app.signIn();
        return;
      }
      await app.mintAndRecordRoot();
      if (!mounted) return;
      setState(() => _revealing = true);
      return;
    }
    final linked = await _askForCode(probe);
    if (!mounted) {
      unawaited(remote.close());
      return;
    }
    await app.identity.useSigner(remote,
        root: linked?.root, epoch: linked?.epoch ?? 0);
    await _takeNickname(app);
    app.signIn();
  }

  Future<void> _takeNickname(AppController app) async {
    final value = Nickname.clean(_nickname.text);
    _nickname.clear();
    if (value.isNotEmpty) await app.setNickname(value);
  }

  Future<void> _generate() async {
    if (_busy) return;
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await app.identity.generate();
      await _takeNickname(app);
      // A key nobody has seen before cannot already have a root, so there is
      // nothing to ask D1 — only a row to write, so the next device to sign in
      // finds it and asks for the code instead of minting a second one.
      final root = app.identity.root;
      if (root != null) {
        unawaited(app.storage
            .publishPqRootRecord(app.identity.signer, root)
            .catchError((_) => false));
      }
      if (mounted) setState(() => _revealing = true);
    } catch (e) {
      if (mounted) setState(() => _error = t('Could not create a key.'));
    } finally {
      if (mounted) setState(() => _busy = false);
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
      await _takeNickname(app);
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
    await _takeNickname(app);
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

  Widget _wordmark(BuildContext context) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            nymbotWordmark,
            textAlign: TextAlign.left,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 10,
              height: 1.08,
              letterSpacing: 0,
              color: Theme.of(context).colorScheme.primary,
            ),
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
          TextField(
            key: const ValueKey('gate-nickname'),
            controller: _nickname,
            maxLength: Nickname.max,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: t('Nickname (optional)'),
              counterText: '',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t('What your messages are signed with. It stays private: it syncs between your devices encrypted, and is never published or sent to the model.'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (!_importing) ...[
            FilledButton(
                onPressed: _busy ? null : _generate,
                child: Text(t('Create a key'))),
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
            const SizedBox(height: 16),
            Text(
              t('Or keep your key in a signer and let Nymbot ask it:'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (Nip55Signer.supported) ...[
              OutlinedButton(
                key: const ValueKey('gate-signer-app'),
                onPressed: _busy ? null : _connectApp,
                child: Text(t('Connect a signer app')),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton(
              key: const ValueKey('gate-remote'),
              onPressed: _busy
                  ? null
                  : () => setState(() => _remoteOpen = !_remoteOpen),
              child: Text(t('Remote signer')),
            ),
            if (_remoteOpen) ..._remotePane(),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      _dropOffer();
                      setState(() {
                        _importing = false;
                        _remoteOpen = false;
                        _signerStatus = null;
                      });
                    },
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
          const SizedBox(height: 20),
          _agreement(context),
        ],
      );

  List<Widget> _remotePane() {
    final link = _offer?.connectUri;
    return [
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('gate-bunker'),
        controller: _bunker,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: t('Connection link from your signer'),
          hintText: 'bunker://…',
        ),
        onSubmitted: (_) => _connectBunker(),
      ),
      const SizedBox(height: 8),
      FilledButton.tonal(
        key: const ValueKey('gate-bunker-connect'),
        onPressed: _busy || link != null ? null : _connectBunker,
        child: Text(t('Connect')),
      ),
      const SizedBox(height: 14),
      Text(
        t('Or show a code for your signer to scan:'),
        style: const TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 6),
      TextField(
        key: const ValueKey('gate-relay'),
        controller: _relay,
        autocorrect: false,
        enableSuggestions: false,
        enabled: link == null && !_busy,
        decoration: InputDecoration(labelText: t('Relay')),
      ),
      const SizedBox(height: 8),
      if (link == null)
        OutlinedButton(
          key: const ValueKey('gate-show-code'),
          onPressed: _busy ? null : _showConnectCode,
          child: Text(t('Show a connection code')),
        )
      else ...[
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            color: Colors.white,
            child: QrImageView(
              data: link,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                link,
                key: const ValueKey('gate-connect-link'),
                maxLines: 3,
                style: const TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 11),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: t('Copy the link'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t('Copied.'))));
              },
            ),
          ],
        ),
      ],
      if (_signerStatus != null) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_signerStatus!,
                  key: const ValueKey('gate-signer-status'),
                  style: const TextStyle(fontSize: 12)),
            ),
            if (link != null)
              TextButton(
                key: const ValueKey('gate-signer-cancel'),
                onPressed: _cancelSigner,
                child: Text(t('Cancel')),
              ),
          ],
        ),
      ],
      const SizedBox(height: 8),
    ];
  }

  Widget _agreement(BuildContext context) {
    final faint = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    final style = TextStyle(fontSize: 12, color: faint);
    final link = style.copyWith(decoration: TextDecoration.underline);
    Widget linkTo(String label, String path) => Semantics(
          link: true,
          child: GestureDetector(
            onTap: () => launchUrl(Uri.parse('https://${NymbotConfig.apiHost}$path'),
                mode: LaunchMode.externalApplication),
            child: Text(label, style: link),
          ),
        );
    final spans = <InlineSpan>[];
    final template = t('By continuing you agree to the {terms} and {privacy}.');
    final parts = template.split(RegExp(r'(\{terms\}|\{privacy\})'));
    final marks = RegExp(r'\{terms\}|\{privacy\}').allMatches(template).map((m) => m.group(0)).toList();
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i]));
      if (i < marks.length) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: marks[i] == '{terms}'
              ? linkTo(t('Terms'), '/terms/')
              : linkTo(t('Privacy Policy'), '/privacy/'),
        ));
      }
    }
    return Text.rich(TextSpan(style: style, children: spans), textAlign: TextAlign.center);
  }

  Widget _reveal(AppController app) => SecretGuard(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(app.identity.hasNsec ? t('Back these up now') : t('Back this up now'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            app.identity.hasNsec
                ? t('Nobody can reissue either of these — not even us. Without them, this '
                    'identity, its history and any credits on it are gone.')
                : t('Nobody can reissue this — not even us. Your private key stays in your signer, so there is no nsec to back up here.'),
          ),
          const SizedBox(height: 18),
          if (app.identity.hasNsec) ...[
            _copyRow(t('Private key (nsec)'), app.identity.nsec),
            const SizedBox(height: 14),
          ],
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
      ));

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
                  style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 12),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: t('Copy'),
                onPressed: () async {
                  await SecretScreen.copy(value);
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
