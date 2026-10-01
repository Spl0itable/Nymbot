import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../services/server_schedules.dart';
import 'i18n/i18n.dart';

class BackgroundSettings extends StatefulWidget {
  const BackgroundSettings({super.key, this.android});

  final bool? android;

  @override
  State<BackgroundSettings> createState() => _BackgroundSettingsState();
}

class _BackgroundSettingsState extends State<BackgroundSettings> {
  List<({String package, String name})>? _distributors;
  String? _endpoint;
  bool _loading = false;

  bool get _android =>
      widget.android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<void> _load() async {
    if (_loading || !_android) return;
    _loading = true;
    final app = AppScope.read(context);
    final found = await app.pushDistributors();
    final endpoint = await app.unifiedPushEndpoint();
    if (!mounted) return;
    setState(() {
      _distributors = found;
      _endpoint = endpoint;
      _loading = false;
    });
  }

  void _toast(String? text) {
    if (text == null || text.isEmpty || !mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pick(String? package) async {
    final app = AppScope.read(context);
    await app.useUnifiedPush(package);
    if (package == null) {
      if (mounted) setState(() => _endpoint = null);
      return;
    }
    for (var i = 0; i < 10 && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final endpoint = await app.unifiedPushEndpoint();
      if (!mounted) return;
      if (endpoint != null) {
        setState(() => _endpoint = endpoint);
        return;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    final wanted = s.backgroundJobs == true || s.serverSchedules;
    if (wanted && _android && _distributors == null && !_loading) {
      scheduleMicrotask(_load);
    }
    final chosen = app.unifiedPushDistributor;
    final names = {for (final d in _distributors ?? const []) d.package: d.name};
    final picked = chosen != null && names.containsKey(chosen) ? chosen : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const ValueKey('background-jobs'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: s.backgroundJobs == true,
          title: Text(t('Keep long tasks going on the server while the app is closed'),
              style: const TextStyle(fontSize: 13)),
          onChanged: (v) => app.setBackgroundJobs(v == true),
        ),
        Text(
            t("Off unless you turn it on. When a task runs out of room, Nymbot's server carries it on by itself instead of waiting for this device. To do that it keeps what the next step needs, sealed with a key the server holds, for at most 6 hours: the task's saved progress and its settings, including the tokens for the repositories and connectors it uses. It spends no more than the budget above and deletes it all when the task ends. Never for anonymous chats or the free allowance."),
            style: hint),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const ValueKey('server-schedules'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: s.serverSchedules,
          title: Text(t("Let scheduled prompts use Nymbot's server while the app is closed"),
              style: const TextStyle(fontSize: 13)),
          onChanged: (v) async => _toast(await app.setServerSchedules(v == true)),
        ),
        Text(
            t("Off unless you turn it on. Each scheduled prompt can then choose to notify you when it is due, or to run on Nymbot's server. Turning this off deletes every schedule the server holds at once."),
            style: hint),
        if (s.serverSchedules) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const ValueKey('schedule-daily-cap'),
            value: ServerSchedules.dailyCaps.contains(s.scheduleDailyCap)
                ? s.scheduleDailyCap
                : ServerSchedules.defaultDaily,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: t('Most credits server schedules may spend in a day')),
            items: [
              for (final n in ServerSchedules.dailyCaps)
                DropdownMenuItem(
                    value: n, child: Text(t('{n} credits', {'n': n}))),
            ],
            onChanged: (v) => app.setScheduleDailyCap(v ?? ServerSchedules.defaultDaily),
          ),
        ],
        if (wanted && _android) ...[
          const SizedBox(height: 10),
          if (_distributors != null && _distributors!.isEmpty)
            Text(t('No UnifiedPush distributor is installed.'),
                style: const TextStyle(fontSize: 13))
          else if (_distributors != null)
            DropdownButtonFormField<String>(
              key: const ValueKey('unifiedpush'),
              value: picked,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: t('Instant notifications with UnifiedPush')),
              items: [
                DropdownMenuItem(value: '', child: Text(t('Off'))),
                for (final d in _distributors!)
                  DropdownMenuItem(value: d.package, child: Text(d.name)),
              ],
              onChanged: (v) => _pick(v == null || v.isEmpty ? null : v),
            ),
          if (picked.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
                _endpoint == null
                    ? t('Waiting for {name} to answer.', {'name': names[picked]})
                    : t('Connected to {name}.', {'name': names[picked]}),
                style: hint),
          ],
          const SizedBox(height: 4),
          Text(
              t("Without Google's push service, Nymbot checks for finished tasks about every 15 minutes while the app is closed. For instant notifications, install a UnifiedPush distributor such as ntfy and pick it here. The notification is encrypted on the server so only this device can read it."),
              style: hint),
        ],
      ],
    );
  }
}
