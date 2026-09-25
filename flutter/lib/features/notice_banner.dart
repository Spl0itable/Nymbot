import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';
import 'sheets/models_sheet.dart';

class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final notice = app.visibleNotice;
    if (notice == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = switch (notice.level) {
      'success' => dark ? NymbotColors.primary : NymbotColors.primaryLight,
      'warning' => NymbotColors.lightning,
      _ => theme.colorScheme.secondary,
    };
    final icon = notice.kind == 'model'
        ? NymGlyph('model', size: 16, color: accent)
        : switch (notice.level) {
            'success' => NymGlyph('verified', size: 16, color: accent),
            'warning' =>
              Icon(Icons.warning_amber_rounded, size: 16, color: accent),
            _ => NymGlyph('prompt', size: 16, color: accent),
          };
    final link = notice.url;
    final model = notice.kind == 'model' ? notice.model : null;
    final action = TextButton.styleFrom(
      foregroundColor: accent,
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 30),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: dark ? 0.10 : 0.08),
        border: BorderDirectional(
          start: BorderSide(color: accent, width: 3),
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: icon,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (notice.title.isNotEmpty)
                  Text(
                    notice.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                if (notice.body.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      notice.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                  ),
                if (link != null || model != null)
                  Wrap(
                    spacing: 4,
                    children: [
                      if (model != null)
                        TextButton(
                          style: action,
                          onPressed: () =>
                              showModelsSheet(context, filter: model),
                          child: Text(t('Try it')),
                        ),
                      if (link != null)
                        TextButton(
                          style: action,
                          onPressed: () => launchUrl(Uri.parse(link),
                              mode: LaunchMode.externalApplication),
                          child: Text(notice.linkLabel ?? t('Learn more')),
                        ),
                    ],
                  )
                else
                  const SizedBox(height: 4),
              ],
            ),
          ),
          IconButton(
            icon: const NymGlyph('close', size: 16),
            tooltip: t('Dismiss'),
            visualDensity: VisualDensity.compact,
            onPressed: () => app.dismissNotice(notice.id),
          ),
        ],
      ),
    );
  }
}
