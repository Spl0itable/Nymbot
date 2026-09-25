
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/theme.dart';
import '../services/key_backup.dart';
import '../services/passkey_backup.dart';
import 'brand_buttons.dart';
import 'i18n/i18n.dart';

typedef BackupStatusSink = void Function(String? text, {bool spin});

String removeBackupsLabel(BackupProvider provider) => switch (provider) {
      BackupProvider.google => t('Remove Google backups'),
      BackupProvider.apple => t('Remove Apple backups'),
    };

String signingInWith(BackupProvider provider) =>
    t('Signing in with {provider}…', {'provider': provider.label});

String backupErrorMessage(Object error) => error is BackupFailure
    ? error.message
    : t('The backup could not be reached. Check your connection and try again.');

class ProviderButton extends StatelessWidget {
  const ProviderButton({
    super.key,
    required this.provider,
    required this.onPressed,
  });

  final BackupProvider provider;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => switch (provider) {
        BackupProvider.google => GoogleButton(onPressed: onPressed),
        BackupProvider.apple => AppleButton(onPressed: onPressed),
      };
}

class BackupStatusLine extends StatelessWidget {
  const BackupStatusLine(this.text, {super.key, this.spin = false});

  final String text;
  final bool spin;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          if (spin) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(text,
                key: const ValueKey('backup-status'),
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      );
}

Future<String?> askBackupPin(BuildContext context, BackupProvider provider,
        {String? error}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PinDialog(provider: provider, confirm: false, error: error),
    );

Future<String?> chooseBackupPin(BuildContext context, BackupProvider provider,
        {String? intro}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PinDialog(provider: provider, confirm: true, intro: intro),
    );

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.provider,
    required this.confirm,
    this.intro,
    this.error,
  });

  final BackupProvider provider;
  final bool confirm;
  final String? intro;
  final String? error;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  late String? _error = widget.error;

  @override
  void dispose() {
    _pin.clear();
    _again.clear();
    _pin.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pin.text;
    if (!isValidBackupPin(pin)) {
      setState(() => _error = t('Use 4 to 8 digits.'));
      return;
    }
    if (widget.confirm && _again.text != pin) {
      setState(() => _error = t('The two PINs do not match.'));
      return;
    }
    Navigator.of(context).pop(pin);
  }

  Widget _field(TextEditingController controller, String label, Key key,
          {bool last = false}) =>
      TextField(
        key: key,
        controller: controller,
        autofocus: !last,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.number,
        maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, counterText: ''),
        onSubmitted: (_) => last || !widget.confirm ? _submit() : null,
      );

  @override
  Widget build(BuildContext context) {
    final provider = {'provider': widget.provider.label};
    return AlertDialog(
      title: Text(widget.confirm ? t('Choose a backup PIN') : t('Enter your backup PIN')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.intro != null) ...[
              Text(widget.intro!),
              const SizedBox(height: 10),
            ],
            if (widget.confirm) ...[
              Text(t('Your key stays yours. {provider} only stores an encrypted '
                  'copy, which it cannot read without this PIN.', provider)),
              const SizedBox(height: 10),
              Text(
                t('This PIN cannot be recovered. If you forget it, the backup '
                    'cannot be opened. Anyone who has both your {provider} '
                    'account and this PIN can get your key.', provider),
                key: const ValueKey('backup-pin-warning'),
                style: const TextStyle(color: NymbotColors.danger),
              ),
            ] else
              Text(t('Enter the PIN you chose when you backed up your key to '
                  '{provider}.', provider)),
            const SizedBox(height: 12),
            _field(_pin, t('PIN (4 to 8 digits)'), const ValueKey('backup-pin'),
                last: !widget.confirm),
            if (widget.confirm)
              _field(_again, t('PIN again'), const ValueKey('backup-pin-again'),
                  last: true),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  key: const ValueKey('backup-pin-error'),
                  style: const TextStyle(color: NymbotColors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(t('Cancel')),
        ),
        FilledButton(
          key: const ValueKey('backup-pin-ok'),
          onPressed: _submit,
          child: Text(widget.confirm ? t('Set PIN') : t('Unlock')),
        ),
      ],
    );
  }
}

Future<BackupCandidate?> pickBackupKey(BuildContext context,
        BackupProvider provider, List<BackupCandidate> candidates) =>
    showDialog<BackupCandidate>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t('Choose a key')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              t('More than one key in your {provider} account opens with this '
                  'PIN. Pick the one to sign in with.',
                  {'provider': provider.label}),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          for (final candidate in candidates)
            SimpleDialogOption(
              key: ValueKey('backup-candidate-${candidate.pubkey}'),
              onPressed: () => Navigator.of(context).pop(candidate),
              child: Text(
                candidate.shortNpub,
                style: const TextStyle(
                    fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback),
              ),
            ),
        ],
      ),
    );

Future<bool> confirmBackupAction(BuildContext context,
    {required String title,
    required String body,
    required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel'))),
        FilledButton(
          key: const ValueKey('backup-confirm'),
          style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<List<BackupCandidate>?> unlockBackups(
  BuildContext context, {
  required KeyBackups backups,
  required BackupProvider provider,
  required String accountId,
  required List<StoredBackup> files,
  required BackupStatusSink status,
  bool Function(BackupCandidate candidate)? keep,
  String? wrongPin,
}) async {
  String? error;
  while (true) {
    final wait = backups.throttle.wait;
    if (wait > Duration.zero) {
      final seconds = (wait.inMilliseconds / 1000).ceil();
      status(t('Wrong PIN. Try again in {n} seconds.', {'n': seconds}));
      await Future<void>.delayed(wait);
      if (!context.mounted) return null;
    }
    status(null);
    final pin = await askBackupPin(context, provider, error: error);
    if (pin == null || !context.mounted) return null;
    status(t('Unlocking…'), spin: true);
    Uint8List? key;
    var found = <BackupCandidate>[];
    try {
      key = await backups.derive(provider, accountId, pin);
      found = openBackups(files, key);
    } finally {
      wipeBytes(key);
    }
    final kept = <BackupCandidate>[];
    for (final candidate in found) {
      if (keep == null || keep(candidate)) {
        kept.add(candidate);
      } else {
        candidate.wipe();
      }
    }
    if (!context.mounted) {
      for (final candidate in kept) {
        candidate.wipe();
      }
      return null;
    }
    if (kept.isNotEmpty) {
      backups.throttle.succeeded();
      status(null);
      return kept;
    }
    backups.throttle.failed();
    error = wrongPin ?? t('Wrong PIN.');
  }
}

String passkeyUnsupportedMessage({required bool google}) => google
    ? t('This passkey provider can\'t hold a key backup, so nothing was saved. '
        'You can delete the passkey it just made. Try another passkey provider, '
        'or Continue with Google.')
    : t('This passkey provider can\'t hold a key backup, so nothing was saved. '
        'You can delete the passkey it just made. Try another passkey provider, '
        'such as a password manager or your phone.');

String passkeyErrorMessage(Object error, {required bool google}) =>
    error is PasskeyUnsupported
        ? passkeyUnsupportedMessage(google: google)
        : backupErrorMessage(error);
