import 'package:flutter/material.dart';

import '../services/ask.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class AskCard extends StatefulWidget {
  const AskCard({super.key, required this.ask, this.onAnswer});

  final Map<String, dynamic> ask;
  final void Function(Map<String, dynamic> raw)? onAnswer;

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  final List<Set<int>> _picked = [];
  final List<bool> _other = [];
  final List<TextEditingController> _text = [];

  List<Map<String, dynamic>> get _questions => Ask.questionsOf(widget.ask['questions']);

  @override
  void initState() {
    super.initState();
    _seed();
  }

  @override
  void didUpdateWidget(covariant AskCard old) {
    super.didUpdateWidget(old);
    if (old.ask['id'] != widget.ask['id']) {
      for (final c in _text) {
        c.dispose();
      }
      _picked.clear();
      _other.clear();
      _text.clear();
      _seed();
    }
  }

  void _seed() {
    final given = widget.ask['answers'] is List
        ? Ask.questionsOf(widget.ask['answers'])
        : (widget.ask['draft'] is List ? Ask.questionsOf(widget.ask['draft']) : const <Map<String, dynamic>>[]);
    for (var i = 0; i < _questions.length; i++) {
      final g = i < given.length ? given[i] : null;
      final sel = g != null && g['selected'] is List ? (g['selected'] as List).whereType<int>().toSet() : <int>{};
      final other = g != null ? '${g['other'] ?? ''}' : '';
      _picked.add(sel);
      _other.add(other.isNotEmpty);
      _text.add(TextEditingController(text: other));
    }
  }

  @override
  void dispose() {
    for (final c in _text) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _read() => {
        'answers': [
          for (var i = 0; i < _questions.length; i++)
            {
              'selected': (_picked[i].toList()..sort()),
              'other': _other[i] ? _text[i].text : '',
            }
        ]
      };

  void _pick(int q, int o, bool multi) {
    setState(() {
      if (multi) {
        if (!_picked[q].remove(o)) _picked[q].add(o);
      } else {
        _picked[q]
          ..clear()
          ..add(o);
        _other[q] = false;
      }
    });
  }

  void _pickOther(int q, bool multi) {
    setState(() {
      if (multi) {
        _other[q] = !_other[q];
      } else {
        _picked[q].clear();
        _other[q] = true;
      }
    });
  }

  Widget _option(BuildContext context, {required bool multi, required bool on, required bool enabled,
      required String label, String description = '', required VoidCallback onTap, Key? key}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: on ? theme.colorScheme.primary.withValues(alpha: 0.1) : Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: on ? theme.colorScheme.primary : theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: multi
                        ? Checkbox(value: on, onChanged: enabled ? (_) => onTap() : null,
                            visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap)
                        : Padding(
                            padding: const EdgeInsets.all(2),
                            child: NymGlyph(on ? 'dot' : 'circle',
                                size: 16, filled: on, color: on ? theme.colorScheme.primary : theme.hintColor),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      checked: on,
                      inMutuallyExclusiveGroup: !multi,
                      button: true,
                      enabled: enabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: const TextStyle(fontSize: 14)),
                          if (description.isNotEmpty)
                            Text(description, style: TextStyle(fontSize: 12, color: theme.hintColor)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.ask;
    final state = Ask.stateOf(a) ?? 'waiting';
    final open = state == 'waiting';
    final qs = _questions;
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    final exp = a['expiresAt'];
    final hours = exp is num
        ? ((exp - DateTime.now().millisecondsSinceEpoch) / 3600000).ceil().clamp(0, 24)
        : 24;
    final status = switch (state) {
      'answered' => t('Answered. Nymbot carried on from here.'),
      'skipped' => t('Skipped. Nymbot carried on with its own judgment.'),
      'expired' => t('No answer came within 24 hours, so this task stopped. Ask again to start it fresh.'),
      'sending' => t('Sending your answer…'),
      _ => '${a['error'] ?? ''}',
    };
    return Semantics(
      container: true,
      label: t('Nymbot has a question'),
      child: Container(
        key: ValueKey('ask-card-$state'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: Border.all(color: open ? theme.colorScheme.secondary : theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Opacity(
          opacity: state == 'expired' ? 0.75 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    qs.length > 1 ? t('Nymbot has {n} questions', {'n': qs.length}) : t('Nymbot has a question'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (open)
                    Text(
                      hours <= 1
                          ? t('Waiting for your answer · expires within the hour')
                          : t('Waiting for your answer · expires in {n} hours', {'n': hours}),
                      style: hint,
                    ),
                ],
              ),
              for (var i = 0; i < qs.length; i++) ...[
                const SizedBox(height: 8),
                if ('${qs[i]['header'] ?? ''}'.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.dividerColor),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('${qs[i]['header']}', style: hint),
                    ),
                  ),
                Semantics(header: true, child: Text('${qs[i]['question']}', style: const TextStyle(fontSize: 14))),
                if (qs[i]['multi'] == true) Text(t('Pick any that apply.'), style: hint),
                for (var j = 0; j < Ask.optionsOf(qs[i]).length; j++)
                  _option(context,
                      key: ValueKey('ask-option-$i-$j'),
                      multi: qs[i]['multi'] == true,
                      on: _picked[i].contains(j),
                      enabled: open,
                      label: '${Ask.optionsOf(qs[i])[j]['label']}',
                      description: '${Ask.optionsOf(qs[i])[j]['description'] ?? ''}',
                      onTap: () => _pick(i, j, qs[i]['multi'] == true)),
                _option(context,
                    key: ValueKey('ask-other-$i'),
                    multi: qs[i]['multi'] == true,
                    on: _other[i],
                    enabled: open,
                    label: t('Other'),
                    onTap: () => _pickOther(i, qs[i]['multi'] == true)),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextField(
                    key: ValueKey('ask-other-text-$i'),
                    controller: _text[i],
                    enabled: open,
                    maxLength: AskLimits.other,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t('Write your own answer'),
                      counterText: '',
                      labelText: null,
                    ),
                    onChanged: (v) {
                      if (v.trim().isNotEmpty && !_other[i]) {
                        setState(() {
                          if (qs[i]['multi'] != true) _picked[i].clear();
                          _other[i] = true;
                        });
                      }
                    },
                  ),
                ),
              ],
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Semantics(liveRegion: true, child: Text(status, key: const ValueKey('ask-status'), style: hint)),
                ),
              if (open)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton(
                        key: const ValueKey('ask-submit'),
                        onPressed: widget.onAnswer == null ? null : () => widget.onAnswer!(_read()),
                        child: Text(t('Submit')),
                      ),
                      TextButton(
                        key: const ValueKey('ask-skip'),
                        onPressed: widget.onAnswer == null ? null : () => widget.onAnswer!({'skipped': true}),
                        child: Text(t('Skip')),
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
