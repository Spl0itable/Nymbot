import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../models/artifact.dart';
import 'artifact_preview.dart';
import 'code_highlight.dart';
import 'markdown_body.dart';
import 'i18n/i18n.dart';
import '../core/theme/theme.dart';
import 'nym_glyph.dart';

Future<void> showArtifact(BuildContext context, Artifact artifact) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArtifactScreen(artifactId: artifact.id),
      fullscreenDialog: true,
    ));

class ArtifactScreen extends StatefulWidget {
  const ArtifactScreen({super.key, required this.artifactId});

  final String artifactId;

  @override
  State<ArtifactScreen> createState() => _ArtifactScreenState();
}

class _ArtifactScreenState extends State<ArtifactScreen> {
  final _body = TextEditingController();
  final _title = TextEditingController();
  int _tab = 0;
  bool _dirty = false;
  bool _primed = false;

  @override
  void dispose() {
    _body.dispose();
    _title.dispose();
    super.dispose();
  }

  Artifact? _find(BuildContext context) {
    final app = AppScope.of(context);
    for (final a in app.artifacts) {
      if (a.id == widget.artifactId) return a;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final artifact = _find(context);
    if (artifact == null) return const Scaffold(body: SizedBox.shrink());

    if (!_primed) {
      _primed = true;
      _body.text = artifact.body;
      _title.text = artifact.title;
      _tab = artifact.readable ? 0 : (artifact.previewable ? 0 : 1);
    }

    final tabs = <(int, String)>[
      if (artifact.previewable) (0, t('Preview')),
      (1, t('Source')),
      (2, t('Versions')),
    ];
    final active = tabs.any((x) => x.$1 == _tab) ? _tab : 1;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final choice = await _askToKeep(context);
        if (choice == null || !mounted) return;
        if (choice) await app.updateArtifact(artifact.id, _body.text);
        if (!mounted) return;
        setState(() => _dirty = false);
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _title,
            decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            style: Theme.of(context).textTheme.titleMedium,
            onSubmitted: (v) => app.renameArtifact(artifact.id, v),
            onTapOutside: (_) => app.renameArtifact(artifact.id, _title.text),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(artifact.lang.isEmpty ? 'text' : artifact.lang,
                    style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11)),
              ),
            ),
            IconButton(
              icon: const NymGlyph('copy', size: 20),
              tooltip: t('Copy'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: _body.text));
                messenger
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(
                      content: Text(t('Copied.')),
                      duration: const Duration(seconds: 2)));
              },
            ),
            IconButton(
              icon: const Icon(Icons.ios_share, size: 20),
              tooltip: t('Share'),
              onPressed: () => Share.share(_body.text, subject: artifact.title),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  for (final tab in tabs)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(tab.$2, style: const TextStyle(fontSize: 12)),
                        selected: active == tab.$1,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _tab = tab.$1),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: _view(context, artifact, active)),
          ],
        ),
        floatingActionButton: (_dirty && active == 1)
            ? FloatingActionButton.extended(
                icon: const NymGlyph('check', size: 18),
                label: Text(t('Save version')),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await app.updateArtifact(artifact.id, _body.text);
                  if (!mounted) return;
                  setState(() => _dirty = false);
                  final saved = app.artifacts
                      .where((a) => a.id == artifact.id)
                      .map((a) => a.versions.length)
                      .followedBy(const [1])
                      .first;
                  messenger.showSnackBar(
                    SnackBar(content: Text(t('Saved as version {n}.', {'n': saved}))),
                  );
                },
              )
            : null,
      ),
    );
  }

  Future<bool?> _askToKeep(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('Keep your changes?')),
          content: Text(
              t('The source has edits that are not saved as a version yet.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t('Keep editing'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t('Discard'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t('Save version'))),
          ],
        ),
      );

  Widget _view(BuildContext context, Artifact artifact, int tab) {
    if (tab == 0) {
      if (artifact.readable) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MarkdownBody(artifact.body),
        );
      }
      return ArtifactWebPreview(
        body: artifact.body,
        lang: artifact.lang,
        fallback: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightedCode(code: artifact.body, language: artifact.lang),
          ),
        ),
      );
    }
    if (tab == 1) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _body,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (v) {
            final dirty = v != artifact.body;
            if (dirty != _dirty) setState(() => _dirty = dirty);
          },
        ),
      );
    }
    final app = AppScope.of(context);
    final versions = artifact.versions.reversed.toList();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: versions.length,
      itemBuilder: (context, i) {
        final v = versions[i];
        final number = versions.length - i;
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            title: Text(t('Version {n}', {'n': number})),
            subtitle: Text(
              '${v.body.split('\n').length} ${t('lines')}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: i == 0
                ? Text(t('current'), style: const TextStyle(fontSize: 11))
                : TextButton(
                    onPressed: () async {
                      await app.revertArtifact(artifact.id, artifact.versions.length - 1 - i);
                      if (!mounted) return;
                      final fresh = app.artifacts
                          .where((a) => a.id == artifact.id)
                          .map((a) => a.body)
                          .followedBy([_body.text])
                          .first;
                      setState(() {
                        _body.text = fresh;
                        _dirty = false;
                      });
                    },
                    child: Text(t('Restore')),
                  ),
          ),
        );
      },
    );
  }
}

/// The card a reply shows for a file it produced.
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.artifact, required this.onOpen});

  final Artifact artifact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onOpen,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            NymGlyph(
              artifact.previewable ? 'artifacts' : 'code',
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(artifact.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(
                    [
                      artifact.lang.isEmpty ? 'text' : artifact.lang,
                      t('{n} lines', {'n': artifact.lines}),
                      if (artifact.versions.length > 1)
                        t('v{n}', {'n': artifact.versions.length}),
                    ].join(' · '),
                    style: TextStyle(fontSize: 11, color: theme.hintColor),
                  ),
                ],
              ),
            ),
            NymGlyph('chevron',
                size: 18, color: theme.hintColor, quarterTurns: 3),
          ],
        ),
      ),
    );
  }
}
