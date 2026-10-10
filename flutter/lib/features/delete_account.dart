import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';

String deleteAccountLabel() => t('Delete account data and wipe device');

String deleteAccountConfirmText({required bool iOS}) => [
      t('On this device: your key, every conversation, your settings and your library.'),
      t('On our servers: your synced chats, settings and library, your Nymbot '
          'conversation history, API keys, background tasks and schedules, '
          'shared links, and your credits and purchase records.'),
      t('Public relays: anything sent to Nostr relays is kept by the relay '
          "operators and can't be deleted by us."),
      if (iOS)
        t('Key backups saved to iCloud from this device are deleted too. Other '
            'key backups in iCloud or Google Drive stay there. Delete them in '
            'that service if you no longer want them.')
      else
        t('Key backups you saved to iCloud or Google Drive stay there. Delete '
            'them in that service if you no longer want them.'),
      t('Any remaining Nymbot credits will be lost. To keep them, use Move my '
          'whole balance first.'),
      t('Other devices signed in to this account will also be wiped the next '
          'time they connect.'),
      t('This cannot be undone.'),
    ].join('\n\n');

Future<void> confirmDeleteAccount(BuildContext context, AppController app) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text('${deleteAccountLabel()}?'),
      content: Text(deleteAccountConfirmText(
          iOS: defaultTargetPlatform == TargetPlatform.iOS)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel'))),
        FilledButton(
          key: const ValueKey('delete-account-confirm'),
          style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(t('Delete')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((r) => r.isFirst);
  await navigator.push(PageRouteBuilder<void>(
    opaque: true,
    barrierDismissible: false,
    transitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => DeleteAccountScreen(app: app),
  ));
}

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key, required this.app});

  final AppController app;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  ({bool purged, int iCloud})? _result;

  @override
  void initState() {
    super.initState();
    widget.app.deleteAccount().then((r) {
      if (mounted) setState(() => _result = r);
    }, onError: (_) {
      if (mounted) setState(() => _result = (purged: false, iCloud: 0));
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: r == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                          const SizedBox(height: 16),
                          Text(t('Deleting your account data on our servers…'),
                              textAlign: TextAlign.center),
                        ],
                      )
                    : Semantics(
                        liveRegion: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(t('Account data deleted'),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleLarge),
                            const SizedBox(height: 12),
                            Text(
                              r.purged
                                  ? t('Your key, conversations and settings are gone from this device, and your account data is gone from our servers.')
                                  : t("Your key, conversations and settings are gone from this device. We couldn't reach our servers to delete your account data there."),
                              textAlign: TextAlign.center,
                            ),
                            if (r.iCloud > 0) ...[
                              const SizedBox(height: 12),
                              Text(
                                r.iCloud == 1
                                    ? t('1 key backup saved to iCloud from this device was deleted.')
                                    : t('{n} key backups saved to iCloud from this device were deleted.',
                                        {'n': r.iCloud}),
                                textAlign: TextAlign.center,
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(t('Anything already on public relays stays there.'),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 20),
                            FilledButton(
                              key: const ValueKey('delete-account-done'),
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(t('Done')),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
