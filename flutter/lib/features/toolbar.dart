import 'package:flutter/material.dart';

import '../app.dart';
import '../models/workspace.dart';
import '../services/chat_engine.dart';
import '../state/app_controller.dart';
import '../core/theme/theme.dart';
import 'brand_tile.dart';
import 'i18n/i18n.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/sheet.dart';
import 'sheets/artifacts_sheet.dart';
import 'sheets/bots_sheet.dart';
import 'sheets/compare_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/models_sheet.dart';
import 'sheets/personas_sheet.dart';
import 'sheets/connectors_sheet.dart';
import 'sheets/repos_sheet.dart';
import 'sheets/schedules_sheet.dart';
import 'sheets/team_sheet.dart';
import 'sheets/workspaces_sheet.dart';
import 'nym_glyph.dart';
import 'research_view.dart';

/// The AI toolbar: which balance this chat spends, which model answers, the
/// connected repository, anonymous mode, and the credit balance.
class NymbotToolbar extends StatelessWidget {
  const NymbotToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final model = app.activeModel;
    final media = app.activeMediaModel;
    final pro = model != null || AppController.mediaNeedsPro(media);
    final shown = media ?? model;
    final accent = pro ? theme.colorScheme.secondary : theme.colorScheme.primary;
    final repos = app.activeRepos;
    final persona = app.activePersona;
    final hasSystem = (app.current?.systemPrompt ?? '').trim().isNotEmpty;

    // Every chip that can be on for this chat, in the order the bar reads.
    final chips = <_ChipSpec>[
      _ChipSpec(
        glyph: 'auto-routed',
        label: shown == null ? t('Auto-routed') : shown['label'] as String,
        active: shown != null,
        brand: shown == null ? null : shown['slug'] as String?,
        onTap: () => showModelsSheet(context),
      ),
      _ChipSpec(
        glyph: 'git',
        label: repos.isEmpty
            ? t('Git')
            : repos.length == 1
                ? repos.first.display
                : t('{n} repos', {'n': repos.length}),
        active: repos.isNotEmpty,
        onTap: () => showReposSheet(context),
      ),
      if (app.runnerAvailable && repos.isNotEmpty)
        _ChipSpec(
          glyph: 'server-runs',
          label: t('Server runs'),
          active: app.current?.serverRuns == true,
          onTap: () => _toggleServerRuns(context, app),
        ),
      _ChipSpec(
        glyph: 'connectors',
        label: app.activeConnectors.isEmpty
            ? t('Connectors')
            : app.activeConnectors.length == 1
                ? app.activeConnectors.first.name
                : t('{n} connectors', {'n': app.activeConnectors.length}),
        active: app.activeConnectors.isNotEmpty,
        onTap: () => showConnectorsSheet(context),
      ),
      _ChipSpec(
        glyph: 'persona',
        label: persona != null
            ? persona.name
            : hasSystem
                ? t('Custom')
                : t('Persona'),
        active: persona != null || hasSystem,
        onTap: () => showPersonasSheet(context),
      ),
      _ChipSpec(
        glyph: 'scheduled',
        label: app.schedules.where((s) => s.enabled).isEmpty
            ? t('Scheduled')
            : t('{n} scheduled',
                {'n': app.schedules.where((s) => s.enabled).length}),
        active: app.schedules.any((s) => s.enabled),
        onTap: () => showSchedulesSheet(context),
      ),
      _ChipSpec(
        glyph: 'ghost',
        label: t('Ghost'),
        active: app.current?.ephemeral == true,
        onTap: () => _confirmGhost(context, app),
      ),
      _ChipSpec(
        glyph: 'bot',
        label: app.activeBot?.name ?? t('Bot'),
        active: app.activeBot != null,
        onTap: () => showBotsSheet(context),
      ),
      _ChipSpec(
        glyph: 'workspace',
        label: app.activeWorkspace?.name ?? t('Workspace'),
        active: app.activeWorkspace != null,
        onTap: () => showWorkspacesSheet(context),
      ),
      _ChipSpec(
        glyph: 'compare',
        label: t('Compare'),
        active: false,
        onTap: () => showCompareSheet(context),
      ),
      if (app.artifacts.isNotEmpty)
        _ChipSpec(
          glyph: 'artifacts',
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
          glyph: 'effort',
          label: switch (ChatEngine.effortOf(app.current)) {
            'careful' => t('Careful'),
            'deep' => t('Deep'),
            _ => t('Effort'),
          },
          active: ChatEngine.effortOf(app.current) != 'normal',
          onTap: () => _cycleEffort(context, app),
        ),
      _ChipSpec(
        glyph: 'research',
        label: t('Research'),
        active: app.researchNext,
        onTap: () => toggleResearchChip(context, app),
      ),
      if (app.teamAvailable)
        _ChipSpec(
          glyph: 'team',
          label: app.teamSetting == null
              ? t('Team')
              : t('Team of {n}', {'n': app.teamSetting!.workers}),
          active: app.teamSetting != null,
          onTap: () => showTeamSheet(context),
        ),
      _ChipSpec(
        glyph: 'web',
        label: t('Web'),
        active: app.settings.webSearch,
        onTap: () => app.setWebSearch(!app.settings.webSearch),
      ),
      _ChipSpec(
        glyph: 'anon',
        label: t('Anon'),
        active: app.current?.anon ?? false,
        onTap: () => _anonChip(context, app),
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

    final chipRow = [
      for (final c in on) c.build(context),
      if (on.isNotEmpty && off.isNotEmpty)
        Container(
          width: 1,
          height: 20,
          color: theme.dividerColor,
        ),
      for (final c in off) c.build(context),
    ];
    final balance = _Chip(
      glyph: 'bolt',
      label: (!app.proTier &&
              !app.spendingAnon &&
              (app.standardBalance ?? 0) == 0 &&
              app.freeLeft != null)
          ? t('{n} free', {'n': figure(app.freeLeft)})
          : (app.shownBalance == null
              ? t('Buy')
              : creditFigure(app.shownBalance)),
      active: false,
      color: NymbotColors.lightning,
      onTap: () => showCreditsSheet(context),
    );
    if (MediaQuery.textScalerOf(context).scale(1) > 1.15) {
      return Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        child: SingleChildScrollView(
          key: const ValueKey('toolbar-scroll'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: spaced([
            _TierSwitch(pro: pro, accent: accent),
            _ChipMenuButton(on: on, off: off),
            ...chipRow,
            balance,
          ]),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      // Only the chips scroll. The tier switch and the balance are anchored
      // either side of them, so a chat with a long model name or a shelf of
      // repositories can never push the button that buys credits out of reach.
      child: Row(
        children: [
          _TierSwitch(pro: pro, accent: accent),
          const SizedBox(width: 6),
          _ChipMenuButton(on: on, off: off),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: spaced(chipRow),
            ),
          ),
          const SizedBox(width: 6),
          balance,
        ],
      ),
    );
  }
}

class _ChipMenuButton extends StatelessWidget {
  const _ChipMenuButton({required this.on, required this.off});

