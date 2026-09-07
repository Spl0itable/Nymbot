import 'package:flutter/material.dart';

import '../app.dart';
import '../state/app_controller.dart';
import '../core/theme/theme.dart';
import 'i18n/i18n.dart';
import 'nym_icons.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/artifacts_sheet.dart';
import 'sheets/bots_sheet.dart';
import 'sheets/compare_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/models_sheet.dart';
import 'sheets/personas_sheet.dart';
import 'sheets/repos_sheet.dart';
import 'sheets/schedules_sheet.dart';
import 'sheets/workspaces_sheet.dart';

/// The AI toolbar: which balance this chat spends, which model answers, the
/// connected repository, anonymous mode, and the credit balance.
class NymbotToolbar extends StatelessWidget {
  const NymbotToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final model = app.activeModel;
    final pro = model != null;
    final accent = pro ? theme.colorScheme.secondary : theme.colorScheme.primary;
    final repos = app.activeRepos;
    final persona = app.activePersona;
    final hasSystem = (app.current?.systemPrompt ?? '').trim().isNotEmpty;

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
              label: pro ? model['label'] as String : t('Auto-routed'),
              active: pro,
              onTap: () => showModelsSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.account_tree_outlined,
              label: repos.isEmpty
                  ? t('Git')
                  : repos.length == 1
                      ? repos.first.display
                      : t('{n} repos', {'n': repos.length}),
              active: repos.isNotEmpty,
              onTap: () => showReposSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.person_outline,
              label: persona != null
                  ? persona.name
                  : hasSystem
                      ? t('Custom')
                      : t('Persona'),
              active: persona != null || hasSystem,
              onTap: () => showPersonasSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.schedule,
              label: app.schedules.where((s) => s.enabled).isEmpty
                  ? t('Scheduled')
                  : t('{n} scheduled',
                      {'n': app.schedules.where((s) => s.enabled).length}),
              active: app.schedules.any((s) => s.enabled),
              onTap: () => showSchedulesSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: app.current?.ephemeral == true
                  ? Icons.no_accounts
                  : Icons.history_toggle_off,
              label: app.current?.ephemeral == true ? t('Ghost on') : t('Ghost'),
              active: app.current?.ephemeral == true,
              onTap: () => _confirmGhost(context, app),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: NymIcons.forPersona(app.activeBot?.icon ?? 'robot'),
              label: app.activeBot?.name ?? t('Bot'),
              active: app.activeBot != null,
              onTap: () => showBotsSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.folder_outlined,
              label: app.activeWorkspace?.name ?? t('Workspace'),
              active: app.activeWorkspace != null,
              onTap: () => showWorkspacesSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.splitscreen_outlined,
              label: t('Compare'),
              active: false,
              onTap: () => showCompareSheet(context),
            ),
            if (app.artifacts.isNotEmpty) ...[
              const SizedBox(width: 6),
              _Chip(
                icon: Icons.description_outlined,
                label: app.artifacts.length == 1
                    ? t('1 artifact')
                    : t('{n} artifacts', {'n': app.artifacts.length}),
                active: true,
                onTap: () => showArtifactsSheet(context),
              ),
            ],
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.public,
              label: t('Web'),
              active: app.settings.webSearch,
              onTap: () => app.setWebSearch(!app.settings.webSearch),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.visibility_off_outlined,
              label: app.anon.enabled ? t('Anon on') : t('Anon'),
              active: app.anon.enabled,
              onTap: () => showAnonSheet(context),
            ),
            const SizedBox(width: 6),
            _Chip(
              icon: Icons.bolt,
              label: app.shownBalance?.toString() ?? t('Buy'),
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

/// Turning ghost mode on is a promise about what is kept, so it is asked for
/// rather than toggled by accident.
Future<void> _confirmGhost(BuildContext context, AppController app) async {
  final conv = app.current;
  if (conv == null) return;
  if (conv.ephemeral) {
    await app.setEphemeral(false);
    return;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('Make this a ghost chat?')),
      content: Text(t('Nothing it says will be written to this device, and no '
          'archive copy will be published. It is gone when you close the app.')),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('Cancel'))),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('Make it a ghost'))),
      ],
    ),
  );
  if (go == true) await app.setEphemeral(true);
}

class ContextBar extends StatelessWidget {
  const ContextBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final repos = app.activeRepos;
    final persona = app.activePersona;
    final hasSystem = (app.current?.systemPrompt ?? '').trim().isNotEmpty;

    if (repos.isEmpty && persona == null && !hasSystem && !app.settings.webSearch) {
      return const SizedBox.shrink();
    }

    Widget chip(String label, Color colour, VoidCallback? onClear,
        {VoidCallback? onTap, IconData? leading, IconData? badge}) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap ?? onClear,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
          decoration: BoxDecoration(
            border: Border.all(color: colour.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                Icon(leading, size: 12, color: colour),
                const SizedBox(width: 4),
              ],
              Text(label, style: TextStyle(fontSize: 11, color: colour)),
              if (badge != null) ...[
                const SizedBox(width: 3),
                Icon(badge, size: 11, color: colour.withValues(alpha: 0.75)),
              ],
              if (onClear != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.close, size: 12, color: colour.withValues(alpha: 0.7)),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        children: [
          for (final r in repos)
            chip(
              '${r.display}${r.branch.isEmpty ? '' : '@${r.branch}'}',
              NymbotColors.lightning,
              () => app.toggleRepoHere(r.id),
              badge: r.allowWrites ? Icons.edit_outlined : null,
            ),
          if (persona != null)
            chip(persona.name, theme.colorScheme.primary,
                () => app.setPersona(null),
                leading: NymIcons.forPersona(persona.icon)),
          if (hasSystem)
            chip(t('Custom instructions'), theme.colorScheme.secondary, null,
                onTap: () => showSystemPromptSheet(context)),
          if (app.settings.webSearch)
            chip(t('Web search'), theme.colorScheme.secondary,
                () => app.setWebSearch(false)),
        ],
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
    Widget side(String label, bool active, bool isPro) => GestureDetector(
          onTap: () async {
            if (isPro) {
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
      child: Row(children: [
        side(t('Standard'), !pro, false),
        side(t('Pro'), pro, true),
      ]),
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
