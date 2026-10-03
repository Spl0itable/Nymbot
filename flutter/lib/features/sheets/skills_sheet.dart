import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/skills.dart';
import '../i18n/i18n.dart';
import 'sheet.dart';

Future<String?> showSkillsSheet(BuildContext context, {String filter = ''}) =>
    showNymSheet<String>(context, (_) => SkillsSheet(filter: filter));

class SkillsSheet extends StatefulWidget {
  const SkillsSheet({super.key, this.filter = ''});

  final String filter;

  @override
  State<SkillsSheet> createState() => _SkillsSheetState();
}

class _SkillsSheetState extends State<SkillsSheet> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _body = TextEditingController();
  String? _editingId;
  String? _status;
  bool _warn = false;
  late String _term = widget.filter.trim();

  @override
  void initState() {
    super.initState();
    _search.text = _term;
  }

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _editingId = null;
        _name.clear();
        _description.clear();
        _body.clear();
      });

  void _edit(Skill s) => setState(() {
        _editingId = s.id;
        _name.text = s.name;
        _description.text = s.description;
        _body.text = s.body;
        _status = null;
      });

  Future<void> _save() async {
    final app = AppScope.of(context);
    final got = await app.saveSkill({
      'id': _editingId ?? '',
      'name': _name.text,
      'description': _description.text,
      'body': _body.text,
    });
    if (!mounted) return;
    if (got.error != null) {
      setState(() {
        _status = Skills.errorText(got.error!);
        _warn = true;
      });
      return;
    }
    _reset();
    setState(() {
      _status = t('Saved. Run it with /{slug}.', {'slug': Skills.slugOf(got.skill!)});
      _warn = false;
    });
  }

  Future<void> _duplicate(Skill s) async {
    final app = AppScope.of(context);
    final got = await app.duplicateSkill(s.id);
    if (!mounted || got.skill == null) return;
    _edit(got.skill!);
    setState(() => _status = t('Copied. Edit it below.'));
  }

  Future<void> _delete(Skill s) async {
    final app = AppScope.of(context);
    final go = await showNymDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Delete {name}?', {'name': Skills.label(s)})),
        content: Text(t('The skill is deleted from this device and from your other devices. Chats that use it stop using it.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('Cancel'))),
          FilledButton(
            key: const ValueKey('skill-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (go != true) return;
    await app.deleteSkill(s.id);
    if (_editingId == s.id) _reset();
  }

  Widget _row(BuildContext context, Skill s, List<Skill> own, String? attached, bool filtered) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final builtin = Skills.isBuiltin(s.id);
    final name = Skills.label(s);
    final about = Skills.describe(s);
    final on = attached == s.id;
    final at = own.indexWhere((x) => x.id == s.id);
    final hint = TextStyle(fontSize: 11, color: theme.hintColor);
    Widget act(String label, String key, VoidCallback? onTap, {String? semantics}) => TextButton(
          key: ValueKey('$key-${s.id}'),
          style: TextButton.styleFrom(minimumSize: const Size(44, 36), visualDensity: VisualDensity.compact),
          onPressed: onTap,
          child: Semantics(label: semantics, excludeSemantics: semantics != null, child: Text(label)),
        );
    return Container(
      key: ValueKey('skill-row-${s.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
      decoration: BoxDecoration(
        color: on ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
        border: Border.all(color: on ? theme.colorScheme.primary : theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name, style: const TextStyle(fontSize: 14)),
              if (builtin) Text(t('Built-in'), style: hint),
              if (on) Text(t('On in this chat'), style: TextStyle(fontSize: 11, color: theme.colorScheme.primary)),
            ],
          ),
          Text('/${Skills.slugOf(s)}',
              style: TextStyle(fontSize: 12, fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, color: theme.colorScheme.primary)),
          if (about.isNotEmpty) Text(about, style: hint),
          Wrap(
            children: [
              act(t('Run'), 'skill-run', () => Navigator.pop(context, '/${Skills.slugOf(s)} '),
                  semantics: t('Run {name} on the next message', {'name': name})),
              if (app.current != null && app.current!.support != true)
                act(on ? t('Detach') : t('Attach'), 'skill-attach', () => app.attachSkill(s.id),
                    semantics: on
                        ? t('Stop using {name} in this chat', {'name': name})
                        : t('Use {name} on every message in this chat', {'name': name})),
              act(t('New chat'), 'skill-new-chat', () async {
                await app.newChatWithSkill(s.id);
                if (context.mounted) Navigator.pop(context);
              }, semantics: t('Start a new chat with {name}', {'name': name})),
              act(t('Duplicate'), 'skill-duplicate', () => _duplicate(s), semantics: t('Duplicate {name}', {'name': name})),
              if (!builtin) ...[
                act(t('Edit'), 'skill-edit', () => _edit(s), semantics: t('Edit {name}', {'name': name})),
                act(t('Move up'), 'skill-up', at <= 0 || filtered ? null : () => app.moveSkill(s.id, -1),
                    semantics: t('Move {name} up', {'name': name})),
                act(t('Move down'), 'skill-down', at >= own.length - 1 || filtered ? null : () => app.moveSkill(s.id, 1),
                    semantics: t('Move {name} down', {'name': name})),
                act(t('Delete'), 'skill-delete', () => _delete(s), semantics: t('Delete {name}', {'name': name})),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final all = app.allSkills;
    final shown = _term.trim().isEmpty ? all : Skills.match(_term, all, all.length);
    final count = _body.text.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Skills'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              t("Saved instructions. Run one on a message by typing / and its name, attach one to a chat so it applies to every message, or start a new chat with it. A skill's text is sent with the message, so it counts toward what the message costs."),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('skill-search'),
              controller: _search,
              decoration: InputDecoration(hintText: t('Search skills')),
              onChanged: (v) => setState(() => _term = v),
            ),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t('Nothing matches that.'), style: TextStyle(color: theme.hintColor)),
              ),
            for (final s in shown) _row(context, s, app.skills, app.current?.skillId, _term.trim().isNotEmpty),
            const SizedBox(height: 8),
            Text(_editingId == null ? t('New skill') : t('Edit skill'), style: theme.textTheme.titleSmall),
            TextField(
              key: const ValueKey('skill-name'),
              controller: _name,
              maxLength: Skills.nameMax,
              decoration: InputDecoration(labelText: t('Name'), counterText: ''),
            ),
            TextField(
              key: const ValueKey('skill-description'),
              controller: _description,
              maxLength: Skills.descriptionMax,
              decoration: InputDecoration(labelText: t('Short description (optional)'), counterText: ''),
            ),
            TextField(
              key: const ValueKey('skill-body'),
              controller: _body,
              minLines: 4,
              maxLines: 10,
              maxLength: Skills.bodyMax,
              scrollPadding: textAreaScrollPadding(context, 4),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t('Instructions'),
                hintText: t('What Nymbot should do when this skill runs. Markdown works.'),
                counterText: count == 0 ? '' : t('{n} of {max} characters', {'n': count, 'max': Skills.bodyMax}),
              ),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_status!,
                      key: const ValueKey('skill-status'),
                      style: TextStyle(fontSize: 12, color: _warn ? theme.colorScheme.error : theme.hintColor)),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('skill-save'),
                  onPressed: _save,
                  child: Text(_editingId == null ? t('Save skill') : t('Save changes')),
                ),
                if (_editingId != null) TextButton(onPressed: _reset, child: Text(t('Cancel'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
