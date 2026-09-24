import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/chat_engine.dart';
import '../services/team.dart';
import 'i18n/i18n.dart';
import 'nym_avatar.dart';
import 'research_view.dart';

class TeamProgress extends StatelessWidget {
  const TeamProgress({
    super.key,
    required this.label,
    required this.steps,
    required this.workers,
    this.showAvatar = true,
  });

  final String label;
  final List<TurnStep> steps;
  final int workers;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lanes = Team.lanes(steps, workers);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: const ValueKey('team-progress'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: theme.dividerColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showAvatar) ...[
                  const NymAvatar(seed: 'nymbot', size: 18, bot: true),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
                ),
              ],
            ),
            for (final lane in lanes)
              Container(
                key: ValueKey('team-lane-${lane.lane}'),
                margin: const EdgeInsets.only(top: 7),
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      width: 2,
                      color: lane.lane == 0
                          ? theme.colorScheme.primary
                          : lane.state == 'failed' || lane.state == 'rework-failed'
                              ? NymbotColors.danger
                              : theme.hintColor.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(lane.title,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: theme.hintColor)),
                    ResearchSteps(lines: lane.lines),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TeamSummary extends StatelessWidget {
  const TeamSummary({
    super.key,
    required this.team,
    this.leadModel,
    this.catalog,
  });

  final Map<String, dynamic> team;
  final String? leadModel;
  final Map<String, dynamic>? catalog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = Team.summary(team, leadModel, catalog);
    if (rows.isEmpty) return const SizedBox.shrink();
    final faint = TextStyle(fontSize: 11, color: theme.hintColor);
    return Padding(
      key: const ValueKey('team-summary'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('Team'),
              style: faint.copyWith(fontWeight: FontWeight.w600)),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(row.who, style: faint.copyWith(fontWeight: FontWeight.w500)),
                  if (row.model.isNotEmpty) Text(row.model, style: faint),
                  Text(
                      t('{credits} Pro credits',
                          {'credits': Team.credits(row.credits)}),
                      style: faint),
                  if (row.status.isNotEmpty)
                    Text(Team.statusLabel(row.status),
                        style: faint.copyWith(
                            color: row.status == 'failed'
                                ? NymbotColors.danger
                                : null)),
                ],
              ),
            ),
          if (Team.sequential(team))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  t('The provider was busy, so the workers ran one at a time.'),
                  style: faint.copyWith(fontStyle: FontStyle.italic)),
            ),
        ],
      ),
    );
  }
}
