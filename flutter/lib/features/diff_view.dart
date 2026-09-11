import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n/i18n.dart';
import '../core/theme/theme.dart';

enum DiffLineKind { add, remove, context, hunk, meta }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});

  final DiffLineKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

/// One file's worth of a unified diff, already counted so the header can say
/// what changed without the reader tallying `+` lines by eye.
class DiffFile {
  DiffFile({required this.path, List<DiffLine>? lines})
      : lines = lines ?? [];

  final String path;
  final List<DiffLine> lines;

  int get added => lines.where((l) => l.kind == DiffLineKind.add).length;
  int get removed => lines.where((l) => l.kind == DiffLineKind.remove).length;

  /// Splits a unified diff into files. Anything before the first file header
  /// is kept under an empty path, so a bare hunk still renders rather than
  /// being silently dropped.
  static List<DiffFile> parse(String source) {
    final files = <DiffFile>[];
    DiffFile? current;
    var oldNo = 0;
    var newNo = 0;

    void ensure(String path) {
      if (current == null || current!.path != path) {
        current = DiffFile(path: path);
        files.add(current!);
      }
    }

    for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
      final gitHeader = RegExp(r'^diff --git a/(\S+) b/(\S+)').firstMatch(raw);
      if (gitHeader != null) {
        current = DiffFile(path: gitHeader.group(2)!);
        files.add(current!);
        continue;
      }
      if (raw.startsWith('+++ ')) {
        final path = raw.substring(4).trim();
        final cleaned = path.startsWith('b/') ? path.substring(2) : path;
        if (cleaned != '/dev/null') {
          if (current == null || current!.lines.isNotEmpty) {
            current = DiffFile(path: cleaned);
            files.add(current!);
          } else {
            files.removeLast();
            current = DiffFile(path: cleaned);
            files.add(current!);
          }
        }
        continue;
      }
      if (raw.startsWith('--- ') || raw.startsWith('index ') ||
          raw.startsWith('new file') || raw.startsWith('deleted file') ||
          raw.startsWith('similarity index') || raw.startsWith('rename ')) {
        continue;
      }

      final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@').firstMatch(raw);
      if (hunk != null) {
        ensure(current?.path ?? '');
        oldNo = int.parse(hunk.group(1)!);
        newNo = int.parse(hunk.group(2)!);
        current!.lines.add(DiffLine(DiffLineKind.hunk, raw));
        continue;
      }
      if (current == null) {
        if (raw.trim().isEmpty) continue;
        ensure('');
      }
      if (raw.startsWith('+')) {
        current!.lines.add(DiffLine(DiffLineKind.add, raw, newNo: newNo++));
      } else if (raw.startsWith('-')) {
        current!.lines.add(DiffLine(DiffLineKind.remove, raw, oldNo: oldNo++));
      } else if (raw.startsWith('\\')) {
        current!.lines.add(DiffLine(DiffLineKind.meta, raw));
      } else {
        current!.lines
            .add(DiffLine(DiffLineKind.context, raw, oldNo: oldNo++, newNo: newNo++));
      }
    }

    return files.where((f) => f.lines.isNotEmpty).toList();
  }
}

/// A ```diff block, read as a patch rather than as coloured text: one panel per
/// file, each saying what it costs before you read a line of it.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final files = DiffFile.parse(source);
    if (files.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final file in files) _FilePanel(file: file, source: source),
      ],
    );
  }
}

class _FilePanel extends StatefulWidget {
  const _FilePanel({required this.file, required this.source});

  final DiffFile file;
  final String source;

  @override
  State<_FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<_FilePanel> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = widget.file;
    final dark = theme.brightness == Brightness.dark;
    final addBg = (dark ? const Color(0xFF1B4721) : const Color(0xFFE6FFEC))
        .withValues(alpha: dark ? 0.55 : 1);
    final delBg = (dark ? const Color(0xFF5A1E22) : const Color(0xFFFFEBE9))
        .withValues(alpha: dark ? 0.55 : 1);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
              decoration: BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_more : Icons.chevron_right,
                      size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      file.path.isEmpty ? t('patch') : file.path,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('+${file.added}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
                          color: Color(0xFF2DA44E))),
                  const SizedBox(width: 6),
                  Text('−${file.removed}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
                          color: Color(0xFFCF222E))),
                  IconButton(
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    tooltip: t('Copy'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 30, minHeight: 28),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: widget.source)),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in file.lines)
                      _row(context, line, addBg, delBg),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
      BuildContext context, DiffLine line, Color addBg, Color delBg) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
      fontSize: 11.5,
      height: 1.45,
      color: switch (line.kind) {
        DiffLineKind.hunk => theme.hintColor,
        DiffLineKind.meta => theme.hintColor,
        _ => theme.textTheme.bodyMedium?.color,
      },
    );
    final background = switch (line.kind) {
      DiffLineKind.add => addBg,
      DiffLineKind.remove => delBg,
      DiffLineKind.hunk => theme.dividerColor.withValues(alpha: 0.35),
      _ => null,
    };
    String gutter(int? n) => n == null ? '' : '$n';

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(gutter(line.oldNo),
                textAlign: TextAlign.right,
                style: mono.copyWith(color: theme.hintColor, fontSize: 10)),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            child: Text(gutter(line.newNo),
                textAlign: TextAlign.right,
                style: mono.copyWith(color: theme.hintColor, fontSize: 10)),
          ),
          const SizedBox(width: 10),
          Text(line.text, style: mono),
        ],
      ),
    );
  }
}
