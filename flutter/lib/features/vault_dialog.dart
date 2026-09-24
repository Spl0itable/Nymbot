import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../state/vault.dart';
import 'i18n/i18n.dart';

enum VaultAction { enable, change, disable, useBiometric, usePassphrase }

Future<bool> showVaultDialog(BuildContext context, Vault vault, VaultAction action,
        {bool biometricAvailable = false}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VaultDialog(
          vault: vault, action: action, biometricAvailable: biometricAvailable),
    ) ==
    true;

class VaultDialog extends StatefulWidget {
  const VaultDialog({
    super.key,
    required this.vault,
    required this.action,
    this.biometricAvailable = false,
  });

  final Vault vault;
  final VaultAction action;
  final bool biometricAvailable;

  @override
  State<VaultDialog> createState() => _VaultDialogState();
}

class _VaultDialogState extends State<VaultDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _bio = false;
  String? _error;

  bool get _biometricVault => widget.vault.biometric;

  bool get _asksCurrent => switch (widget.action) {
        VaultAction.enable || VaultAction.usePassphrase => false,
        VaultAction.disable => !_biometricVault,
        VaultAction.change || VaultAction.useBiometric => true,
      };

  bool get _asksNext => switch (widget.action) {
        VaultAction.enable => !_bio,
        VaultAction.change || VaultAction.usePassphrase => true,
        VaultAction.disable || VaultAction.useBiometric => false,
      };

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _title => switch (widget.action) {
        VaultAction.enable => t('Encrypt your identity'),
        VaultAction.change => t('Change passphrase'),
        VaultAction.disable => t('Turn off identity encryption'),
        VaultAction.useBiometric => t('Unlock with biometrics'),
        VaultAction.usePassphrase => t('Use a passphrase instead'),
      };

  String get _intro => switch (widget.action) {
        VaultAction.enable when _bio => t('Protect the key saved on this device with '
            'your fingerprint or face. Nymbot will ask for it every time it opens, and '
            'nothing syncs or sends until it is unlocked. There is no passphrase to fall '
            "back on: if your fingerprints or face data change, you'll need your saved "
            'nsec and recovery code, so keep them somewhere safe.'),
        VaultAction.enable => t('Protect the key saved on this device with a '
            'passphrase. Nymbot will ask for it every time it opens, and nothing '
            'syncs or sends until it is unlocked. If you forget it, the key on '
            'this device cannot be recovered, so keep your nsec saved somewhere '
            'safe.'),
        VaultAction.change => t('Enter your current passphrase, then choose a new one.'),
        VaultAction.disable when _biometricVault => t('Confirm with your biometrics to '
            'turn off identity encryption. Your key will be kept on this device without '
            'it again.'),
        VaultAction.disable => t('Enter your passphrase to turn off identity '
            'encryption. Your key will be kept on this device without a '
            'passphrase again.'),
        VaultAction.useBiometric => t('Enter your passphrase, then confirm with your '
            'biometrics. Nymbot will ask for your fingerprint or face instead of the '
            "passphrase from then on. If your fingerprints or face data change, you'll "
            'need your saved nsec and recovery code.'),
        VaultAction.usePassphrase => t('Choose a passphrase, then confirm with your '
            'biometrics. Nymbot will ask for the passphrase instead from then on.'),
      };

  String get _actionLabel => switch (widget.action) {
        VaultAction.enable => t('Turn on'),
        VaultAction.change => t('Change'),
        VaultAction.disable => t('Turn off'),
        VaultAction.useBiometric || VaultAction.usePassphrase => t('Switch'),
      };

  Future<void> _submit() async {
    if (_busy) return;
    if (_asksCurrent && _current.text.isEmpty) {
      setState(() => _error = t('Enter your passphrase.'));
      return;
    }
    if (_asksNext) {
      if (_next.text.length < Vault.minLength) {
        setState(() => _error = t('Use at least 4 characters.'));
        return;
      }
      if (_next.text != _confirm.text) {
        setState(() => _error = t('The two entries do not match.'));
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (widget.action) {
        case VaultAction.enable:
          if (_bio) {
            await widget.vault.enableBiometric();
          } else {
            await widget.vault.enable(_next.text);
          }
        case VaultAction.change:
          await widget.vault.change(_current.text, _next.text);
        case VaultAction.disable:
          if (_biometricVault) {
            await widget.vault.disableBiometric();
          } else {
            await widget.vault.disable(_current.text);
          }
        case VaultAction.useBiometric:
          await widget.vault.useBiometric(_current.text);
        case VaultAction.usePassphrase:
          await widget.vault.usePassphrase(_next.text);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on VaultWrongPassphrase {
      _current.clear();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t('Wrong passphrase.');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Widget _field(Key key, TextEditingController controller, String label,
          {bool last = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          key: key,
          controller: controller,
          obscureText: true,
          enabled: !_busy,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: last ? TextInputAction.done : TextInputAction.next,
          onSubmitted: last ? (_) => _submit() : null,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final danger = widget.action == VaultAction.disable;
    return AlertDialog(
      title: Text(_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.action == VaultAction.enable && widget.biometricAvailable)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 6,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('vault-method-passphrase'),
                      label: Text(t('Passphrase')),
                      selected: !_bio,
                      onSelected: _busy ? null : (_) => setState(() => _bio = false),
                    ),
                    ChoiceChip(
                      key: const ValueKey('vault-method-biometric'),
                      label: Text(t('Biometrics')),
                      selected: _bio,
                      onSelected: _busy ? null : (_) => setState(() => _bio = true),
                    ),
                  ],
                ),
              ),
            Text(_intro, style: const TextStyle(fontSize: 13)),
            if (_asksCurrent)
              _field(const ValueKey('vault-current'), _current,
                  widget.action == VaultAction.change
                      ? t('Current passphrase')
                      : t('Passphrase'),
                  last: !_asksNext),
            if (_asksNext) ...[
              _field(
                  const ValueKey('vault-next'),
                  _next,
                  widget.action == VaultAction.change
                      ? t('New passphrase')
                      : t('Passphrase')),
              _field(const ValueKey('vault-confirm'), _confirm,
                  t('Confirm passphrase'),
                  last: true),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: const TextStyle(color: NymbotColors.danger, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t('Cancel')),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: NymbotColors.danger)
              : null,
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_actionLabel),
        ),
      ],
    );
  }
}
