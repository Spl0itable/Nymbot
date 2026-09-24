import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/team.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import 'models_sheet.dart';
import 'sheet.dart';

Future<void> showTeamSheet(BuildContext context) async {
  final app = AppScope.read(context);
  final conv = app.current;
  if (conv == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final reason = app.teamLeadOf(conv) == null
      ? Team.needsPro()
      : app.teamModeOf(conv) == null
          ? Team.wrongTask()
          : null;
  if (reason != null) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(reason)));
    return;
  }
  final said = await showNymSheet<String>(context, (_) => const _TeamSheet());
  if (said == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Text(said),
    ));
}

class _TeamSheet extends StatefulWidget {
  const _TeamSheet();

  @override
  State<_TeamSheet> createState() => _TeamSheetState();
}

class _TeamSheetState extends State<_TeamSheet> {
  int _workers = Team.defaultWorkers;
  ({String key, String label})? _model;
  Map<String, dynamic>? _catalog;
  bool _loading = true;
  TeamEstimate? _price;
  bool _pricing = false;
  int _seq = 0;
  String? _status;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    final saved = app.teamSetting;
    if (saved != null) {
      _workers = saved.workers;
      _model = (key: saved.key, label: saved.label);
    }
    _load(app);
  }

  Future<void> _load(AppController app) async {
    final catalog = await app.ensureMentionCatalog();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
      _model ??=
          Team.defaultWorker(catalog, app.teamLeadOf(app.current));
    });
    await _reprice();
  }

  Future<void> _reprice() async {
    final app = AppScope.read(context);
    final conv = app.current;
    final model = _model;
    if (conv == null || model == null) {
      setState(() => _price = null);
      return;
    }
    final mode = app.teamModeOf(conv) ??
        (app.reposOf(conv).isNotEmpty ? 'repo' : 'research');
    final seq = ++_seq;
    setState(() => _pricing = true);
    final est = await app.teamEstimate(conv,
        workers: _workers, model: model.key, mode: mode);
    if (!mounted || seq != _seq) return;
    setState(() {
      _pricing = false;
      _price = est;
    });
  }

  Future<void> _change() async {
    final picked = await showNymSheet<Map<String, dynamic>>(
      context,
      (_) => _TeamModelChoice(catalog: _catalog, current: _model?.key),
    );
    if (picked == null || !mounted) return;
    final key = picked['key'] as String;
    setState(() {
      _model = (key: key, label: (picked['label'] as String?) ?? key);
      _status = null;
    });
    await _reprice();
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final conv = app.current;
    final model = _model;
    if (conv == null) return;
    if (model == null) {
      setState(() => _status = t('Pick a model for the workers first.'));
      return;
    }
    final team = Team.stored(_workers, model.key, model.label);
    await app.setTeam(conv, team);
    if (!mounted) return;
    Navigator.pop(
        context,
        t('Team mode is on for this chat: {n} workers on {model}.',
            {'n': team['workers'], 'model': model.label}));
  }

  Future<void> _off() async {
    final app = AppScope.read(context);
    final conv = app.current;
    if (conv == null) return;
    await app.setTeam(conv, null);
    if (!mounted) return;
    Navigator.pop(context, t('Team mode is off for this chat.'));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final conv = app.current;
    final lead = app.teamLeadOf(conv);
    final price = _price;
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Team mode'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(t('A lead model splits the task among workers that run at the same time, then checks and combines what they bring back.'),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              lead != null
                  ? t('Led by {model}, the model pinned to this chat.', {
                      'model': (lead['label'] as String?) ?? '${lead['key']}'
                    })
                  : Team.needsPro(),
              key: const ValueKey('team-lead'),
              style: hint,
            ),
            const SizedBox(height: 14),
            Text(t('Number of workers'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (var n = Team.minWorkers; n <= Team.maxWorkers; n++)
                  ChoiceChip(
                    key: ValueKey('team-workers-$n'),
                    label: Text('$n'),
                    selected: _workers == n,
                    onSelected: (_) {
                      if (_workers == n) return;
                      setState(() => _workers = n);
                      _reprice();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(t('Worker model'), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _model?.label ?? t('Loading the models…'),
                    key: const ValueKey('team-model'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('team-change'),
                  onPressed: _loading ? null : _change,
                  child: Text(t('Change')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_model != null)
              Text(
                _pricing
                    ? t('Working out the price…')
                    : price == null
                        ? ''
                        : price.error ?? Team.priceLine(price),
                key: const ValueKey('team-price'),
                style: TextStyle(
                  fontSize: 14,
                  color: !_pricing && price?.error != null
                      ? NymbotColors.danger
                      : null,
                ),
              ),
            if (app.teamLeadTools(conv)) ...[
              const SizedBox(height: 8),
              Text(
                t('The lead can use this chat\'s connectors and server runs, and the workers cannot. Each call the lead wants waits for you to allow it.'),
                key: const ValueKey('team-lead-tools'),
                style: hint,
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!,
                  style: const TextStyle(fontSize: 12, color: NymbotColors.danger)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('team-save'),
              onPressed: _save,
              child: Text(t('Save')),
            ),
            if (app.teamSetting != null) ...[
              const SizedBox(height: 6),
              TextButton(
                key: const ValueKey('team-off'),
                onPressed: _off,
                child: Text(t('Turn off')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TeamModelChoice extends StatelessWidget {
  const _TeamModelChoice({required this.catalog, required this.current});

  final Map<String, dynamic>? catalog;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.95,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('Worker model'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Expanded(
              child: ModelList(
                catalog: catalog,
                loading: false,
                chatOnly: true,
                filters: ModelPicker.chatFilters,
                selectedKeys: {if (current != null) current!},
                scrollController: controller,
                onPick: (m, _) => Navigator.pop(context, m),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
