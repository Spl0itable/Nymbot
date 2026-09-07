import 'package:flutter/material.dart';

import '../../app.dart';
import '../artifact_screen.dart';
import '../i18n/i18n.dart';

Future<void> showArtifactsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ArtifactsSheet(),
    );

class _ArtifactsSheet extends StatelessWidget {
  const _ArtifactsSheet();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final made = app.artifacts.reversed.toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Artifacts'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('A reply that contains a whole file opens here instead of scrolling '
                  'away. Edits are kept as versions on this device.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (made.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  t('Nothing yet. A reply with a whole file in it lands here.'),
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
            for (final a in made)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    a.previewable
                        ? Icons.description_outlined
                        : Icons.code_outlined,
                    size: 20,
                  ),
                  title: Text(a.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      a.lang.isEmpty ? 'text' : a.lang,
                      t('{n} lines', {'n': a.lines}),
                      t('v{n}', {'n': a.versions.length}),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    showArtifact(context, a);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 17),
                    tooltip: t('Delete'),
                    onPressed: () => app.deleteArtifact(a.id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
