import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../../models/schedule.dart';
import '../../state/app_controller.dart';
import '../../services/chat_engine.dart';
import '../../services/server_schedules.dart';
import '../i18n/i18n.dart';
import 'sheet.dart';
import '../nym_glyph.dart';

Future<String?> showSchedulesSheet(BuildContext context, {String prefill = ''}) =>
    showNymSheet<String>(
      context,
      (_) => _SchedulesSheet(prefill: prefill),
    );

String repeatLabel(ScheduleRepeat repeat) => switch (repeat) {
      ScheduleRepeat.hourly => t('Every hour'),
      ScheduleRepeat.daily => t('Every day'),
      ScheduleRepeat.weekly => t('Every week'),
      ScheduleRepeat.once => t('Once'),
    };

class _SchedulesSheet extends StatefulWidget {
  const _SchedulesSheet({this.prefill = ''});

  final String prefill;

  @override
  State<_SchedulesSheet> createState() => _SchedulesSheetState();
}

class _SchedulesSheetState extends State<_SchedulesSheet> {
  final _title = TextEditingController();
  final _prompt = TextEditingController();
  String? _editingId;
  ScheduleRepeat _repeat = ScheduleRepeat.daily;
  DateTime _when = DateTime.now().add(const Duration(hours: 1));
  bool _here = false;
  String _error = '';
  String? _mode;
  int _cap = ServerSchedules.defaultCap;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _prompt.text = widget.prefill;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshServerSchedules();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _editingId = null;
        _repeat = ScheduleRepeat.daily;
        _when = DateTime.now().add(const Duration(hours: 1));
        _here = false;
        _error = '';
        _mode = null;
        _cap = ServerSchedules.defaultCap;
        _title.clear();
        _prompt.clear();
      });

  void _edit(Schedule entry) => setState(() {
        _editingId = entry.id;
        _repeat = entry.repeat;
        _when = entry.nextAt;
        _here = entry.convId != null;
        _error = '';
        _status = '';
        _mode = entry.server;
        _cap = ServerSchedules.runCaps.contains(entry.serverCap)
            ? entry.serverCap
            : ServerSchedules.defaultCap;
        _title.text = entry.title;
        _prompt.text = entry.prompt;
      });

  Future<void> _pickWhen() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );
    if (time == null || !mounted) return;
    setState(() {
      _when = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      setState(() => _error = t('Give it something to ask.'));
      return;
    }
    final existing = app.schedules.where((s) => s.id == _editingId);
    final entry = existing.isEmpty
        ? Schedule(id: bytesToHex(randomBytes(8)))
        : existing.first;
    final title = _title.text.trim();
    entry.title = title.isEmpty ? ChatEngine.titleFor(prompt) : title;
    entry.prompt = prompt;
    entry.repeat = _repeat;
    entry.nextAt = _when;
    entry.convId = _here ? app.current?.id : null;
    entry.enabled = true;
    entry.serverCap = _cap;
    await app.saveSchedule(entry);
    var said = '';
    if (app.settings.serverSchedules && (_mode != null || entry.server != null)) {
      var mode = _mode;
      if (mode == 'run' && mounted && !await _confirmRun(_cap)) mode = entry.server;
      said = await app.saveServerSchedule(entry, mode);
    }
    if (!mounted) return;
    _reset();
    setState(() => _status = said);
  }

  Future<bool> _confirmRun(int cap) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(t('Run this on the server?')),
          content: SingleChildScrollView(child: Text(ServerSchedules.consent(cap))),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(t('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t('Run it on the server')),
            ),
          ],
        ),
      ) ??
      false;

  Widget _choice(String? value, String label, String hint) {
    final on = _mode == value;
    return ListTile(
      key: ValueKey('schedule-mode-${value ?? 'device'}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      selected: on,
      leading: NymGlyph('dot',
          size: 14,
          filled: on,
          color: on ? Theme.of(context).colorScheme.primary : Theme.of(context).hintColor),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: hint.isEmpty ? null : Text(hint, style: const TextStyle(fontSize: 11)),
      onTap: () => setState(() => _mode = value),
    );
  }

  Widget _serverChoices(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          Text(t('While the app is closed'), style: Theme.of(context).textTheme.labelLarge),
          _choice('notify', t('Notify me instead of running'),
              t('The server keeps only the due time and where to send the notification. The prompt stays on this device, and the app runs it when you open it.')),
          _choice('run', t('Run on the server'), ''),
          if (_mode == 'run') ...[
            DropdownButtonFormField<int>(
              key: const ValueKey('schedule-run-cap'),
              initialValue: _cap,
              isExpanded: true,
              decoration: InputDecoration(labelText: t('Most credits one run may spend')),
              items: [
                for (final n in ServerSchedules.runCaps)
                  DropdownMenuItem(
                      value: n,
                      child: Text(n == 1 ? t('1 credit') : t('{n} credits', {'n': n}))),
              ],
              onChanged: (v) => setState(() => _cap = v ?? ServerSchedules.defaultCap),
            ),
            const SizedBox(height: 4),
            Text(ServerSchedules.consent(_cap), style: const TextStyle(fontSize: 11)),
          ],
          _choice(null, t('Neither: only while the app is open'), ''),
        ],
      );

  String _stamp(DateTime at) {
    final d = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _details(BuildContext context, AppController app, Schedule entry) {
    final chatId = entry.convId ?? entry.lastConvId;
    Conversation? chat;
    for (final c in app.conversations) {
      if (c.id == chatId) chat = c;
    }
    final where = entry.convId != null
        ? (chat == null
            ? t('Its chat was deleted')
            : (chat.title.isEmpty ? t('New chat') : chat.title))
        : t('A new chat each run');
    final ran = entry.lastRunAt;
    final last = ran == null || ran.millisecondsSinceEpoch == 0
        ? ''
        : t('Last run {when}', {'when': _stamp(ran)});
    final target = chat;
    return Opacity(
      opacity: entry.enabled ? 1 : 0.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            [
              repeatLabel(entry.repeat),
              entry.enabled ? _stamp(entry.nextAt) : t('Paused'),
              entry.runs > 0
                  ? t('{n} runs', {'n': entry.runs})
                  : t('never run'),
            ].join(' · '),
            style: const TextStyle(fontSize: 11),
          ),
          Text(
            last.isEmpty ? where : '$where · $last',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          if (ServerSchedules.rowLine(entry).isNotEmpty)
            Text(ServerSchedules.rowLine(entry), style: const TextStyle(fontSize: 11)),
          if (target != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('schedule-chat-${entry.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  await app.open(target);
                  navigator.pop(target.id);
                },
                child: Text(t('Go to chat')),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);

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
            Text(t('Scheduled prompts'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              app.settings.serverSchedules
                  ? t("A prompt Nymbot sends for you: once, hourly, daily or weekly. By default it runs while the app is open, and a run that came due while it was shut fires once when you come back. Turn on server schedules in Settings and each schedule can instead notify you when it is due (the server keeps only the time), or run on Nymbot's server while the app is closed (the server keeps the prompt, sealed, and spends up to the cap you set per run). Turning the switch off, deleting a schedule or wiping the app deletes the server copy at once.")
                  : t('A prompt Nymbot sends for you on a schedule. There is no server '
                      'doing this: it runs while the app is open, and a run that came '
                      'due while it was shut runs once when you come back rather than '
                      'catching up on all of them. Each run costs a reply, like any '
                      'other.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (app.schedules.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  t('Nothing scheduled. A standing question — a digest, a check on a repository — goes here.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final entry in app.schedules)
              Card(
                key: ValueKey('schedule-${entry.id}'),
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: NymGlyph(
                    'scheduled',
                    size: 20,
                    color: entry.enabled ? null : Theme.of(context).disabledColor,
                  ),
                  title: Text(
                      entry.title.isEmpty ? t('Untitled') : entry.title,
                      overflow: TextOverflow.ellipsis),
                  subtitle: _details(context, app, entry),
                  onTap: () => _edit(entry),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          entry.enabled
                              ? Icons.pause_outlined
                              : Icons.play_arrow_outlined,
                          size: 18,
                        ),
                        tooltip: entry.enabled ? t('Pause') : t('Resume'),
                        onPressed: () => app.toggleSchedule(entry),
                      ),
                      IconButton(
                        icon: const NymGlyph('send', size: 18),
                        tooltip: t('Run now'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          app.runSchedule(entry.id);
                        },
                      ),
                      IconButton(
                        icon: const NymGlyph('close', size: 17),
                        tooltip: t('Delete'),
                        onPressed: () => app.deleteSchedule(entry.id),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 24),
            Text(
              _editingId == null
                  ? t('New scheduled prompt')
                  : t('Edit scheduled prompt'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _title,
              decoration: InputDecoration(labelText: t('Name')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              maxLines: 4,
              minLines: 2,
              scrollPadding: textAreaScrollPadding(context, 2),
              decoration: InputDecoration(
                labelText: t('Prompt'),
                hintText: t('What should it ask?'),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<ScheduleRepeat>(
              isExpanded: true,
              value: _repeat,
              decoration: InputDecoration(labelText: t('How often')),
              items: [
                for (final r in ScheduleRepeat.values)
                  DropdownMenuItem(value: r, child: Text(repeatLabel(r))),
              ],
              onChanged: (v) => setState(() => _repeat = v ?? _repeat),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _pickWhen,
              icon: const NymGlyph('scheduled', size: 18),
              label: Text('${t('First run')}: ${_stamp(_when)}'),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _here,
              title: Text(
                  t('Send it into this chat rather than a new one'),
                  style: const TextStyle(fontSize: 13)),
              onChanged: (v) => setState(() => _here = v),
            ),
            if (app.settings.serverSchedules) _serverChoices(context),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_status, style: const TextStyle(fontSize: 12)),
              ),
            if (_error.isNotEmpty)
              Text(_error,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(t('Save it')),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: TextButton(
                    onPressed: _reset,
                    child: Text(t('Clear the form')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
