import 'package:flutter/material.dart';

import '../services/chat_engine.dart';
import '../services/research.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'nym_avatar.dart';
import 'nym_glyph.dart';

Future<void> toggleResearchChip(BuildContext context, AppController app) async {
  final messenger = ScaffoldMessenger.of(context);
  final changed = app.toggleResearch();
  if (changed && !app.researchNext) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(changed
          ? t('Research is on for your next message. It searches, reads and writes a report with sources.')
          : Research.needsPro()),
    ));
}

class ResearchProgress extends StatelessWidget {
  const ResearchProgress({
    super.key,
    required this.label,
    required this.steps,
    this.showAvatar = true,
  });

  final String label;
  final List<TurnStep> steps;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = Research.lines(steps);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: const ValueKey('research-progress'),
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
            const SizedBox(height: 4),
            ResearchSteps(lines: lines),
          ],
        ),
      ),
    );
  }
}

class ResearchSteps extends StatelessWidget {
  const ResearchSteps({super.key, required this.lines});

  final List<ResearchLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                NymGlyph(
                  line.current ? 'dot' : 'check',
                  size: 13,
                  color: line.current
                      ? theme.hintColor
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    line.line,
                    key: ValueKey('research-step-${line.current ? 'current' : 'done'}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: line.current
                          ? theme.hintColor
                          : theme.hintColor.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
