import 'package:flutter/material.dart';

import '../app.dart';
import '../models/conversation.dart';
import '../services/spend_caps.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'sheets/sheet.dart';

Future<String> showCapPrompt(BuildContext context, CapPrompt prompt) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(prompt.title),
      content: Text(prompt.body),
      actions: [
        TextButton(
          key: const Key('capCancel'),
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: Text(t('Cancel')),
        ),
        TextButton(
          key: const Key('capRaise'),
          onPressed: () => Navigator.pop(context, 'raise'),
          child: Text(t('Raise the cap')),
        ),
        if (prompt.sendOnce)
          FilledButton(
            key: const Key('capSendOnce'),
            onPressed: () => Navigator.pop(context, 'send'),
            child: Text(t('Send anyway once')),
          ),
      ],
    ),
  );
  return choice ?? 'cancel';
}

Future<void> showCapsSheet(BuildContext context, Conversation conv) =>
    showNymSheet<void>(context, (_) => CapsSheet(conv: conv));

class CapsSheet extends StatefulWidget {
  const CapsSheet({super.key, required this.conv});

  final Conversation conv;

  @override
  State<CapsSheet> createState() => _CapsSheetState();
}

class _CapsSheetState extends State<CapsSheet> {
  late final TextEditingController _total = TextEditingController(
      text: widget.conv.capSats == null ? '' : '${widget.conv.capSats}');
  late final TextEditingController _reply = TextEditingController(
      text: widget.conv.askAboveSats == null ? '' : '${widget.conv.askAboveSats}');
  String _status = '';

  @override
  void dispose() {
    _total.dispose();
    _reply.dispose();
    super.dispose();
  }

  (bool, int?) _read(TextEditingController c) {
    final raw = c.text.trim();
    if (raw.isEmpty) return (true, null);
    final n = num.tryParse(raw);
    if (n == null || n < 0) return (false, null);
    return (true, n > 0 ? n.floor() : null);
  }

  Future<void> _save(AppController app, {bool clear = false}) async {
    final total = clear ? (true, null) : _read(_total);
    final reply = clear ? (true, null) : _read(_reply);
    if (!total.$1 || !reply.$1) {
      setState(() => _status = t('Caps are whole numbers of sats.'));
      return;
    }
    await app.setCaps(widget.conv, total: total.$2, perReply: reply.$2);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final bot = app.botOf(widget.conv);
    final theme = Theme.of(context);
    final botCaps = bot != null && (bot.capSats != null || bot.askAboveSats != null);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Spending caps'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            t('Limits for this chat, in sats, whichever tier answers. Replies are counted at each tier\'s price per credit. A bot\'s own caps apply too, and the stricter one wins.'),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('capTotal'),
            controller: _total,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t('Stop this chat at (sats)'),
              hintText: t('No cap'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('capReply'),
            controller: _reply,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t('Ask me before a reply that could cost more than (sats)'),
              hintText: t('No cap'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            [
              t('Spent here so far: {n} sats.',
                  {'n': figure(app.capSpentOf(widget.conv).round())}),
              if (botCaps)
                t('{bot} also sets caps; the stricter of the two applies.',
                    {'bot': bot.name.isEmpty ? t('This bot') : bot.name}),
            ].join(' '),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_status,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('capSave'),
                  onPressed: () => _save(app),
                  child: Text(t('Save')),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _save(app, clear: true),
                child: Text(t('Remove caps')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CapBadge extends StatelessWidget {
  const CapBadge({super.key, required this.conv});

  final Conversation conv;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final line = app.capUsedLineOf(conv);
    if (line.isEmpty) return const SizedBox.shrink();
    final lim = app.capLimitsOf(conv);
    final full = lim.total != null && app.capSpentOf(conv) >= lim.total!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        onTap: () => showCapsSheet(context, conv),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          key: const Key('capBadge'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            border: Border.all(
                color: full ? theme.colorScheme.error : theme.dividerColor),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(line,
              style: TextStyle(
                  fontSize: 11,
                  color: full ? theme.colorScheme.error : theme.hintColor)),
        ),
      ),
    );
  }
}

String withCapRoom(AppController app, String hint) {
  final room = app.capRoomLine;
  if (room.isEmpty) return hint;
  return hint.isEmpty ? room : '$hint · $room';
}
