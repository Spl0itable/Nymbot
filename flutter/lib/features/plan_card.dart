import 'package:flutter/material.dart';

import '../services/plan.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class PlanCard extends StatefulWidget {
  const PlanCard({super.key, required this.plan, this.onDecide, this.onRevise});

  final Map<String, dynamic> plan;
  final void Function(Map<String, dynamic> raw)? onDecide;
  final void Function(String text)? onRevise;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  String _mode = '';
  final List<TextEditingController> _steps = [];
  final TextEditingController _note = TextEditingController();
  String _error = '';

  @override
  void didUpdateWidget(covariant PlanCard old) {
    super.didUpdateWidget(old);
    if (old.plan['id'] != widget.plan['id']) _close();
  }

  @override
  void dispose() {
    for (final c in _steps) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  void _close() {
    for (final c in _steps) {
      c.dispose();
    }
    _steps.clear();
    _note.clear();
    _error = '';
    _mode = '';
  }

  void _open(String mode) {
    setState(() {
      _close();
      _mode = mode;
      if (mode == 'edit') {
        for (final s in Plan.itemsOf(widget.plan['items'])) {
          _steps.add(TextEditingController(text: s));
        }
      }
    });
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _steps.length) return;
    setState(() {
      final c = _steps.removeAt(i);
      _steps.insert(j, c);
    });
  }

  void _remove(int i) {
    if (_steps.length <= 1) return;
    setState(() => _steps.removeAt(i).dispose());
  }

  void _add() {
    if (_steps.length >= PlanLimits.items) return;
    setState(() => _steps.add(TextEditingController()));
  }

  void _approveEdits() {
    final steps = [
      for (final c in _steps)
        if (c.text.trim().isNotEmpty) c.text.trim()
    ];
    if (steps.isEmpty) {
      setState(() => _error = t('Keep at least one step.'));
      return;
    }
    widget.onDecide?.call({
      'decision': 'approve',
      'edits': {'items': steps, 'note': _note.text},
    });
    setState(_close);
  }

  void _send(Map<String, dynamic> raw) {
    widget.onDecide?.call(raw);
    setState(_close);
  }

  Widget _section(String title, List<Widget> children, TextStyle hint) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text(title, style: hint.copyWith(fontWeight: FontWeight.w600))),
            ...children,
          ],
        ),
      );

  Widget _editor(BuildContext context, TextStyle hint) {
    return Column(
      key: const ValueKey('plan-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                SizedBox(width: 22, child: Text('${i + 1}.', style: hint)),
                Expanded(
                  child: TextField(
                    key: ValueKey('plan-edit-$i'),
                    controller: _steps[i],
                    autofocus: i == 0,
                    maxLength: PlanLimits.item,
                    decoration: InputDecoration(isDense: true, counterText: '', labelText: t('Step {n}', {'n': i + 1})),
                  ),
                ),
                IconButton(
                  key: ValueKey('plan-up-$i'),
                  tooltip: t('Move step {n} up', {'n': i + 1}),
                  onPressed: i == 0 ? null : () => _move(i, -1),
                  icon: const NymGlyph('up', size: 16),
                ),
                IconButton(
                  key: ValueKey('plan-down-$i'),
                  tooltip: t('Move step {n} down', {'n': i + 1}),
                  onPressed: i >= _steps.length - 1 ? null : () => _move(i, 1),
                  icon: const NymGlyph('down', size: 16),
                ),
                IconButton(
                  key: ValueKey('plan-remove-$i'),
                  tooltip: t('Remove step {n}', {'n': i + 1}),
                  onPressed: _steps.length <= 1 ? null : () => _remove(i),
                  icon: const NymGlyph('close', size: 16),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('plan-add'),
            onPressed: _steps.length >= PlanLimits.items ? null : _add,
            icon: const NymGlyph('plus', size: 16),
            label: Text(t('Add a step')),
          ),
        ),
        TextField(
          key: const ValueKey('plan-note'),
          controller: _note,
          minLines: 1,
          maxLines: 4,
          maxLength: PlanLimits.note,
          decoration: InputDecoration(isDense: true, counterText: '', labelText: t('Note for Nymbot (optional)')),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_error, style: hint.copyWith(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                key: const ValueKey('plan-approve-edits'),
                onPressed: widget.onDecide == null ? null : _approveEdits,
                child: Text(t('Approve with edits')),
              ),
              TextButton(
                key: const ValueKey('plan-cancel'),
                onPressed: () => setState(_close),
                child: Text(t('Cancel')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reason(String mode, TextStyle hint) {
    final reject = mode == 'reject';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            key: ValueKey(reject ? 'plan-reason' : 'plan-revise-text'),
            controller: _note,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            maxLength: PlanLimits.note,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              labelText: reject ? t('Why? (optional)') : t('What should change in the plan?'),
              hintText: reject ? t('Tell Nymbot what to change') : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                key: ValueKey(reject ? 'plan-reject-send' : 'plan-revise-send'),
                onPressed: reject
                    ? (widget.onDecide == null ? null : () => _send({'decision': 'reject', 'edits': {'note': _note.text}}))
                    : (widget.onRevise == null
                        ? null
                        : () {
                            final text = _note.text;
                            if (text.trim().isEmpty) {
                              setState(() => _error = t('Say what should change.'));
                              return;
                            }
                            widget.onRevise!(text);
                            setState(_close);
                          }),
                child: Text(reject ? t('Reject the plan') : t('Revise plan')),
              ),
              TextButton(
                key: const ValueKey('plan-cancel'),
                onPressed: () => setState(_close),
                child: Text(t('Cancel')),
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty) Text(_error, style: hint),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.plan;
    final state = Plan.stateOf(p) ?? 'waiting';
    final live = state == 'waiting' || state == 'sending';
    final open = state == 'waiting';
    final mode = live ? _mode : '';
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    final hours = Plan.hoursLeft(p).clamp(0, 24);
    final shown = Plan.itemsOf(p['approvedItems'] ?? p['items']);
    final groups = Plan.grouped(p['changes']);
    final status = Plan.statusText(p, state);
    final said = '${p['note'] ?? ''}';
    return Semantics(
      container: true,
      label: t('Nymbot\'s plan'),
      child: Container(
        key: ValueKey('plan-card-$state'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: Border.all(color: live ? theme.colorScheme.primary : theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Opacity(
          opacity: state == 'expired' || state == 'rejected' ? 0.8 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(t('Nymbot\'s plan'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  if (open)
                    Text(
                      hours <= 1
                          ? t('Waiting for your approval · expires within the hour')
                          : t('Waiting for your approval · expires in {n} hours', {'n': hours}),
                      key: const ValueKey('plan-expiry'),
                      style: hint,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${p['summary'] ?? ''}', key: const ValueKey('plan-summary'), style: const TextStyle(fontSize: 14)),
              if (mode == 'edit')
                _editor(context, hint)
              else
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < shown.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('${i + 1}. ${shown[i]}', key: ValueKey('plan-item-$i'), style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                  ),
                ),
              if (groups.isNotEmpty && mode != 'edit')
                _section(t('What changes where'), [
                  for (final g in groups)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(g.target, key: ValueKey('plan-target-${g.target}'), style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                          for (final w in g.what)
                            Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Text('· $w', style: hint),
                            ),
                        ],
                      ),
                    ),
                ], hint),
              if (said.isNotEmpty && !live)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    state == 'rejected' ? t('Your reason: {text}', {'text': said}) : t('Your note: {text}', {'text': said}),
                    style: hint,
                  ),
                ),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Semantics(liveRegion: true, child: Text(status, key: const ValueKey('plan-status'), style: hint)),
                ),
              if (live && (mode == 'reject' || mode == 'revise')) _reason(mode, hint),
              if (live && mode.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton(
                        key: const ValueKey('plan-approve'),
                        onPressed: !open || widget.onDecide == null ? null : () => _send({'decision': 'approve'}),
                        child: Text(t('Approve')),
                      ),
                      OutlinedButton(
                        key: const ValueKey('plan-edit'),
                        onPressed: !open || widget.onDecide == null ? null : () => _open('edit'),
                        child: Text(t('Edit')),
                      ),
                      TextButton(
                        key: const ValueKey('plan-reject'),
                        onPressed: !open || widget.onDecide == null ? null : () => _open('reject'),
                        child: Text(t('Reject')),
                      ),
                      TextButton(
                        key: const ValueKey('plan-revise'),
                        onPressed: !open || widget.onRevise == null ? null : () => _open('revise'),
                        child: Text(t('Revise plan')),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
