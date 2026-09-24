import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../state/app_controller.dart';
import '../state/store.dart';
import '../state/vault.dart';
import 'gate_screen.dart';
import 'i18n/i18n.dart';

class LockedApp extends StatefulWidget {
  const LockedApp({super.key, required this.store, this.boot});

  final Store store;
  final Future<AppController> Function(Store store)? boot;

  @override
  State<LockedApp> createState() => _LockedAppState();
}

class _LockedAppState extends State<LockedApp> {
  AppController? _controller;

  Future<AppController> _boot() =>
      (widget.boot ?? (store) => AppController.boot(store: store))(widget.store);

  Future<void> _unlock(String passphrase) async {
    await widget.store.vault.unlock(passphrase);
    final controller = await _boot();
    if (mounted) setState(() => _controller = controller);
  }

  Future<void> _unlockBiometric() async {
    await widget.store.vault.unlockBiometric();
    final controller = await _boot();
    if (mounted) setState(() => _controller = controller);
  }

  Future<void> _forget() async {
    await widget.store.wipe();
    await I18n.load();
    final controller = await _boot();
    if (mounted) setState(() => _controller = controller);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) return NymbotApp(controller: controller);
    final settings = widget.store.settings();
    return MaterialApp(
      title: 'Nymbot',
      debugShowCheckedModeBanner: false,
      theme: nymbotTheme(Brightness.light),
      darkTheme: nymbotTheme(Brightness.dark, palette: paletteFor(settings)),
      themeMode: themeModeFor(settings),
      locale: appLocale(),
      supportedLocales: appLocales(),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => appFrame(context, child, settings),
      home: UnlockScreen(
        onUnlock: _unlock,
        onForget: _forget,
        onBiometric: widget.store.vault.biometric ? _unlockBiometric : null,
      ),
    );
  }
}

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({
    super.key,
    required this.onUnlock,
    required this.onForget,
    this.onBiometric,
  });

  final Future<void> Function(String passphrase) onUnlock;
  final Future<void> Function() onForget;
  final Future<void> Function()? onBiometric;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passphrase = TextEditingController();
  bool _busy = false;
  bool _invalidated = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    final passphrase = _passphrase.text;
    if (passphrase.isEmpty) {
      setState(() => _error = t('Enter your passphrase.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onUnlock(passphrase);
    } on VaultWrongPassphrase {
      _passphrase.clear();
      if (mounted) setState(() => _error = t('Wrong passphrase. Try again.'));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockBiometric() async {
    final unlock = widget.onBiometric;
    if (_busy || unlock == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await unlock();
    } on VaultBiometricInvalidated catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _invalidated = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_invalidated && mounted) await _forget();
  }

  Future<void> _forget() async {
    final bio = widget.onBiometric != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Forget this identity?')),
        content: Text(
          bio
              ? t('Without your biometrics, the encrypted key on this device cannot be '
                  'recovered. Starting over permanently deletes it and everything '
                  'else Nymbot keeps on this device. If you saved your nsec '
                  'somewhere else, you can sign back in with it afterwards.')
              : t('Without the passphrase, the encrypted key on this device cannot be '
                  'recovered. Starting over permanently deletes it and everything '
                  'else Nymbot keeps on this device. If you saved your nsec '
                  'somewhere else, you can sign back in with it afterwards.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Delete and start over')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await widget.onForget();
  }

  @override
  Widget build(BuildContext context) {
    final bio = widget.onBiometric != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        nymbotWordmark,
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
                  ),
                  const SizedBox(height: 20),
                  Text(t('Unlock your identity'),
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(bio
                      ? t('Your Nymbot identity is encrypted on this device. '
                          'Use your biometrics to unlock it.')
                      : t('Your Nymbot identity is encrypted on this device. '
                          'Enter your passphrase to unlock it.')),
                  const SizedBox(height: 16),
                  if (!bio)
                    TextField(
                      key: const ValueKey('vault-unlock-passphrase'),
                      controller: _passphrase,
                      autofocus: true,
                      obscureText: true,
                      enabled: !_busy,
                      keyboardType: TextInputType.visiblePassword,
                      onSubmitted: (_) => _unlock(),
                      decoration: InputDecoration(labelText: t('Passphrase')),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(_error!,
                          style: const TextStyle(color: NymbotColors.danger)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('vault-unlock'),
                    onPressed: _busy
                        ? null
                        : _invalidated
                            ? _forget
                            : (bio ? _unlockBiometric : _unlock),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : _invalidated
                            ? Text(t('Can\'t unlock?'))
                            : bio
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.fingerprint, size: 18),
                                  const SizedBox(width: 8),
                                  Text(t('Unlock with biometrics')),
                                ],
                              )
                            : Text(t('Unlock')),
                  ),
                  if (!_invalidated) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _forget,
                      child: Text(bio ? t('Can\'t unlock?') : t('Forgot your passphrase?')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
