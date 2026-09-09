import 'package:flutter/material.dart';

import '../app.dart';
import '../services/chat_engine.dart';
import '../state/app_controller.dart';
import '../core/theme/theme.dart';
import 'brand_tile.dart';
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
    final media = app.activeMediaModel;
    final shown = media ?? (pro ? model : null);
    final accent = pro ? theme.colorScheme.secondary : theme.colorScheme.primary;
    final repos = app.activeRepos;
    final persona = app.activePersona;
    final hasSystem = (app.current?.systemPrompt ?? '').trim().isNotEmpty;

    // Every chip that can be on for this chat, in the order the bar reads.
    final chips = <_ChipSpec>[
      _ChipSpec(
        icon: Icons.auto_awesome,
        label: shown == null ? t('Auto-routed') : shown['label'] as String,
        active: shown != null,
        brand: shown == null ? null : shown['slug'] as String?,
        onTap: () => showModelsSheet(context),
      ),
      _ChipSpec(
        icon: Icons.account_tree_outlined,
        label: repos.isEmpty
            ? t('Git')
            : repos.length == 1
                ? repos.first.display
                : t('{n} repos', {'n': repos.length}),
        active: repos.isNotEmpty,
        onTap: () => showReposSheet(context),
      ),
      _ChipSpec(
        icon: Icons.person_outline,
        label: persona != null
            ? persona.name
            : hasSystem
                ? t('Custom')
                : t('Persona'),
        active: persona != null || hasSystem,
        onTap: () => showPersonasSheet(context),
      ),
      _ChipSpec(
        icon: Icons.schedule,
        label: app.schedules.where((s) => s.enabled).isEmpty
            ? t('Scheduled')
            : t('{n} scheduled',
                {'n': app.schedules.where((s) => s.enabled).length}),
        active: app.schedules.any((s) => s.enabled),
        onTap: () => showSchedulesSheet(context),
      ),
      _ChipSpec(
        icon: app.current?.ephemeral == true
            ? Icons.no_accounts
            : Icons.history_toggle_off,
        label: app.current?.ephemeral == true ? t('Ghost on') : t('Ghost'),
        active: app.current?.ephemeral == true,
        onTap: () => _confirmGhost(context, app),
      ),
      _ChipSpec(
        icon: NymIcons.forPersona(app.activeBot?.icon ?? 'robot'),
        label: app.activeBot?.name ?? t('Bot'),
        active: app.activeBot != null,
        onTap: () => showBotsSheet(context),
      ),
      _ChipSpec(
        icon: Icons.folder_outlined,
        label: app.activeWorkspace?.name ?? t('Workspace'),
        active: app.activeWorkspace != null,
        onTap: () => showWorkspacesSheet(context),
      ),
      _ChipSpec(
        icon: Icons.splitscreen_outlined,
        label: t('Compare'),
        active: false,
        onTap: () => showCompareSheet(context),
      ),
      if (app.artifacts.isNotEmpty)
        _ChipSpec(
          icon: Icons.description_outlined,
          label: app.artifacts.length == 1
              ? t('1 artifact')
              : t('{n} artifacts', {'n': app.artifacts.length}),
          active: true,
          onTap: () => showArtifactsSheet(context),
        ),
      // Only a Pro reply outside a repo task can be asked to think harder:
      // standard replies are one routed call, and a repo task already loops on
      // a budget of its own.
      if (pro && repos.isEmpty)
        _ChipSpec(
          icon: Icons.lightbulb_outline,
          label: switch (ChatEngine.effortOf(app.current)) {
            'careful' => t('Careful'),
            'deep' => t('Deep'),
            _ => t('Effort'),
          },
          active: ChatEngine.effortOf(app.current) != 'normal',
          onTap: () => _cycleEffort(context, app),
        ),
      _ChipSpec(
        icon: Icons.public,
        label: t('Web'),
        active: app.settings.webSearch,
        onTap: () => app.setWebSearch(!app.settings.webSearch),
      ),
      _ChipSpec(
        icon: Icons.visibility_off_outlined,
        label: app.anon.enabled ? t('Anon on') : t('Anon'),
        active: app.anon.enabled,
        onTap: () => showAnonSheet(context),
      ),
    ];

    // Whatever is on for this chat sorts to the front, with a rule after it,
    // so the settings in force are the ones you see before you scroll.
    final on = chips.where((c) => c.active).toList();
    final off = chips.where((c) => !c.active).toList();

    Widget spaced(List<Widget> children) {
      final out = <Widget>[];
      for (final child in children) {
        if (out.isNotEmpty) out.add(const SizedBox(width: 6));
        out.add(child);
      }
      return Row(children: out);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      // Only the chips scroll. The tier switch and the balance are anchored
      // either side of them, so a chat with a long model name or a shelf of
      // repositories can never push the button that buys credits out of reach.
      child: Row(
        children: [
          _TierSwitch(pro: pro, accent: accent),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: spaced([
                for (final c in on) c.build(context),
                if (on.isNotEmpty && off.isNotEmpty)
                  Container(
                    width: 1,
                    height: 20,
                    color: theme.dividerColor,
                  ),
                for (final c in off) c.build(context),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          _Chip(
            icon: Icons.bolt,
            // With nothing to spend, the chip counts what the day has left
            // rather than showing a zero — which is a wall, where the free
            // tier is a thing that is still working.
            label: (app.activeModel == null &&
                    (app.standardBalance ?? 0) == 0 &&
                    app.freeLeft != null)
                ? t('{n} free', {'n': app.freeLeft})
                : (app.shownBalance?.toString() ?? t('Buy')),
            active: false,
            color: NymbotColors.lightning,
            onTap: () => showCreditsSheet(context),
          ),
        ],
      ),
    );
  }
}

/// One toolbar chip, described rather than built, so the bar can sort the ones
/// that are on to the front before any of them is laid out.
class _ChipSpec {
  const _ChipSpec({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.brand,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? brand;

  Widget build(BuildContext context) => _Chip(
      icon: icon, label: label, active: active, onTap: onTap, brand: brand);
}

/// Each step is another model call the reply takes and the balance pays for,
/// so what it costs is said rather than left to be discovered on the bill.
Future<void> _cycleEffort(BuildContext context, AppController app) async {
  final messenger = ScaffoldMessenger.of(context);
  final next = await app.cycleEffort();
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(switch (next) {
        'careful' => t('Careful: it plans before it answers. Two passes, so '
            'about twice the credits.'),
        'deep' => t('Deep: it plans, answers, then checks its answer. Three '
            'passes, so about three times the credits.'),
        _ => t('Normal effort: one pass.'),
      }),
    ));
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

    if (repos.isEmpty && !(hasSystem && persona != null)) {
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
          if (hasSystem && persona != null)
            chip(t('Custom instructions'), theme.colorScheme.secondary, null,
                onTap: () => showSystemPromptSheet(context)),
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
              await app.dropProMedia();
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
    this.brand,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final Color? color;
  final String? brand;

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
            if (brand != null)
              BrandTile(slug: brand!, size: 15)
            else
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
