import 'package:flutter/material.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/git_sheet.dart';
import 'sheets/models_sheet.dart';

/// The AI toolbar: which balance this chat spends, which model answers, the
/// connected repository, anonymous mode, and the credit balance.
class NymbotToolbar extends StatelessWidget {
  const NymbotToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final pro = app.proModel != null;
    final accent = pro ? theme.colorScheme.secondary : theme.colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TierSwitch(pro: pro, accent: accent),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.auto_awesome,
              label: pro ? app.proModel!['label'] as String : 'Auto-routed',
              active: pro,
              onTap: () => showModelsSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.account_tree_outlined,
              label: (app.git?['repo'] as String?) ?? 'Git',
              active: app.git?['repo'] != null,
              onTap: () => showGitSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.visibility_off_outlined,
              label: app.anon.enabled ? 'Anon on' : 'Anon',
              active: app.anon.enabled,
              onTap: () => showAnonSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.bolt,
              label: app.shownBalance?.toString() ?? 'Buy',
              active: false,
              color: NymbotColors.lightning,
              onTap: () => showCreditsSheet(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _TierSwitch extends StatelessWidget {
  const _TierSwitch({required this.pro, required this.accent});

  final bool pro;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget side(String label, bool active) => GestureDetector(
          onTap: () async {
            if (label == 'Pro') {
              await showModelsSheet(context);
            } else {
              await app.setProModel(null);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: active ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(NymbotColors.switchTabRadius),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active
                    ? Theme.of(context).scaffoldBackgroundColor
                    : Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(NymbotColors.switchRadius),
      ),
      child: Row(children: [side('Standard', !pro), side('Pro', pro)]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ??
        (active ? theme.colorScheme.secondary : theme.textTheme.bodySmall?.color);
    return InkWell(
      borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(
            color: (color ?? (active ? theme.colorScheme.secondary : theme.dividerColor))
                .withValues(alpha: active || color != null ? 0.6 : 1),
          ),
          borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: tint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