  final List<_ChipSpec> on;
  final List<_ChipSpec> off;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: t('All settings for this chat'),
      child: InkWell(
        borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
        onTap: () => _showChipMenu(context, on, off),
        child: _TapHeight(
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const NymGlyph('menu', size: 14),
                if (on.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text('${on.length}',
                      style: TextStyle(
                          fontSize: 11, color: theme.colorScheme.primary)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showChipMenu(
    BuildContext context, List<_ChipSpec> on, List<_ChipSpec> off) {
  return showNymSheet<void>(context, (sheetContext) {
    final theme = Theme.of(sheetContext);

    Widget row(_ChipSpec spec) => ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: spec.brand != null
              ? BrandTile(slug: spec.brand!, size: 18)
              : NymGlyph(spec.glyph,
                  size: 18,
                  color: spec.active ? theme.colorScheme.primary : null),
          title: Text(spec.label, style: const TextStyle(fontSize: 13)),
          trailing: spec.active
              ? NymGlyph('check', size: 16, color: theme.colorScheme.primary)
              : null,
          onTap: () {
            Navigator.pop(sheetContext);
            spec.onTap();
          },
        );

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text,
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.4,
                  color: theme.hintColor)),
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (on.isNotEmpty) ...[
              heading(t('On for this chat')),
              for (final spec in on) row(spec),
              const Divider(height: 1),
            ],
            heading(on.isEmpty ? t('This chat') : t('Also available')),
            for (final spec in off) row(spec),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  });
}

/// One toolbar chip, described rather than built, so the bar can sort the ones
/// that are on to the front before any of them is laid out.
class _ChipSpec {
  const _ChipSpec({
    required this.glyph,
    required this.label,
    required this.active,
    required this.onTap,
    this.brand,
  });

  final String glyph;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? brand;

  Widget build(BuildContext context) => _Chip(
      glyph: glyph, label: label, active: active, onTap: onTap, brand: brand);
}

Future<void> _toggleServerRuns(BuildContext context, AppController app) async {
  final messenger = ScaffoldMessenger.of(context);
  await app.toggleServerRuns();
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(app.current?.serverRuns == true
          ? t('Server runs on: repo replies can ask to run a command on a Nymbot server. Each run asks you first and shows the most it can cost.')
          : t('Server runs off.')),
    ));
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

Future<void> _anonChip(BuildContext context, AppController app) async {
  final conv = app.current;
  if (conv == null) return;
  if (app.canFlipAnon) {
    final messenger = ScaffoldMessenger.of(context);
    await app.setChatAnon(!conv.anon);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(conv.anon
            ? t('This chat travels under a throwaway key.')
            : t('This chat uses your own key.')),
      ));
    return;
  }
  await showAnonSheet(context);
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

