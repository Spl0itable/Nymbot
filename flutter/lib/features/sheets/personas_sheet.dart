import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/workspace.dart';
import '../i18n/i18n.dart';
import '../nym_icons.dart';

Future<void> showPersonasSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PersonasSheet(),
    );

class _PersonasSheet extends StatefulWidget {
  const _PersonasSheet();

  @override
  State<_PersonasSheet> createState() => _PersonasSheetState();
}

class _PersonasSheetState extends State<_PersonasSheet> {
  final _name = TextEditingController();
  final _body = TextEditingController();
  String? _editingId;
  String? _error;
  String _icon = 'robot';

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _editingId = null;
        _error = null;
        _icon = 'robot';
        _name.clear();
        _body.clear();
      });

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final active = app.current?.personaId;

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
            Text(t('Personas'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('A persona is a standing instruction sent with the first message of a '
                  'chat. It never leaves your device except as part of that message.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            for (final p in app.personas)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                color: p.id == active
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
                    : null,
                child: ListTile(
                  dense: true,
                  leading: Icon(NymIcons.forPersona(p.icon), size: 20),
                  title: Text(p.name),
                  subtitle: Text(
                    p.instructions,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => app.setPersona(p.id == active ? null : p.id),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy_all_outlined, size: 17),
                        tooltip: t('Copy'),
                        onPressed: () => setState(() {
                          _editingId = null;
                          _icon = p.icon;
                          _name.text = '${p.name} ${t('(copy)')}';
                          _body.text = p.instructions;
                        }),
                      ),
                      if (!p.builtin)
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 17),
                          tooltip: t('Edit'),
                          onPressed: () => setState(() {
                            _editingId = p.id;
                            _icon = p.icon;
                            _name.text = p.name;
                            _body.text = p.instructions;
                          }),
                        ),
                      if (!p.builtin)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 17),
                          tooltip: t('Delete'),
                          onPressed: () => app.deletePersona(p.id),
                        ),
                    ],
                  ),
                ),
              ),
            if (active != null)
              TextButton(
                onPressed: () => app.setPersona(null),
                child: Text(t('No persona in this chat')),
              ),
            const Divider(height: 24),
            Text(
              _editingId == null ? t('New persona') : t('Edit persona'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              decoration:
                  InputDecoration(labelText: t('Name'), hintText: 'Staff engineer'),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t('Icon'),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final name in NymIcons.personaOrder)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _icon = name),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: name == _icon
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        NymIcons.forPersona(name),
                        size: 19,
                        color: name == _icon
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).hintColor,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                  labelText: t('Instructions'), hintText: 'Answer as…'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () async {
                if (_name.text.trim().isEmpty || _body.text.trim().isEmpty) {
                  setState(() => _error =
                      t('A name and some instructions are both needed.'));
                  return;
                }
                await app.savePersona(Persona(
                  id: _editingId ?? bytesToHex(randomBytes(8)),
                  name: _name.text.trim(),
                  instructions: _body.text.trim(),
                  icon: _icon,
                ));
                _reset();
              },
              child: Text(_editingId == null ? t('Save persona') : t('Save changes')),
            ),
            if (_editingId != null)
              TextButton(onPressed: _reset, child: Text(t('Cancel'))),
          ],
        ),
      ),
    );
  }
}

Future<void> showSystemPromptSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _SystemSheet(),
    );

class _SystemSheet extends StatefulWidget {
  const _SystemSheet();

  @override
  State<_SystemSheet> createState() => _SystemSheetState();
}

class _SystemSheetState extends State<_SystemSheet> {
  late final TextEditingController _body =
      TextEditingController(text: AppScope.read(context).current?.systemPrompt ?? '');

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('Custom instructions'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            t('Sent once, with the first message of this chat, on top of any persona.'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              hintText: t('Always answer in British English, and show the diff before '
                  'the explanation.'),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
              await app.setSystemPrompt(_body.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(t('Save')),
          ),
          TextButton(
            onPressed: () async {
              await app.setSystemPrompt('');
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(t('Clear')),
          ),
        ],
      ),
    );
  }
}
