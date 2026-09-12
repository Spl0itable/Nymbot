import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app.dart';
import '../../models/workspace.dart';
import '../i18n/i18n.dart';
import '../i18n/language_select.dart';

Future<void> showAppearanceSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AppearanceSheet(),
    );

class _AppearanceSheet extends StatefulWidget {
  const _AppearanceSheet();

  @override
  State<_AppearanceSheet> createState() => _AppearanceSheetState();
}

class _AppearanceSheetState extends State<_AppearanceSheet> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;

    Widget toggle(String label, bool value, void Function(bool) set) =>
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: value,
          title: Text(label, style: const TextStyle(fontSize: 13)),
          onChanged: (v) {
            set(v);
            app.saveSettings(s);
          },
        );

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
            Text(t('Settings'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            // The language a reader wants is a setting like any other, not
            // something to go looking for behind their keys.
            if (I18n.available.isNotEmpty) ...[
              InputDecorator(
                decoration: InputDecoration(labelText: t('Language')),
                child: InkWell(
                  onTap: () => showLanguagePicker(context, app),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(I18n.lang == 'en'
                            ? 'English'
                            : I18n.available
                                .firstWhere((l) => l.code == I18n.lang,
                                    orElse: () => LanguageOption(
                                        code: I18n.lang, name: I18n.lang))
                                .label),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            DropdownButtonFormField<ChatTheme>(
              // ignore: deprecated_member_use
              value: s.theme,
              decoration: InputDecoration(labelText: t('Theme')),
              items: [
                DropdownMenuItem(
                    value: ChatTheme.system, child: Text(t('Match the system'))),
                DropdownMenuItem(value: ChatTheme.dark, child: Text(t('Dark'))),
                DropdownMenuItem(value: ChatTheme.light, child: Text(t('Light'))),
                DropdownMenuItem(
                    value: ChatTheme.terminal, child: Text(t('Terminal green'))),
                DropdownMenuItem(
                    value: ChatTheme.midnight, child: Text(t('Midnight'))),
              ],
              onChanged: (v) {
                s.theme = v ?? ChatTheme.system;
                app.saveSettings(s);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<ChatDensity>(
              // ignore: deprecated_member_use
              value: s.density,
              decoration: InputDecoration(labelText: t('Density')),
              items: [
                DropdownMenuItem(
                    value: ChatDensity.comfortable, child: Text(t('Comfortable'))),
                DropdownMenuItem(
                    value: ChatDensity.compact, child: Text(t('Compact'))),
                DropdownMenuItem(value: ChatDensity.roomy, child: Text(t('Roomy'))),
              ],
              onChanged: (v) {
                s.density = v ?? ChatDensity.comfortable;
                app.saveSettings(s);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<double>(
              // ignore: deprecated_member_use
              value: const [0.9, 1.0, 1.15, 1.3].contains(s.fontScale)
                  ? s.fontScale
                  : 1.0,
              decoration: InputDecoration(labelText: t('Text size')),
              items: [
                DropdownMenuItem(value: 0.9, child: Text(t('Small'))),
                DropdownMenuItem(value: 1.0, child: Text(t('Normal'))),
                DropdownMenuItem(value: 1.15, child: Text(t('Large'))),
                DropdownMenuItem(value: 1.3, child: Text(t('Larger'))),
              ],
              onChanged: (v) {
                s.fontScale = v ?? 1;
                app.saveSettings(s);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<SidebarGrouping>(
              // ignore: deprecated_member_use
              value: s.grouping,
              decoration: InputDecoration(labelText: t('Chat list')),
              items: [
                DropdownMenuItem(
                    value: SidebarGrouping.date, child: Text(t('By date'))),
                DropdownMenuItem(
                    value: SidebarGrouping.folder, child: Text(t('By folder'))),
                DropdownMenuItem(
                    value: SidebarGrouping.flat, child: Text(t('Flat'))),
              ],
              onChanged: (v) {
                s.grouping = v ?? SidebarGrouping.date;
                app.saveSettings(s);
              },
            ),
            const SizedBox(height: 12),
            Text(t('Messages'), style: Theme.of(context).textTheme.titleSmall),
            toggle(t('Bubbles rather than blocks'), s.bubbles, (v) => s.bubbles = v),
            toggle(t('Show avatars'), s.avatars, (v) => s.avatars = v),
            toggle(t('Show timestamps'), s.timestamps, (v) => s.timestamps = v),
            toggle(t('Reveal replies as they are read out'), s.typewriter,
                (v) => s.typewriter = v),
            toggle(t('Open reasoning by default'), s.showReasoningByDefault,
                (v) => s.showReasoningByDefault = v),
            toggle(t('Monospace replies'), s.monospaceReplies,
                (v) => s.monospaceReplies = v),
            toggle(t('Reduce motion'), s.reduceMotion, (v) => s.reduceMotion = v),
            const SizedBox(height: 12),
            Text(t('Behavior'), style: Theme.of(context).textTheme.titleSmall),
            toggle(t('Enter sends, Shift+Enter starts a line'), s.sendOnEnter,
                (v) => s.sendOnEnter = v),
            toggle(t('Show what the next reply will cost'), s.showCostEstimate,
                (v) => s.showCostEstimate = v),
            toggle(t('Sound when a reply lands'), s.soundOnReply,
                (v) => s.soundOnReply = v),
            toggle(t('Vibrate when a reply lands'), s.hapticOnReply,
                (v) => s.hapticOnReply = v),
            toggle(t('Read every reply aloud'), s.autoSpeak, (v) => s.autoSpeak = v),
            const SizedBox(height: 10),
            DropdownButtonFormField<double>(
              // ignore: deprecated_member_use
              value: const [0.8, 1.0, 1.25, 1.5].contains(s.speechRate)
                  ? s.speechRate
                  : 1.0,
              decoration: InputDecoration(labelText: t('Reading speed')),
              items: [
                DropdownMenuItem(value: 0.8, child: Text(t('Slow'))),
                DropdownMenuItem(value: 1.0, child: Text(t('Normal'))),
                DropdownMenuItem(value: 1.25, child: Text(t('Fast'))),
                DropdownMenuItem(value: 1.5, child: Text(t('Faster'))),
              ],
              onChanged: (v) {
                s.speechRate = v ?? 1;
                app.saveSettings(s);
              },
            ),
            const SizedBox(height: 16),
            Text(t('Long tasks'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              initialValue: s.autoContinue,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: t('When a repo task runs out of room')),
              items: [
                DropdownMenuItem(value: 0, child: Text(t('Stop and tell me'))),
                DropdownMenuItem(
                    value: 10, child: Text(t('Carry on, up to 10 more credits'))),
                DropdownMenuItem(
                    value: 25, child: Text(t('Carry on, up to 25 more credits'))),
                DropdownMenuItem(
                    value: 50, child: Text(t('Carry on, up to 50 more credits'))),
                DropdownMenuItem(
                    value: 100, child: Text(t('Carry on, up to 100 more credits'))),
                DropdownMenuItem(
                    value: -1, child: Text(t('Carry on until my balance runs out'))),
              ],
              onChanged: (v) => app.setAutoContinue(v ?? 0),
            ),
            const SizedBox(height: 4),
            Text(
              t('A repo task can stop mid-way when it has used its allowance of '
                  'model calls. Carrying on buys it another allowance from the '
                  'same balance, one leg at a time, and every leg says what it '
                  'cost. Stop cancels the rest.'),
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: s.showProgress,
              title: Text(t('Show what Nymbot is doing while it works'),
                  style: const TextStyle(fontSize: 13)),
              onChanged: app.setShowProgress,
            ),
            const SizedBox(height: 10),
            Text(t('Your data'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              initialValue: s.autoDeleteDays,
              decoration: InputDecoration(labelText: t('Delete chats after')),
              items: [
                DropdownMenuItem(value: 0, child: Text(t('Never'))),
                DropdownMenuItem(value: 1, child: Text(t('A day'))),
                DropdownMenuItem(value: 7, child: Text(t('A week'))),
                DropdownMenuItem(value: 30, child: Text(t('A month'))),
                DropdownMenuItem(value: 90, child: Text(t('Three months'))),
                DropdownMenuItem(value: 365, child: Text(t('A year'))),
              ],
              onChanged: (v) => app.setAutoDeleteDays(v ?? 0),
            ),
            const SizedBox(height: 4),
            Text(
              t('Swept when the app opens. Pinned chats are never swept.'),
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () async {
                    final payload = await app.store.exportAll();
                    await Share.share(payload, subject: 'Nymbot export');
                  },
                  child: Text(t('Export everything')),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await app.resetSettings();
                    if (context.mounted) setState(() {});
                  },
                  child: Text(t('Reset appearance')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
