import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../state/app_controller.dart';
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
  final _nsec = TextEditingController();
  bool _importing = false;
  bool _revealing = false;
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
      setState(() => _revealing = true);
    } catch (e) {
      setState(() => _error = t('Could not create a key.'));
    }
  }

  Future<void> _import() async {
    final app = AppScope.read(context);
    try {
      await app.identity.import(_nsec.text);
      app.signIn();
    } catch (e) {
      setState(() => _error = e is FormatException
          ? e.message
          : t('That key could not be read.'));
    }
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
            FilledButton(onPressed: _import, child: Text(t('Sign in'))),
            TextButton(
              onPressed: () => setState(() => _importing = false),
              child: Text(t('Back')),
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
