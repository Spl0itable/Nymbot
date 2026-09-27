import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';
import 'sheets/sheet.dart';

class ShareTarget {
  const ShareTarget.fresh() : conversation = null;
  const ShareTarget.existing(Conversation this.conversation);

  final Conversation? conversation;

  bool get fresh => conversation == null;
}

Future<ShareTarget?> showShareTargetSheet(
  BuildContext context,
  AppController app, {
  String text = '',
  int files = 0,
}) =>
    showNymSheet<ShareTarget>(
      context,
      (_) => ShareTargetSheet(app: app, text: text, files: files),
    );

class ShareTargetSheet extends StatefulWidget {
  const ShareTargetSheet(
      {super.key, required this.app, this.text = '', this.files = 0});

  static const searchAbove = 6;

  final AppController app;
  final String text;
  final int files;

  static List<Conversation> choices(AppController app, String needle) {
    final term = needle.trim().toLowerCase();
    return app.conversations
        .where((c) => !c.archived)
        .where((c) =>
            term.isEmpty ||
            c.title.toLowerCase().contains(term) ||
            c.tags.any((x) => x.toLowerCase().contains(term)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  State<ShareTargetSheet> createState() => _ShareTargetSheetState();
}

class _ShareTargetSheetState extends State<ShareTargetSheet> {
  final _search = TextEditingController();
  String _needle = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _summary {
    final text = widget.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final clipped = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    final files = widget.files;
    if (files == 0) return clipped;
    final count = files == 1
        ? t('1 file')
        : t('{n} files', {'n': files});
    return clipped.isEmpty ? count : '$count · $clipped';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = widget.app;
    final all = ShareTargetSheet.choices(app, '');
    final shown =
        _needle.isEmpty ? all : ShareTargetSheet.choices(app, _needle);
    final summary = _summary;
    final height = MediaQuery.of(context).size.height;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height * 0.8),
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(t('Share to Nymbot'),
                  style: theme.textTheme.titleMedium),
            ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            if (all.length > ShareTargetSheet.searchAbove)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  key: const ValueKey('share-target-search'),
                  controller: _search,
                  onChanged: (v) => setState(() => _needle = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Padding(
                      padding: EdgeInsets.all(10),
                      child: NymGlyph('search', size: 16),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    hintText: t('Find a chat'),
                  ),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    key: const ValueKey('share-target-new'),
                    leading: const NymGlyph('plus', size: 18),
                    title: Text(t('New chat')),
                    onTap: () =>
                        Navigator.pop(context, const ShareTarget.fresh()),
                  ),
                  if (all.isNotEmpty) const Divider(height: 1),
                  for (final conv in shown)
                    ListTile(
                      key: ValueKey('share-target-${conv.id}'),
                      dense: true,
                      selected: conv.id == app.current?.id,
                      leading: conv.pinned
                          ? const NymGlyph('star',
                              size: 15,
                              filled: true,
                              color: NymbotColors.lightning)
                          : null,
                      horizontalTitleGap: conv.pinned ? null : 0,
                      title: Text(
                        conv.title.isEmpty ? t('New chat') : conv.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () =>
                          Navigator.pop(context, ShareTarget.existing(conv)),
                    ),
                  if (all.isNotEmpty && shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(t('No chat matches that.'),
                          style: TextStyle(color: theme.hintColor)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