    Widget face(String label, Color colour, {String? badge}) => Container(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          decoration: BoxDecoration(
            border: Border.all(color: colour.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colour)),
              ),
              if (badge != null) ...[
                const SizedBox(width: 3),
                NymGlyph(badge, size: 11, color: colour.withValues(alpha: 0.75)),
              ],
            ],
          ),
        );

    Future<void> remove(GitRepo repo) async {
      final messenger = ScaffoldMessenger.of(context);
      await app.toggleRepoHere(repo.id);
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(t('{repo} is no longer in scope for this chat.',
              {'repo': repo.repo})),
          action: SnackBarAction(
            label: t('Undo'),
            onPressed: () {
              if (!(app.current?.repoIds ?? const []).contains(repo.id)) {
                app.toggleRepoHere(repo.id);
              }
            },
          ),
        ));
    }

    Future<void> menu(GitRepo repo) async {
      final choice = await showNymSheet<String>(
        context,
        (sheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(repo.repo, overflow: TextOverflow.ellipsis),
                  subtitle: repo.branch.isEmpty ? null : Text(repo.branch),
                ),
                ListTile(
                  leading: const NymGlyph('pencil', size: 20),
                  title: Text(repo.allowWrites
                      ? t('Stop letting Nymbot write here')
                      : t('Let Nymbot write here')),
                  onTap: () => Navigator.pop(sheet, 'writes'),
                ),
                ListTile(
                  leading: const NymGlyph('settings', size: 20),
                  title: Text(t('Repository settings')),
                  onTap: () => Navigator.pop(sheet, 'settings'),
                ),
                ListTile(
                  leading: const NymGlyph('close', size: 20),
                  title: Text(t('Remove from this chat')),
                  onTap: () => Navigator.pop(sheet, 'remove'),
                ),
              ],
            ),
          ),
        ),
      );
      if (!context.mounted) return;
      switch (choice) {
        case 'writes':
          repo.allowWrites = !repo.allowWrites;
          await app.saveRepo(repo, useHere: false);
        case 'settings':
          await showReposSheet(context);
        case 'remove':
          await remove(repo);
      }
    }

    Widget repoChip(GitRepo r) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Semantics(
                button: true,
                label: t('Options for {repo}', {'repo': r.repo}),
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('repo-chip-${r.id}'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => menu(r),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Center(
                      widthFactor: 1,
                      child: face(
                        '${r.display}${r.branch.isEmpty ? '' : '@${r.branch}'}',
                        NymbotColors.lightning,
                        badge: r.allowWrites ? 'pencil' : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('repo-remove-${r.id}'),
              icon: NymGlyph('close',
                  size: 14,
                  color: NymbotColors.lightning.withValues(alpha: 0.8)),
              tooltip: t('Remove {repo} from this chat', {'repo': r.repo}),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              padding: EdgeInsets.zero,
              onPressed: () => remove(r),
            ),
          ],
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Wrap(
        spacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final r in repos) repoChip(r),
          if (hasSystem && persona != null)
            Semantics(
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => showSystemPromptSheet(context),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Center(
                    widthFactor: 1,
                    child: face(
                        t('Custom instructions'), theme.colorScheme.secondary),
                  ),
                ),
              ),
            ),
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
    Widget face(String label, bool active) => Container(
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
        );

    Future<void> pick(bool isPro) async {
      if (isPro) {
        await showModelsSheet(context);
      } else {
        await app.dropProMedia();
        await app.setProModel(null);
      }
    }

    Widget side(String label, bool active, bool isPro) => Semantics(
          key: ValueKey('tier-${isPro ? 'pro' : 'standard'}'),
          button: true,
          selected: active,
          label: label,
          excludeSemantics: true,
          onTap: () => pick(isPro),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => pick(isPro),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(
                widthFactor: 1,
                child: Opacity(opacity: 0, child: face(label, active)),
              ),
            ),
          ),
        );

    final standard = t('Standard');
    final proLabel = t('Pro');
    return Stack(
      alignment: Alignment.center,
      children: [
        ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(NymbotColors.switchRadius),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              face(standard, !pro),
              face(proLabel, pro),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            side(standard, !pro, false),
            side(proLabel, pro, true),
          ]),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.glyph,
    required this.label,
    required this.active,
    required this.onTap,
    this.color,
    this.brand,
  });

  final String glyph;
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
      child: _TapHeight(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(
              color: (color ??
                      (active ? theme.colorScheme.secondary : theme.dividerColor))
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
                NymGlyph(glyph, size: 14, color: tint),
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
      ),
    );
  }
}

class _TapHeight extends StatelessWidget {
  const _TapHeight({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Center(widthFactor: 1, child: child),
      );
}
