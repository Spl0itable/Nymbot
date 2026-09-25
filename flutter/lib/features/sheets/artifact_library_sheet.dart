import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/artifact.dart';
import '../../models/conversation.dart';
import '../../services/share_file.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import '../nym_glyph.dart';
import 'sheet.dart';

typedef ArtifactJump = ({
  String conversationId,
  String? messageId,
  String? artifactId,
});

enum ArtifactKind { code, doc, page, data }

ArtifactKind artifactKindOf(String lang) {
  final l = lang.toLowerCase();
  if (const {'html', 'htm', 'svg', 'xml'}.contains(l)) return ArtifactKind.page;
  if (const {'markdown', 'md', 'txt', 'text', ''}.contains(l)) {
    return ArtifactKind.doc;
  }
  if (const {'json', 'csv', 'tsv', 'yaml', 'yml', 'toml', 'sql'}.contains(l)) {
    return ArtifactKind.data;
  }
  return ArtifactKind.code;
}

class ArtifactEntry {
  const ArtifactEntry(this.artifact, this.conv);

  final Artifact artifact;
  final Conversation conv;

  ArtifactKind get kind => artifactKindOf(artifact.lang);
}

List<ArtifactEntry> artifactIndex(AppController app) {
  final rows = <ArtifactEntry>[];
  for (final conv in app.conversations) {
    if (conv.ephemeral) continue;
    for (final a in app.store.keptArtifacts(conv.id)) {
      rows.add(ArtifactEntry(a, conv));
    }
  }
  rows.sort((x, y) => y.artifact.updatedAt.compareTo(x.artifact.updatedAt));
  return rows;
}

Future<ArtifactJump?> showArtifactLibrarySheet(BuildContext context) =>
    showNymSheet<ArtifactJump>(
      context,
      (_) => const _ArtifactLibrarySheet(),
    );

class _ArtifactLibrarySheet extends StatefulWidget {
  const _ArtifactLibrarySheet();

  @override
  State<_ArtifactLibrarySheet> createState() => _ArtifactLibrarySheetState();
}

class _ArtifactLibrarySheetState extends State<_ArtifactLibrarySheet> {
  final _search = TextEditingController();
  late final List<ArtifactEntry> _rows = artifactIndex(AppScope.read(context));
  ArtifactKind? _kind;
  int _limit = 100;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ArtifactEntry> get _matches {
    final term = _search.text.trim().toLowerCase();
    return _rows.where((row) {
      if (_kind != null && row.kind != _kind) return false;
      if (term.isEmpty) return true;
      final a = row.artifact;
      return a.title.toLowerCase().contains(term) ||
          a.lang.toLowerCase().contains(term) ||
          row.conv.title.toLowerCase().contains(term) ||
          a.body.toLowerCase().contains(term);
    }).toList();
  }

  String _day(DateTime at) {
    final d = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _name(Artifact a) {
    final base = a.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w.-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${base.isEmpty ? 'artifact' : base}.${a.extension}';
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Widget _row(ArtifactEntry row) {
    final a = row.artifact;
    final title = a.title.isEmpty ? t('Untitled') : a.title;
    final chat = row.conv.title.isEmpty ? t('New chat') : row.conv.title;
    return Card(
      key: ValueKey('artifact-library-${a.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: NymGlyph(a.previewable ? 'artifacts' : 'code', size: 20),
        title: Semantics(
          label: t('Open {title} from {chat}', {'title': title, 'chat': chat}),
          excludeSemantics: true,
          child: Text(title, overflow: TextOverflow.ellipsis),
        ),
        subtitle: Text(
          [
            a.lang.isEmpty ? 'text' : a.lang,
            t('{n} lines', {'n': a.lines}),
            chat,
            _day(a.updatedAt),
            if (row.conv.anon) t('anon'),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        onTap: () => Navigator.pop(context, (
          conversationId: row.conv.id,
          messageId: a.messageId,
          artifactId: a.id,
        )),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const NymGlyph('copy', size: 17),
              tooltip: t('Copy'),
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: a.body));
                _say(t('Copied.'));
              },
            ),
            IconButton(
              icon: const NymGlyph('save', size: 17),
              tooltip: t('Download'),
              visualDensity: VisualDensity.compact,
              onPressed: () => ShareFile.text(a.body,
                  name: _name(a), mime: 'text/plain', subject: title),
            ),
            IconButton(
              icon: const NymGlyph('prompt', size: 17),
              tooltip: t('Go to chat'),
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.pop(context, (
                conversationId: row.conv.id,
                messageId: a.messageId,
                artifactId: null,
              )),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _matches;
    final kinds = <(ArtifactKind?, String)>[
      (null, t('All')),
      (ArtifactKind.code, t('Code')),
      (ArtifactKind.doc, t('Documents')),
      (ArtifactKind.page, t('Pages')),
      (ArtifactKind.data, t('Data')),
    ];
    final shown = matches.take(_limit).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(t('Artifacts'), style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 6),
          Text(
            t('Every file a reply has produced, across all your chats, newest first.'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('artifact-library-search'),
            controller: _search,
            decoration: InputDecoration(
              isDense: true,
              hintText: t('Search artifacts'),
              prefixIcon: const NymGlyph('search', size: 16),
            ),
            onChanged: (_) => setState(() => _limit = 100),
          ),
          const SizedBox(height: 8),
          Semantics(
            label: t('Filter by type'),
            container: true,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final kind in kinds)
                  ChoiceChip(
                    key: ValueKey('artifact-kind-${kind.$1?.name ?? 'all'}'),
                    label: Text(kind.$2, style: const TextStyle(fontSize: 11)),
                    selected: _kind == kind.$1,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() {
                      _kind = kind.$1;
                      _limit = 100;
                    }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              _rows.isEmpty
                  ? t('Nothing yet. A reply with a whole file in it lands here.')
                  : matches.length == 1
                      ? t('1 artifact')
                      : t('{n} artifacts', {'n': matches.length}),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
          const SizedBox(height: 6),
          if (_rows.isNotEmpty && matches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t('Nothing matches that.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: shown.length + (matches.length > _limit ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == shown.length) {
                  return TextButton(
                    onPressed: () => setState(() => _limit += 100),
                    child: Text(t('Show more')),
                  );
                }
                return _row(shown[i]);
              },
            ),
          ),
        ],
      ),
    );
  }
}
