import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/bot_files.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class FileCards extends StatelessWidget {
  const FileCards({super.key, required this.files});

  final List<BotFile> files;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < files.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            FileCard(file: files[i]),
          ],
        ],
      );
}

class FileCard extends StatefulWidget {
  const FileCard({super.key, required this.file});

  final BotFile file;

  @override
  State<FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<FileCard> {
  bool _busy = false;

  Color _tint(ThemeData theme) {
    switch (widget.file.kind) {
      case 'pdf':
        return theme.colorScheme.error;
      case 'sheet':
        return Colors.green.shade600;
      case 'archive':
        return Colors.orange.shade700;
      default:
        return theme.colorScheme.secondary;
    }
  }

  Future<void> _run(Future<bool> Function(BotFile) action, {bool saving = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await action(widget.file);
    if (mounted) setState(() => _busy = false);
    if (!ok && saving) {
      messenger?.showSnackBar(SnackBar(content: Text(t('Opened it outside the app — save it from there.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = widget.file;
    final tint = _tint(theme);
    return Container(
      key: ValueKey('file-card-${f.name}'),
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.tint(0.5),
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              f.ext.isEmpty ? '?' : f.ext.toUpperCase(),
              key: const ValueKey('file-card-ext'),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tint, letterSpacing: 0.4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(f.subtitle, style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            if (f.opens)
              IconButton(
                key: const ValueKey('file-open'),
                tooltip: t('Open'),
                icon: const NymGlyph('link', size: 18),
                onPressed: () => _run(BotFiles.open),
              ),
            IconButton(
              key: const ValueKey('file-save'),
              tooltip: t('Download'),
              icon: const NymGlyph('save', size: 18),
              onPressed: () => _run(BotFiles.save, saving: true),
            ),
          ],
        ],
      ),
    );
  }
}

class PendingFileCard extends StatelessWidget {
  const PendingFileCard({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('file-card-pending'),
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(t('Making the file…'), style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
