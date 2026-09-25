import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import 'command_sheet.dart';
import 'i18n/i18n.dart';
import 'sheets/sheet.dart';
import 'nym_glyph.dart';

typedef PaletteChoice = ({String kind, String value});

class PaletteRow {
  const PaletteRow(this.group, this.name, this.hint, this.choice,
      {this.mono = false});

  final String group;
  final String name;
  final String hint;
  final PaletteChoice choice;
  final bool mono;
}

bool get _apple =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

String shortcutLabel(String keys) => '${_apple ? 'Cmd' : 'Ctrl'}+$keys';

List<(String, String, String)> paletteActions() => [
      ('new', t('New chat'), shortcutLabel('N')),
      ('search', t('Search every chat'), shortcutLabel('Shift+F')),
      ('models', t('Pick a model'), shortcutLabel('Shift+M')),
      ('repos', t('Repositories'), shortcutLabel('Shift+G')),
      ('personas', t('Personas'), ''),
      ('system', t('Custom instructions'), ''),
      ('prompts', t('Prompt library'), shortcutLabel('Shift+P')),
      ('saved', t('Saved messages'), ''),
      ('settings', t('Settings'), ''),
      ('memory', t('Memory'), ''),
      ('shortcuts', t('Keyboard shortcuts'), ''),
      ('credits', t('Buy credits'), ''),
      ('anon', t('Anonymous chat'), ''),
      ('identity', t('Identity'), ''),
      ('stats', t('Chat statistics'), ''),
      ('export-md', t('Export this chat as Markdown'), ''),
      ('tags', t('Tags and folder'), ''),
      ('clear', t('Clear this chat'), ''),
    ];

List<PaletteRow> paletteRows(BuildContext context, String term) {
  final app = AppScope.read(context);
  final needle = term.toLowerCase().trim();
  final rows = <PaletteRow>[];
  for (final a in paletteActions()) {
    if (needle.isEmpty || a.$2.toLowerCase().contains(needle)) {
      rows.add(PaletteRow(t('Actions'), a.$2, a.$3, (kind: 'action', value: a.$1)));
    }
  }
  for (final c in BotCommands.match(needle, limit: needle.isEmpty ? 6 : 8)) {
    rows.add(PaletteRow(t('Commands'), '?${c.name}', c.hint(),
        (kind: 'command', value: c.args.isEmpty ? c.name : '${c.name} '),
        mono: true));
  }
  if (needle.isNotEmpty) {
    for (final conv in app.conversations) {
      if (!conv.title.toLowerCase().contains(needle)) continue;
      rows.add(PaletteRow(
          t('Chats'),
          conv.title.isEmpty ? t('New chat') : conv.title,
          conv.archived ? t('archived') : '',
          (kind: 'chat', value: conv.id)));
      if (rows.length > 40) break;
    }
    for (final hit in app.store.searchAll(needle).take(8)) {
      final message = hit.message;
      if (message == null) continue;
      rows.add(PaletteRow(
          t('Messages'),
          hit.excerpt.length > 70 ? hit.excerpt.substring(0, 70) : hit.excerpt,
          hit.conv.title.isEmpty ? t('New chat') : hit.conv.title,
          (kind: 'message', value: '${hit.conv.id} ${message.id}')));
    }
  }
  return rows.take(40).toList();
}

Future<PaletteChoice?> showCommandPalette(BuildContext context) =>
    showNymSheet<PaletteChoice>(context, (_) => const _Palette());

class _Palette extends StatefulWidget {
  const _Palette();

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _field = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _key);
  String _term = '';
  int _at = 0;
  List<PaletteRow> _rows = const [];

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _rows.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _at = (_at + 1) % _rows.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _at = (_at - 1 + _rows.length) % _rows.length);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _run(_at);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _run(int index) {
    if (index < 0 || index >= _rows.length) return;
    Navigator.pop(context, _rows[index].choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _rows = paletteRows(context, _term);
    if (_at >= _rows.length) _at = 0;
    final children = <Widget>[];
    String? group;
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row.group != group) {
        group = row.group;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(row.group.toUpperCase(),
              style: TextStyle(
                  fontSize: 10, letterSpacing: 1, color: theme.hintColor)),
        ));
      }
      children.add(ListTile(
        dense: true,
        selected: i == _at,
        title: Text(
          row.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: row.mono
              ? const TextStyle(
                  fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback)
              : null,
        ),
        trailing: row.hint.isEmpty
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(row.hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: theme.hintColor)),
              ),
        onTap: () => _run(i),
      ));
    }
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _field,
              focusNode: _focus,
              autofocus: true,
              decoration: InputDecoration(
                hintText: t('Type a command or search'),
                prefixIcon: const NymGlyph('search', size: 18),
              ),
              onChanged: (v) => setState(() {
                _term = v;
                _at = 0;
              }),
              onSubmitted: (_) => _run(_at),
            ),
          ),
          Flexible(
            child: _rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(t('Nothing matches that.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.hintColor)),
                  )
                : ListView(shrinkWrap: true, children: children),
          ),
        ],
      ),
    );
  }
}
