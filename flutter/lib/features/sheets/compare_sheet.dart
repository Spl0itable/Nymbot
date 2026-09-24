import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../models/compare.dart';
import '../../models/model_maker.dart';
import '../brand_tile.dart';
import '../i18n/i18n.dart';
import '../markdown_body.dart';
import '../nym_glyph.dart';
import 'models_sheet.dart';
import 'sheet.dart';

Future<void> showCompareSheet(BuildContext context, {String prefill = ''}) =>
    showNymSheet<void>(
      context,
      (_) => _CompareSheet(prefill: prefill),
    );

class _CompareSheet extends StatefulWidget {
  const _CompareSheet({this.prefill = ''});

  final String prefill;

  @override
  State<_CompareSheet> createState() => _CompareSheetState();
}

class _CompareSheetState extends State<_CompareSheet> {
  final _prompt = TextEditingController();
  Map<String, dynamic>? _catalog;
  bool _loading = true;
  String? _a;
  String? _b;
  String _status = '';
  bool _busy = false;
  List<CompareRun> _runs = const [];

  @override
  void initState() {
    super.initState();
    _prompt.text = widget.prefill;
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final catalog = await app.api.models();
    app.notePricing(catalog);
    if (!mounted) return;
    final (a, b) = ModelPicker.compareDefaults(catalog,
        pinned: app.activeModel?['key'] as String?,
        favourites: app.favouriteModels);
    setState(() {
      _catalog = catalog;
      _loading = false;
      _a = a;
      _b = b;
    });
  }

  List<Map<String, dynamic>> get _models =>
      ModelPicker.modelsOf(_catalog).where(ModelPicker.isChat).toList();

  Map<String, dynamic>? _byKey(String? key) {
    for (final m in _models) {
      if (m['key'] == key) return m;
    }
    return null;
  }

  Future<void> _choose(bool first) async {
    final current = first ? _a : _b;
    final other = first ? _b : _a;
    final picked = await showModelChoice(
      context,
      title: first ? t('Pick Model A') : t('Pick Model B'),
      catalog: _catalog,
      current: current,
      unavailable: {
        if (other != null)
          other: first
              ? t('Already picked as Model B')
              : t('Already picked as Model A'),
      },
    );
    final key = picked?['key'] as String?;
    if (key == null || key == other || !mounted) return;
    setState(() {
      if (first) {
        _a = key;
      } else {
        _b = key;
      }
      _status = '';
    });
  }

  Future<void> _run() async {
    final app = AppScope.read(context);
    final a = _byKey(_a);
    final b = _byKey(_b);
    if (a == null || b == null || a['key'] == b['key']) {
      setState(() => _status = t('Pick two different models.'));
      return;
    }
    final text = _prompt.text.trim();
    if (text.isEmpty) {
      setState(() => _status = t('Type a prompt for both of them first.'));
      return;
    }

    final price = ((a['credits'] as num?)?.toInt() ?? 1) +
        ((b['credits'] as num?)?.toInt() ?? 1);
    // Both answers come from frontier models, so both are charged to the Pro balance.
    final have = app.proBalance;
    if (have != null && have < price) {
      setState(() => _status = t(
          'Comparing spends Pro credits — {n} for these two, and you have {have}. Type ?buy to top up.',
          {'n': price, 'have': have}));
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Ask both?')),
        content: Text(t(
            '{a} and {b} each answer once, so this costs two replies — about {n} Pro credits.',
            {'a': a['label'], 'b': b['label'], 'n': price})),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('Cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t('Ask both'))),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = t('Waiting on both…');
      _runs = const [];
    });
    final out = await app.compare(text, [a, b]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _runs = out;
      _status = out.isEmpty
          ? t('Nothing was sent.')
          : out.every((r) => r.ok)
          ? t('Both answered. Keep the one you want to carry on from.')
          : t('One of them did not answer.');
    });
  }

  Future<void> _keep(CompareRun run) async {
    final app = AppScope.read(context);
    final navigator = Navigator.of(context);
    await app.keepCompare(_prompt.text.trim(), run);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
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
            Text(t('Ask two models at once'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('The same prompt goes to two models on separate threads, so neither '
                  'sees the other\'s answer. Keep the one you prefer and the chat '
                  'carries on from it. Two replies means two charges.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(t('The model catalog is unavailable right now.'),
                    style: const TextStyle(fontSize: 12)),
              )
            else ...[
              ModelSlot(
                key: const ValueKey('compare-slot-a'),
                title: t('Model A'),
                model: _byKey(_a),
                catalog: _catalog,
                onTap: _busy ? null : () => _choose(true),
              ),
              const SizedBox(height: 8),
              ModelSlot(
                key: const ValueKey('compare-slot-b'),
                title: t('Model B'),
                model: _byKey(_b),
                catalog: _catalog,
                onTap: _busy ? null : () => _choose(false),
              ),
              if (_byKey(_a) != null && _byKey(_b) != null) ...[
                const SizedBox(height: 8),
                Text(
                  ModelPicker.pairLabel(_byKey(_a)!, _byKey(_b)!, _catalog),
                  style: const TextStyle(
                      fontSize: 12, color: NymbotColors.lightning),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  labelText: t('Prompt'),
                  hintText: t('What should both of them answer?'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _run,
                child: Text(_busy ? t('Waiting on both…') : t('Ask both')),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
            for (final run in _runs) ...[
              const SizedBox(height: 10),
              _Result(
                run: run,
                maker: ModelMaker.of(run.model, _catalog),
                onKeep: () => _keep(run),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.run, required this.maker, required this.onKeep});

  final CompareRun run;
  final ModelMaker? maker;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                const NymGlyph('model', size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(run.label,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      if (maker != null) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: maker!.name,
                          child: Semantics(
                            label: maker!.name,
                            image: true,
                            child: ExcludeSemantics(
                                child: BrandTile(slug: maker!.slug, size: 14)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (run.ok)
                  Text(t('{n} credits', {'n': creditFigure(run.cost)}),
                      style:
                          TextStyle(fontSize: 11, color: theme.hintColor)),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: run.ok
                  ? MarkdownBody(run.reply)
                  : Text(run.error ?? '',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error)),
            ),
          ),
          if (run.ok)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: FilledButton(
                onPressed: onKeep,
                child: Text(t('Keep this one')),
              ),
            ),
        ],
      ),
    );
  }
}
