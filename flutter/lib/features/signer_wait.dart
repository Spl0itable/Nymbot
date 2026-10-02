import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/utils/safe_url.dart';
import 'i18n/i18n.dart';

class SignerWait extends StatelessWidget {
  const SignerWait({super.key, required this.waiting, this.authUrl, this.child});

  final ValueListenable<bool> waiting;
  final ValueNotifier<String?>? authUrl;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.passthrough,
        children: [
          child ?? const SizedBox.shrink(),
          ListenableBuilder(
            listenable: Listenable.merge([waiting, ?authUrl]),
            builder: (context, _) {
              final on = waiting.value;
              final url = authUrl?.value;
              if (!on && url == null) return const SizedBox.shrink();
              final scheme = Theme.of(context).colorScheme;
              return Positioned(
                left: 16,
                right: 16,
                top: MediaQuery.paddingOf(context).top + 8,
                child: Center(
                  child: Material(
                    key: const ValueKey('signer-wait'),
                    elevation: 4,
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (on) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Flexible(
                            child: Text(
                              t('Waiting for your signer…'),
                              style: TextStyle(color: scheme.onSurface),
                            ),
                          ),
                          if (url != null) ...[
                            const SizedBox(width: 6),
                            TextButton(
                              key: const ValueKey('signer-auth-open'),
                              onPressed: () {
                                authUrl!.value = null;
                                launchSafeUrl(url);
                              },
                              child: Text(t('Open the approval page')),
                            ),
                            TextButton(
                              key: const ValueKey('signer-auth-dismiss'),
                              onPressed: () => authUrl!.value = null,
                              child: Text(t('Dismiss')),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      );
}
