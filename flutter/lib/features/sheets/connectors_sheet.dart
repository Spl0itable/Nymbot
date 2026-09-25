import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../core/theme/theme.dart';
import '../../models/connector.dart';
import '../../services/chat_engine.dart';
import '../../services/connectors.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';
import 'sheet.dart';
import '../nym_glyph.dart';

Future<void> showConnectorsSheet(BuildContext context) => showNymSheet<void>(
      context,
      (_) => const ConnectorsSheet(),
    );

class ConnectorsSheet extends StatefulWidget {
  const ConnectorsSheet({super.key});

  @override
  State<ConnectorsSheet> createState() => _ConnectorsSheetState();
}

class _ConnectorsSheetState extends State<ConnectorsSheet> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _headerName = TextEditingController();
  final _headerValue = TextEditingController();
  String _auth = 'none';
  String? _editingId;
  String? _status;
  bool _statusOk = false;
  bool _testing = false;
  List<ConnectorTool>? _tools;
  bool _autoAll = false;
  Set<String> _autoTools = {};

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _editingId = null;
      _auth = 'none';
      _status = null;
      _tools = null;
      _autoAll = false;
      _autoTools = {};
      _name.clear();
      _url.clear();
      _token.clear();
      _headerName.clear();
      _headerValue.clear();
    });
  }

  void _edit(McpConnector c) {
    setState(() {
      _editingId = c.id;
      _auth = c.auth;
      _status = null;
      _name.text = c.name;
      _url.text = c.url;
      _token.text = c.token;
      _headerName.text = c.headerName;
      _headerValue.text = c.headerValue;
      _tools = c.tools?.map((tool) => ConnectorTool.fromJson(tool.toJson())).toList();
      _autoAll = c.allowAll;
      _autoTools = {...c.allowed};
    });
  }

  McpConnector _fromForm() => McpConnector(
        id: _editingId ?? bytesToHex(randomBytes(8)),
        name: _name.text.trim(),
        url: _url.text.trim(),
        auth: _auth,
        token: _auth == 'bearer' ? _token.text.trim() : '',
        headerName: _auth == 'header' ? _headerName.text.trim() : '',
        headerValue: _auth == 'header' ? _headerValue.text.trim() : '',
        tools: _tools,
        allowAll: _autoAll,
        allowed: _autoAll ? [] : _autoTools.toList(),
      );

  void _say(String text, {bool ok = false}) => setState(() {
        _status = text;
        _statusOk = ok;
      });

  Future<void> _test(AppController app) async {
    final c = _fromForm();
    final problem = Connectors.formProblem(c);
    if (problem != null) return _say(problem);
    setState(() {
      _testing = true;
      _status = t('Connecting…');
      _statusOk = false;
    });
    try {
      final tools = await app.probeConnector(c);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _tools = tools;
      });
      _say(t('Connected to {name}: {n} tools.', {'name': c.name, 'n': tools.length}), ok: true);
    } on ChatFailure catch (e) {
      if (!mounted) return;
      setState(() => _testing = false);
      _say(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _testing = false);
      _say(t('The connector could not be reached.'));
    }
  }

  Future<void> _save(AppController app) async {
    final c = _fromForm();
    final problem = Connectors.formProblem(c);
    if (problem != null) return _say(problem);
    await app.saveConnector(c, useHere: _editingId == null);
    _reset();
    _say(t('Saved. Connectors work with a Pro model pinned.'), ok: true);
  }

  Widget _authChoice(String value, String label) => ChoiceChip(
        label: Text(label),
        selected: _auth == value,
        onSelected: (_) => setState(() => _auth = value),
      );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final scoped = app.current?.connectorIds ?? const <String>[];

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
            Text(t('Connectors'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Connect outside tools over MCP and tick the ones this chat can use, '
                  'up to three at a time. Pro replies can call their tools; every tool '
                  'asks you before it runs unless you choose to always allow it, and a '
                  'tool the server marks as able to delete always asks. The URL and '
                  'any token or header are sent to the Nymbot worker with the messages '
                  'that use them and never stored server-side or published to relays. '
                  'With sync on they travel to your other devices sealed to your own key.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (app.connectors.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t('No connectors yet. Add one below and it becomes available to every chat.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final c in app.connectors)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  key: ValueKey('connector-${c.id}'),
                  dense: true,
                  leading: Checkbox(
                    value: scoped.contains(c.id),
                    onChanged: !c.usable && !scoped.contains(c.id)
                        ? null
                        : (_) async {
                            final ok = await app.toggleConnectorHere(c.id);
                            if (!ok) {
                              _say(t('At most {n} connectors can be on in one chat.',
                                  {'n': McpConnector.maxPerChat}));
                            }
                          },
                  ),
                  title: Text(c.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      McpConnector.publicUrl(c.url),
                      if (c.auth == 'bearer') t('bearer token'),
                      if (c.auth == 'header') t('header {name}', {'name': c.headerName}),
                      if (c.tools != null && c.tools!.isNotEmpty)
                        t('{n} of {total} tools', {
                          'n': c.tools!.where((tool) => tool.enabled).length,
                          'total': c.tools!.length
                        }),
                      if (!c.usable) t('Its secret is on another device. Edit it to add it here.'),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const NymGlyph('pencil', size: 18),
                        tooltip: t('Edit'),
                        onPressed: () => _edit(c),
                      ),
                      IconButton(
                        icon: const NymGlyph('close', size: 18),
                        tooltip: t('Remove'),
                        onPressed: () => app.deleteConnector(c.id),
                      ),
                    ],
                  ),
                ),
              ),
            if (app.connectors.isNotEmpty)
              Row(
                children: [
                  TextButton(
                    onPressed: () => app.setConnectorsHere(const []),
                    child: Text(t('Use none here')),
                  ),
                  TextButton(
                    onPressed: () => app.setConnectorsHere(
                        app.connectors.where((c) => c.usable).map((c) => c.id).toList()),
                    child: Text(t('Use all here')),
                  ),
                ],
              ),
            const Divider(height: 24),
            Text(
              _editingId == null ? t('Add a connector') : t('Edit connector'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('connectorName'),
              controller: _name,
              decoration: InputDecoration(labelText: t('Name'), hintText: 'Docs'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('connectorUrl'),
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                  labelText: t('Server URL'), hintText: 'https://example.com/mcp'),
            ),
            const SizedBox(height: 10),
            Text(t('Authentication'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                _authChoice('none', t('None')),
                _authChoice('bearer', t('Bearer token')),
                _authChoice('header', t('Custom header')),
              ],
            ),
            if (_auth == 'bearer') ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('connectorToken'),
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(labelText: t('Token')),
              ),
            ],
            if (_auth == 'header') ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('connectorHeaderName'),
                controller: _headerName,
                autocorrect: false,
                decoration:
                    InputDecoration(labelText: t('Header name'), hintText: 'X-Api-Key'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('connectorHeaderValue'),
                controller: _headerValue,
                obscureText: true,
                decoration: InputDecoration(labelText: t('Header value')),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: _testing
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const NymGlyph('connectors', size: 18),
              label: Text(t('Test connection')),
              onPressed: _testing ? null : () => _test(app),
            ),
            if (_tools != null) ...[
              const SizedBox(height: 8),
              if (_tools!.isEmpty)
                Text(t('This server offers no tools.'),
                    style: TextStyle(fontSize: 12, color: theme.hintColor))
              else ...[
                Text(
                  t('Untick a tool to keep it from Nymbot. Every tool asks you before it runs unless you let it run without asking. Tools the server marks as able to delete always ask.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
                SwitchListTile(
                  key: const ValueKey('auto-all'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _autoAll,
                  onChanged: (on) => setState(() => _autoAll = on),
                  title: Text(t('Always allow all tools'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                for (final tool in _tools!)
                  CheckboxListTile(
                    key: ValueKey('tool-${tool.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: tool.enabled,
                    onChanged: (on) => setState(() => tool.enabled = on == true),
                    title: Text(tool.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      [
                        if (tool.destructive)
                          t('always asks · the server says it can delete')
                        else if (tool.readOnly)
                          t('the server says it only reads'),
                        if (tool.description.isNotEmpty) tool.description,
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: 11,
                          color: tool.destructive ? NymbotColors.lightning : theme.hintColor),
                    ),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(t('Always allow'),
                            style: TextStyle(fontSize: 11, color: theme.hintColor)),
                        Checkbox(
                          key: ValueKey('auto-${tool.name}'),
                          value: !tool.destructive &&
                              (_autoAll || _autoTools.contains(tool.name)),
                          onChanged: tool.destructive || _autoAll
                              ? null
                              : (on) => setState(() => on == true
                                  ? _autoTools.add(tool.name)
                                  : _autoTools.remove(tool.name)),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _status!,
                  style: TextStyle(
                      color: _statusOk ? theme.colorScheme.primary : theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () => _save(app),
              child: Text(_editingId == null ? t('Add connector') : t('Save changes')),
            ),
            if (_editingId != null)
              TextButton(onPressed: _reset, child: Text(t('Cancel'))),
          ],
        ),
      ),
    );
  }
}
