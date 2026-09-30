import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/api_access.dart';
import '../i18n/i18n.dart';
import '../nym_glyph.dart';
import '../purchase_policy.dart';
import '../secret_guard.dart';
import 'models_sheet.dart';
import 'sheet.dart';

Future<void> showApiSheet(BuildContext context) =>
    showNymSheet<void>(context, (_) => const _ApiSheet());

const _snippetNames = ['curl', 'python', 'js', 'anthropic'];

const _apiKinds = [
  'chat',
  'image',
  'video',
  'speech',
  'transcription',
  'embedding',
];

const _docAnchors = {
  'chat': 'api-chat/#chat-completions',
  'anthropic': 'api-chat/#messages',
  'image': 'api-media/#images',
  'video': 'api-media/#video',
  'speech': 'api-media/#speech',
  'transcription': 'api-media/#transcription',
  'embedding': 'api-media/#embeddings',
};

const _imageUrl = 'https://example.com/photo.jpg';
const _curlKey = r'$NYMBOT_API_KEY';
const _pyKey = 'os.environ["NYMBOT_API_KEY"]';
const _jsKey = 'process.env.NYMBOT_API_KEY';

String apiModelKind(Map<String, dynamic>? m) {
  if (m == null) return 'chat';
  final type = m['type'];
  if (type == 'audio') {
    return m['audio_type'] == 'transcription' ? 'transcription' : 'speech';
  }
  return type is String && _apiKinds.contains(type) ? type : 'chat';
}

final _claudeId = RegExp(r'^(anthropic/|claude)', caseSensitive: false);

bool apiIsClaude(Map<String, dynamic>? m) =>
    apiModelKind(m) == 'chat' && _claudeId.hasMatch('${m?['id'] ?? ''}');

List<String> apiTabsFor(Map<String, dynamic>? m) => apiIsClaude(m)
    ? const ['curl', 'python', 'js', 'anthropic']
    : const ['curl', 'python', 'js'];

String _voiceFor(Map<String, dynamic> m) {
  final id = '${m['id'] ?? ''}';
  if (id.contains('aura-2')) return 'luna';
  if (id.contains('melotts')) return 'en';
  return 'alloy';
}

Map<String, dynamic> _capsOf(Map<String, dynamic> m) =>
    m['capabilities'] is Map
        ? Map<String, dynamic>.from(m['capabilities'] as Map)
        : const {};

int _secondsFor(Map<String, dynamic> m) {
  final raw = _capsOf(m)['max_duration_seconds'];
  final n = raw is num ? raw : (raw is String ? num.tryParse(raw) : null);
  return n != null && n == n.roundToDouble() && n > 0 && n <= 60
      ? n.toInt()
      : 5;
}

bool _needsImage(Map<String, dynamic> m) =>
    _capsOf(m)['requires_image_url'] == true;

String _q(Object? v) => jsonEncode('${v ?? ''}');

List<String> _openaiPy() => [
      'import os',
      'from openai import OpenAI',
      '',
      'client = OpenAI(base_url="$kApiBaseUrl", api_key=$_pyKey)',
    ];

List<String> _openaiJs([List<String> head = const []]) => [
      ...head,
      'import OpenAI from "openai";',
      '',
      'const client = new OpenAI({ baseURL: "$kApiBaseUrl", apiKey: $_jsKey });',
    ];

List<String> _curlJson(String path, String body, [String? tail]) => [
      'curl $kApiBaseUrl$path \\',
      '  -H "Authorization: Bearer $_curlKey" \\',
      '  -H "Content-Type: application/json" \\',
      "  -d '$body'${tail != null ? ' \\' : ''}",
      if (tail != null) tail,
    ];

List<String> _chatLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  return switch (tab) {
    'python' => [
        ..._openaiPy(),
        'reply = client.chat.completions.create(',
        '    model=$model,',
        '    messages=[{"role": "user", "content": "Hello"}],',
        ')',
        'print(reply.choices[0].message.content)',
      ],
    'js' => [
        ..._openaiJs(),
        'const reply = await client.chat.completions.create({',
        '  model: $model,',
        '  messages: [{ role: "user", content: "Hello" }],',
        '});',
        'console.log(reply.choices[0].message.content);',
      ],
    'anthropic' => [
        'import os',
        'import anthropic',
        '',
        'client = anthropic.Anthropic(base_url="$kApiAnthropicBaseUrl", api_key=$_pyKey)',
        'message = client.messages.create(',
        '    model=$model,',
        '    max_tokens=1024,',
        '    messages=[{"role": "user", "content": "Hello"}],',
        ')',
        'print(message.content[0].text)',
      ],
    _ => _curlJson('/chat/completions',
        '{"model": $model, "messages": [{"role": "user", "content": "Hello"}]}'),
  };
}

List<String> _imageLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  final edit = _needsImage(m);
  return switch (tab) {
    'python' => [
        ..._openaiPy(),
        'image = client.images.generate(',
        '    model=$model,',
        '    prompt="A lighthouse at dusk",',
        '    size="1024x1024",',
        if (edit) '    extra_body={"image_url": "$_imageUrl"},',
        ')',
        'print(image.data[0].url)',
      ],
    'js' => [
        ..._openaiJs(),
        'const image = await client.images.generate({',
        '  model: $model,',
        '  prompt: "A lighthouse at dusk",',
        '  size: "1024x1024",',
        if (edit) '  image_url: "$_imageUrl",',
        '});',
        'console.log(image.data[0].url);',
      ],
    _ => _curlJson('/images/generations',
        '{"model": $model, "prompt": "A lighthouse at dusk", "size": "1024x1024"${edit ? ', "image_url": "$_imageUrl"' : ''}}'),
  };
}

List<String> _videoLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  final seconds = _secondsFor(m);
  final still = _needsImage(m);
  return switch (tab) {
    'python' => [
        'import os',
        'import time',
        'import requests',
        '',
        'headers = {"Authorization": "Bearer " + $_pyKey}',
        'job = requests.post(',
        '    "$kApiBaseUrl/videos",',
        '    headers=headers,',
        '    json={"model": $model, "prompt": "Waves rolling onto a beach at sunrise", "duration": $seconds${still ? ', "image_url": "$_imageUrl"' : ''}},',
        ').json()',
        'while job.get("status") == "in_progress":',
        '    time.sleep(8)',
        '    job = requests.get("$kApiBaseUrl/videos/" + job["id"], headers=headers).json()',
        'print(job["data"]["url"] if job.get("status") == "completed" else job.get("error"))',
      ],
    'js' => [
        'const headers = { "Authorization": "Bearer " + $_jsKey, "Content-Type": "application/json" };',
        'let job = await (await fetch("$kApiBaseUrl/videos", {',
        '  method: "POST",',
        '  headers,',
        '  body: JSON.stringify({ model: $model, prompt: "Waves rolling onto a beach at sunrise", duration: $seconds${still ? ', image_url: "$_imageUrl"' : ''} }),',
        '})).json();',
        'while (job.status === "in_progress") {',
        '  await new Promise((r) => setTimeout(r, 8000));',
        '  job = await (await fetch("$kApiBaseUrl/videos/" + job.id, { headers })).json();',
        '}',
        'console.log(job.status === "completed" ? job.data.url : job.error);',
      ],
    _ => [
        ..._curlJson('/videos',
            '{"model": $model, "prompt": "Waves rolling onto a beach at sunrise", "duration": $seconds${still ? ', "image_url": "$_imageUrl"' : ''}}'),
        '',
        'curl $kApiBaseUrl/videos/VIDEO_ID \\',
        '  -H "Authorization: Bearer $_curlKey"',
      ],
  };
}

List<String> _speechLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  final voice = _q(_voiceFor(m));
  return switch (tab) {
    'python' => [
        ..._openaiPy(),
        'audio = client.audio.speech.create(',
        '    model=$model,',
        '    voice=$voice,',
        '    input="Hello from Nymbot",',
        ')',
        'audio.write_to_file("speech.mp3")',
      ],
    'js' => [
        ..._openaiJs(['import { writeFile } from "node:fs/promises";']),
        'const audio = await client.audio.speech.create({',
        '  model: $model,',
        '  voice: $voice,',
        '  input: "Hello from Nymbot",',
        '});',
        'await writeFile("speech.mp3", Buffer.from(await audio.arrayBuffer()));',
      ],
    _ => _curlJson('/audio/speech',
        '{"model": $model, "input": "Hello from Nymbot", "voice": $voice}',
        '  --output speech.mp3'),
  };
}

List<String> _transcriptionLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  return switch (tab) {
    'python' => [
        ..._openaiPy(),
        'transcript = client.audio.transcriptions.create(model=$model, file=open("audio.mp3", "rb"))',
        'print(transcript.text)',
      ],
    'js' => [
        ..._openaiJs(['import fs from "node:fs";']),
        'const transcript = await client.audio.transcriptions.create({',
        '  model: $model,',
        '  file: fs.createReadStream("audio.mp3"),',
        '});',
        'console.log(transcript.text);',
      ],
    _ => [
        'curl $kApiBaseUrl/audio/transcriptions \\',
        '  -H "Authorization: Bearer $_curlKey" \\',
        '  -F file=@audio.mp3 \\',
        '  -F model=${m['id'] ?? ''}',
      ],
  };
}

List<String> _embeddingLines(String tab, Map<String, dynamic> m) {
  final model = _q(m['id']);
  return switch (tab) {
    'python' => [
        ..._openaiPy(),
        'result = client.embeddings.create(model=$model, input="Hello")',
        'print(len(result.data[0].embedding))',
      ],
    'js' => [
        ..._openaiJs(),
        'const result = await client.embeddings.create({ model: $model, input: "Hello" });',
        'console.log(result.data[0].embedding.length);',
      ],
    _ => _curlJson('/embeddings', '{"model": $model, "input": "Hello"}'),
  };
}

String apiSnippet(String tab, [Map<String, dynamic>? model]) {
  final m = model ?? kApiAutoModel;
  final shown = apiTabsFor(m).contains(tab) ? tab : 'curl';
  final lines = switch (apiModelKind(m)) {
    'image' => _imageLines(shown, m),
    'video' => _videoLines(shown, m),
    'speech' => _speechLines(shown, m),
    'transcription' => _transcriptionLines(shown, m),
    'embedding' => _embeddingLines(shown, m),
    _ => _chatLines(shown, m),
  };
  return lines.join('\n');
}

String apiDocsFor(String tab, Map<String, dynamic>? m) {
  final kind = apiModelKind(m);
  return kApiDocsRoot +
      (kind == 'chat' && tab == 'anthropic'
          ? _docAnchors['anthropic']!
          : _docAnchors[kind]!);
}

String _jsNumber(double n) =>
    n == n.truncateToDouble() && n.abs() < 1e21 ? '${n.toInt()}' : '$n';

String? apiUsd(Object? v) {
  final n = v is num
      ? v.toDouble()
      : (v is String && v.trim().isNotEmpty ? double.tryParse(v) : null);
  if (n == null || !n.isFinite) return null;
  return '\$${_jsNumber(double.parse(n.toStringAsPrecision(3)))}';
}

String? _amountOf(Map<String, dynamic> p, String field) {
  final dollars = apiUsd(p[field]);
  if (dollars != null) return dollars;
  final raw = p['sats_$field'];
  final sats = raw is num ? raw : (raw is String ? num.tryParse(raw) : null);
  return sats != null && sats.isFinite ? t('{n} sats', {'n': figure(sats)}) : null;
}

String apiPriceLine(Map<String, dynamic>? m) {
  if (m != null && m['id'] == kApiAutoModel['id']) {
    return t('Priced per reply by the model it picks.');
  }
  final p = m?['pricing'] is Map
      ? Map<String, dynamic>.from(m!['pricing'] as Map)
      : <String, dynamic>{};
  final kind = apiModelKind(m);
  if (kind == 'chat') {
    if (p['type'] == 'per_request') {
      final each = _amountOf(p, 'usd_per_request');
      return each == null ? '' : t('{price} per request.', {'price': each});
    }
    final inn = _amountOf(p, 'input_per_1M_tokens');
    final out = _amountOf(p, 'output_per_1M_tokens');
    return inn != null && out != null
        ? t('{in} in, {out} out per 1M tokens.', {'in': inn, 'out': out})
        : '';
  }
  final field = switch (kind) {
    'image' => 'per_generation',
    'video' => 'per_second',
    'speech' => 'per_1k_chars',
    'transcription' => 'per_minute',
    _ => 'input_per_1M_tokens',
  };
  final price = _amountOf(p, field);
  if (price == null) return '';
  return switch (kind) {
    'image' => t('{price} per image.', {'price': price}),
    'video' => t('{price} per second.', {'price': price}),
    'speech' => t('{price} per 1k characters.', {'price': price}),
    'transcription' => t('{price} per minute.', {'price': price}),
    _ => t('{price} per 1M tokens.', {'price': price}),
  };
}

String apiBalanceLine(Map<String, dynamic>? m) => m?['balance'] == 'pro'
    ? t('Spends the Pro balance.')
    : t('Spends the standard balance.');

String apiModelHint(Map<String, dynamic>? m, {bool failed = false}) => [
      apiPriceLine(m),
      apiBalanceLine(m),
      if (failed) t('Other models could not be loaded.'),
    ].where((s) => s.isNotEmpty).join(' ');

List<Map<String, dynamic>> apiModelRows(ApiReply reply) {
  final raw = reply.ok ? reply.json['data'] : null;
  if (raw is! List) return const [];
  final rows = [
    for (final m in raw)
      if (m is Map && m['id'] is String && (m['id'] as String).isNotEmpty)
        Map<String, dynamic>.from(m),
  ];
  if (rows.isEmpty) return const [];
  return rows.any((m) => m['id'] == kApiAutoModel['id'])
      ? rows
      : [kApiAutoModel, ...rows];
}

String? _makerSlug(Map<String, dynamic> m) {
  if (m['id'] == kApiAutoModel['id']) return null;
  final id = '${m['id'] ?? ''}';
  if (id.contains('/') && !id.startsWith('@')) {
    return id.split('/').first.toLowerCase();
  }
  final owner = '${m['owned_by'] ?? ''}'
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return owner.isEmpty ? null : owner;
}

Map<String, dynamic> _pickerEntry(Map<String, dynamic> m) {
  final kind = apiModelKind(m);
  return {
    'key': '$kind:${m['id']}',
    'id': m['id'],
    'label': '${m['name'] ?? m['id']}',
    'description': m['description'] is String ? m['description'] : '',
    'author': '${m['owned_by'] ?? ''}',
    'authorSlug': _makerSlug(m),
    'kind': kind,
    'source': m,
  };
}

String _groupWord(String kind) => switch (kind) {
      'chat' => t('Chat'),
      'image' => t('Image'),
      'video' => t('Video'),
      'speech' => t('Speech'),
      'transcription' => t('Transcription'),
      _ => t('Embeddings'),
    };

Map<String, dynamic> _pickerCatalog(List<Map<String, dynamic>> models) {
  final entries = models.map(_pickerEntry).toList();
  return {
    'models': entries,
    'groups': [
      for (final kind in _apiKinds)
        if (entries.any((e) => e['kind'] == kind))
          {
            'author': _groupWord(kind),
            'keys': [
              for (final e in entries)
                if (e['kind'] == kind) e['key'] as String,
            ],
          },
    ],
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

String _dayUtc(DateTime d) => _day(d.toUtc());

String _moment(DateTime d) {
  final l = d.toLocal();
  return '${_day(l)} ${_two(l.hour)}:${_two(l.minute)}';
}

String _replyError(ApiReply reply) {
  if (reply.status == 0) {
    return t('Could not reach Nymbot. Check your connection and try again.');
  }
  return reply.error ?? t('Something went wrong ({status}).', {'status': reply.status});
}

String _tierName(String tier) => tier == 'standard' ? t('Standard') : t('Pro');

String _periodName(String period) => switch (period) {
      'daily' => t('Daily'),
      'weekly' => t('Weekly'),
      'monthly' => t('Monthly'),
      _ => t('Never'),
    };

String _periodWord(String period) => switch (period) {
      'daily' => t('daily'),
      'weekly' => t('weekly'),
      'monthly' => t('monthly'),
      _ => '',
    };

String _typeWord(String type) => switch (type) {
      'chat' => t('chat'),
      'responses' => t('responses'),
      'messages' => t('messages'),
      'image' => t('image'),
      'video' => t('video'),
      'speech' => t('speech'),
      'transcription' => t('transcription'),
      'embedding' => t('embedding'),
      _ => type,
    };

final _nwcUrl =
    RegExp(r'^nostr\+walletconnect://[0-9a-f]{64}\?', caseSensitive: false);

Color? _statusColor(BuildContext context, String? kind) => switch (kind) {
      'ok' => Theme.of(context).colorScheme.primary,
      'warn' => NymbotColors.danger,
      _ => Theme.of(context).hintColor,
    };

class _ApiSheet extends StatefulWidget {
  const _ApiSheet();

  @override
  State<_ApiSheet> createState() => _ApiSheetState();
}

class _ApiSheetState extends State<_ApiSheet> {
  late final ApiAccess _api = AppScope.read(context).apiAccess;

  ApiAccount? _account;
  String? _accountError;
  List<ApiKey>? _keys;
  String? _keysError;
  bool _keysLoading = true;
  String? _keysStatus;
  String? _keysStatusKind;
  List<ApiQuery>? _history;
  String? _historyError;
  AutoTopup? _topup;
  bool _topupHidden = creditPurchasesDisabled;
  String? _topupError;
  String? _topupStatus;
  String? _topupStatusKind;
  bool _topupBusy = false;
  String _topupTier = 'pro';
  final _topupUrl = TextEditingController();
  final _topupThreshold = TextEditingController(text: '5000');
  final _topupAmount = TextEditingController(text: '10000');
  String _snippet = 'curl';
  Map<String, dynamic> _model = kApiAutoModel;
  List<Map<String, dynamic>> _models = const [kApiAutoModel];
  bool _modelsFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadModels());
    unawaited(_loadAccount());
    unawaited(_loadKeys());
    unawaited(_loadHistory());
    if (!_topupHidden) unawaited(_loadTopup());
  }

  @override
  void dispose() {
    _topupUrl.dispose();
    _topupThreshold.dispose();
    _topupAmount.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    final reply = await _api.account();
    if (!mounted) return;
    setState(() {
      if (reply.ok) {
        _account = ApiAccount.fromJson(reply.data);
        _accountError = null;
      } else {
        _accountError = _replyError(reply);
      }
    });
  }

  Future<void> _loadModels() async {
    final rows = apiModelRows(await _api.models());
    if (!mounted) return;
    setState(() {
      _modelsFailed = rows.isEmpty;
      _models = rows.isEmpty ? const [kApiAutoModel] : rows;
      final kind = apiModelKind(_model);
      _setModel(_models.firstWhere(
          (m) => m['id'] == _model['id'] && apiModelKind(m) == kind,
          orElse: () => kApiAutoModel));
    });
  }

  void _setModel(Map<String, dynamic> m) {
    _model = m;
    if (!apiTabsFor(m).contains(_snippet)) _snippet = 'curl';
  }

  Future<void> _pickModel() async {
    final picked = await showModelChoice(
      context,
      title: t('Pick a model'),
      catalog: _pickerCatalog(_models),
      current: _pickerEntry(_model)['key'] as String,
      price: (e) => apiPriceLine(e['source'] as Map<String, dynamic>?),
    );
    final source = picked?['source'];
    if (source is! Map<String, dynamic> || !mounted) return;
    setState(() => _setModel(source));
  }

  Future<void> _loadKeys() async {
    setState(() => _keysLoading = true);
    final reply = await _api.listKeys();
    if (!mounted) return;
    setState(() {
      _keysLoading = false;
      if (reply.ok) {
        final raw = reply.data;
        _keys = [
          if (raw is List)
            for (final k in raw)
              if (ApiKey.fromJson(k) case final ApiKey key) key,
        ];
        _keysError = null;
      } else {
        _keysError = _replyError(reply);
      }
    });
  }

  Future<void> _loadHistory() async {
    final reply = await _api.history();
    if (!mounted) return;
    setState(() {
      if (reply.ok) {
        final raw = reply.data;
        _history = [
          if (raw is List)
            for (final q in raw)
              if (ApiQuery.fromJson(q) case final ApiQuery query) query,
        ];
        _historyError = null;
      } else {
        _historyError = _replyError(reply);
      }
    });
  }

  Future<void> _loadTopup() async {
    final reply = await _api.autoTopup();
    if (!mounted) return;
    setState(() {
      if (reply.unavailable) {
        _topupHidden = true;
      } else if (reply.ok) {
        _topup = AutoTopup.fromJson(reply.body);
        _topupTier = _topup!.tier;
        _topupError = null;
      } else {
        _topupError = _replyError(reply);
      }
    });
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _copyPlain(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(t('Copied.'))));
  }

  bool get _free =>
      _account?.empty ?? AppScope.read(context).freeOnly;

  void _keysSay(String? text, [String? kind]) => setState(() {
        _keysStatus = text;
        _keysStatusKind = kind;
      });

  void _topupSay(String? text, [String? kind]) => setState(() {
        _topupStatus = text;
        _topupStatusKind = kind;
      });

  Future<void> _edit([ApiKey? existing]) async {
    final saved = await showNymDialog<ApiKey>(
      context: context,
      builder: (_) => _KeyEditor(api: _api, existing: existing),
    );
    if (saved == null || !mounted) return;
    final secret = saved.secret;
    if (secret != null) {
      await showNymDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _NewKeyDialog(secret: secret, name: saved.name),
      );
    }
    if (!mounted) return;
    await Future.wait([_loadKeys(), _loadAccount()]);
    if (!mounted) return;
    if (existing != null) {
      _keysSay(t('Saved.'), 'ok');
    } else {
      _keysSay(
          _free
              ? t('Key made. API calls need credits, so buy some before you use it.')
              : t('Key made.'),
          'ok');
    }
  }

  Future<void> _revoke(ApiKey key) async {
    final sure = await showNymDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Revoke {name}?', {'name': key.name})),
        content: Text(t(
            'Anything using this key stops working at once. This cannot be undone.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('api-revoke-confirm'),
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Revoke')),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    _keysSay(t('Revoking…'));
    final reply = await _api.revokeKey(key.id);
    if (!mounted) return;
    if (!reply.ok) {
      _keysSay(_replyError(reply), 'warn');
      return;
    }
    await Future.wait([_loadKeys(), _loadAccount()]);
    if (mounted) _keysSay(t('Revoked {name}.', {'name': key.name}), 'ok');
  }

  Future<void> _connectTopup() async {
    final url = _topupUrl.text.trim();
    final threshold = int.tryParse(_topupThreshold.text.trim());
    final amount = int.tryParse(_topupAmount.text.trim());
    String? problem;
    if (!_nwcUrl.hasMatch(url)) {
      problem = t('Paste the nostr+walletconnect:// connection string from your wallet.');
    } else if (threshold == null || threshold < kAutoTopupMinSats) {
      problem = t('The threshold is at least {n} sats.',
          {'n': figure(kAutoTopupMinSats)});
    } else if (amount == null ||
        amount < kAutoTopupMinSats ||
        amount > kAutoTopupMaxSats) {
      problem = t('Top up by {min} to {max} sats.',
          {'min': figure(kAutoTopupMinSats), 'max': figure(kAutoTopupMaxSats)});
    }
    if (problem != null) {
      _topupSay(problem, 'warn');
      return;
    }
    setState(() => _topupBusy = true);
    _topupSay(t('Checking the wallet…'));
    final reply = await _api.connectAutoTopup(
      nwcUrl: url,
      thresholdSats: threshold!,
      topupSats: amount!,
      tier: _topupTier,
    );
    if (!mounted) return;
    if (!reply.ok) {
      setState(() => _topupBusy = false);
      _topupSay(_replyError(reply), 'warn');
      return;
    }
    _topupUrl.clear();
    await _loadTopup();
    if (!mounted) return;
    setState(() => _topupBusy = false);
    _topupSay(t('Wallet connected.'), 'ok');
  }

  Future<void> _disconnectTopup() async {
    final sure = await showNymDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Disconnect the wallet?')),
        content: Text(t(
            'Balances stop topping up on their own. The stored connection is deleted.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('api-topup-disconnect-confirm'),
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Disconnect')),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _topupBusy = true);
    _topupSay(t('Disconnecting…'));
    final reply = await _api.disconnectAutoTopup();
    if (!mounted) return;
    if (!reply.ok) {
      setState(() => _topupBusy = false);
      _topupSay(_replyError(reply), 'warn');
      return;
    }
    await _loadTopup();
    if (!mounted) return;
    setState(() => _topupBusy = false);
    _topupSay(t('Wallet disconnected.'), 'ok');
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _hint(String text, {Key? key, Color? color}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: color ?? Theme.of(context).hintColor)),
      );

  Widget _status(String text, String? kind, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, height: 1.4, color: _statusColor(context, kind))),
      );

  Widget _freeNote() => Container(
        key: const ValueKey('api-free-note'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
              color: NymbotColors.lightning.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
        ),
        child: Text(
          t('API calls need credits. You can make keys now, but every call is refused until you buy some.'),
          style: const TextStyle(
              fontSize: 12.5, height: 1.4, color: NymbotColors.lightning),
        ),
      );

  Widget _error(String text, {Key? key, VoidCallback? retry, Key? retryKey}) =>
      Padding(
        key: key,
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(text,
                style: const TextStyle(fontSize: 12, color: NymbotColors.danger)),
            if (retry != null)
              TextButton(key: retryKey, onPressed: retry, child: Text(t('Retry'))),
          ],
        ),
      );

  BoxDecoration _box() => BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
      );

  Widget _baseUrl() {
    const mono = TextStyle(
        fontSize: 13, fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: _box(),
      child: Row(
        children: [
          const Expanded(child: Text(kApiBaseUrl, style: mono)),
          IconButton(
            key: const ValueKey('api-copy-base'),
            tooltip: t('Copy'),
            icon: const NymGlyph('copy', size: 16),
            onPressed: () => _copyPlain(kApiBaseUrl),
          ),
        ],
      ),
    );
  }

  Widget _quickStart() {
    final code = apiSnippet(_snippet, _model);
    final tabs = apiTabsFor(_model);
    final docs = apiDocsFor(_snippet, _model);
    final picker = _pickerCatalog(_models);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(t('Model'),
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor)),
        ),
        ModelSlot(
          key: const ValueKey('api-model'),
          title: t('Model'),
          model: _pickerEntry(_model),
          catalog: picker,
          onTap: _pickModel,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            apiModelHint(_model, failed: _modelsFailed),
            key: const ValueKey('api-model-hint'),
            style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Theme.of(context).hintColor),
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final kind in _snippetNames)
              if (tabs.contains(kind))
                ChoiceChip(
                  key: ValueKey('api-snippet-$kind'),
                  label: Text(switch (kind) {
                    'python' => 'Python',
                    'js' => 'JavaScript',
                    'anthropic' => 'Anthropic SDK',
                    _ => 'cURL',
                  }),
                  selected: _snippet == kind,
                  onSelected: (_) => setState(() => _snippet = kind),
                ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: _box(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  code,
                  key: const ValueKey('api-snippet'),
                  style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback),
                ),
              ),
              IconButton(
                key: const ValueKey('api-copy-snippet'),
                tooltip: t('Copy'),
                icon: const NymGlyph('copy', size: 16),
                onPressed: () => _copyPlain(code),
              ),
            ],
          ),
        ),
        _hint(t('Set NYMBOT_API_KEY to a key made below. Claude Code and other Anthropic clients use {url}.',
            {'url': kApiAnthropicBaseUrl})),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            key: const ValueKey('api-docs-link'),
            link: true,
            linkUrl: Uri.parse(docs),
            child: TextButton(
              key: const ValueKey('api-docs'),
              onPressed: () => _open(docs),
              child: Text(t('Read the API docs')),
            ),
          ),
        ),
      ],
    );
  }

  Widget _balance(String tier, ApiBalance b) {
    final theme = Theme.of(context);
    final value = b.sats != null
        ? t('{n} sats', {'n': figure(b.sats)})
        : (b.credits != null
            ? t('{n} credits', {'n': creditFigure(b.credits)})
            : '…');
    return Expanded(
      child: Container(
        key: ValueKey('api-balance-$tier'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: _box(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_tierName(tier),
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
            Text(value,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _balances() {
    final account = _account;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _balance('standard', account?.standard ?? const ApiBalance()),
            const SizedBox(width: 8),
            _balance('pro', account?.pro ?? const ApiBalance()),
          ],
        ),
        _hint(t('Nymbot Auto spends the standard balance; any other model spends Pro.')),
        if (_accountError != null) _error(_accountError!),
      ],
    );
  }

  Widget _keyCard(ApiKey key) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final expired = key.expiredAt(now);
    final dim = key.revoked || expired;
    final usage = <String>[
      if (key.limitSats != null) ...[
        t('{used} of {cap} sats', {
          'used': figure(key.periodUsedSats),
          'cap': figure(key.limitSats),
        }),
        if (key.resetPeriod != null)
          key.resetAt != null
              ? t('resets {period}, next {date}', {
                  'period': _periodWord(key.resetPeriod!),
                  'date': _dayUtc(key.resetAt!),
                })
              : t('resets {period}', {'period': _periodWord(key.resetPeriod!)}),
      ] else
        t('No cap'),
      t('{n} sats in total', {'n': figure(key.totalUsedSats)}),
    ];
    final status = <String>[
      if (key.revokedAt != null)
        t('Revoked {date}', {'date': _day(key.revokedAt!.toLocal())}),
      if (key.expireAt != null)
        expired
            ? t('Expired {date}', {'date': _day(key.expireAt!.toLocal())})
            : t('Expires {date}', {'date': _day(key.expireAt!.toLocal())}),
      key.lastUsedAt != null
          ? t('Last used {when}', {'when': _moment(key.lastUsedAt!)})
          : t('Never used'),
    ];
    final lines = [usage.join(' · '), status.join(' · ')];
    return Container(
      key: ValueKey('api-key-${key.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
      decoration: _box(),
      child: Opacity(
        opacity: dim ? 0.6 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(key.name.isEmpty ? t('Untitled') : key.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                if (key.revoked)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Text(t('Revoked'),
                        style: const TextStyle(
                            fontSize: 12, color: NymbotColors.danger)),
                  )
                else ...[
                  if (expired)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 4),
                      child: Text(t('Expired'),
                          style: const TextStyle(
                              fontSize: 12, color: NymbotColors.lightning)),
                    ),
                  IconButton(
                    key: ValueKey('api-key-edit-${key.id}'),
                    tooltip: t('Edit'),
                    visualDensity: VisualDensity.compact,
                    icon: const NymGlyph('pencil', size: 16),
                    onPressed: () => _edit(key),
                  ),
                  IconButton(
                    key: ValueKey('api-key-revoke-${key.id}'),
                    tooltip: t('Revoke'),
                    visualDensity: VisualDensity.compact,
                    icon: const NymGlyph('close', size: 16),
                    onPressed: () => _revoke(key),
                  ),
                ],
              ],
            ),
            if (key.hint.isNotEmpty)
              Text(key.hint,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      color: theme.hintColor)),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(line, style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _keyList() {
    final keys = _keys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_keysStatus != null)
          _status(_keysStatus!, _keysStatusKind,
              key: const ValueKey('api-keys-status')),
        if (_keysError != null)
          _error(_keysError!,
              key: const ValueKey('api-keys-error'),
              retry: _loadKeys,
              retryKey: const ValueKey('api-keys-retry'))
        else if (keys == null && _keysLoading)
          _hint(t('Loading…'))
        else if (keys != null && keys.isEmpty)
          _hint(t('No keys yet. Make one below; it works with any OpenAI-compatible client.'))
        else if (keys != null)
          for (final key in [
            ...keys.where((k) => !k.revoked),
            ...keys.where((k) => k.revoked),
          ])
            _keyCard(key),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: const ValueKey('api-create'),
            onPressed: () => _edit(),
            child: Text(t('Create key')),
          ),
        ),
      ],
    );
  }

  Widget _queryRow(ApiQuery q) {
    final theme = Theme.of(context);
    final owner = _keys?.where((k) => k.id == q.keyId).firstOrNull;
    final parts = [
      if (q.timestamp != null) _moment(q.timestamp!),
      if (q.type.isNotEmpty) _typeWord(q.type),
      t('{input} in, {output} out', {
        'input': figure(q.inputTokens),
        'output': figure(q.outputTokens),
      }),
      t('{n} sats', {'n': figure(q.costSats)}),
      if (q.balance == 'standard') t('standard'),
      if (q.balance == 'pro') t('Pro'),
      if (owner != null && owner.name.isNotEmpty) owner.name,
      if (q.webSearch) t('web search'),
      if (q.status != 'ok') t('failed'),
    ];
    return Padding(
      key: ValueKey('api-query-${q.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q.model,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback)),
          Text(parts.join(' · '),
              style: TextStyle(
                  fontSize: 11.5,
                  color: q.status != 'ok'
                      ? NymbotColors.danger
                      : theme.hintColor)),
        ],
      ),
    );
  }

  Widget _historyList() {
    final history = _history;
    if (_historyError != null) {
      return _error(_historyError!, retry: _loadHistory);
    }
    if (history == null) return _hint(t('Loading…'));
    if (history.isEmpty) return _hint(t('No API calls yet.'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final q in history.take(20)) _queryRow(q)],
    );
  }

  Widget _topupSection() {
    final topup = _topup;
    final label = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    final children = <Widget>[
      _hint(t('Connect a Nostr Wallet Connect wallet and Nymbot pays an invoice from it whenever a balance drops below the threshold. The connection is stored encrypted on the server.')),
    ];
    final status = _topupStatus == null
        ? null
        : _status(_topupStatus!, _topupStatusKind,
            key: const ValueKey('api-topup-status'));
    if (topup == null && _topupError == null) {
      children.add(_hint(t('Loading…')));
    } else if (topup == null) {
      children.add(_error(_topupError!, retry: _loadTopup));
    } else if (topup.connected) {
      children.addAll([
        const SizedBox(height: 6),
        Text(
          t('Connected. When the {tier} balance drops below {threshold} sats, it tops up {topup} sats.',
              {
                'tier': topup.tier == 'standard' ? t('standard') : t('Pro'),
                'threshold': figure(topup.thresholdSats ?? 0),
                'topup': figure(topup.topupSats ?? 0),
              }),
          style: const TextStyle(fontSize: 13),
        ),
        if (topup.wallet.isNotEmpty) _hint(topup.wallet),
        if (topup.lastTopupAt != null)
          _hint(t('Last top-up {when}.', {'when': _moment(topup.lastTopupAt!)})),
        if (topup.lastError != null)
          _hint(t('Last error: {error}', {'error': topup.lastError}),
              color: NymbotColors.danger),
        if (status != null) status,
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            key: const ValueKey('api-topup-disconnect'),
            style: OutlinedButton.styleFrom(
                foregroundColor: NymbotColors.danger),
            onPressed: _topupBusy ? null : _disconnectTopup,
            child: Text(t('Disconnect')),
          ),
        ),
      ]);
    } else {
      children.addAll([
        const SizedBox(height: 6),
        Text(t('Not connected.'), style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('api-topup-url'),
          controller: _topupUrl,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: t('Wallet connection'),
            hintText: 'nostr+walletconnect://…',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('api-topup-threshold'),
                controller: _topupThreshold,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: t('When below (sats)')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('api-topup-amount'),
                controller: _topupAmount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: t('Top up by (sats)')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(t('Balance'), style: label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: [
            for (final tier in ['standard', 'pro'])
              ChoiceChip(
                key: ValueKey('api-topup-tier-$tier'),
                label: Text(_tierName(tier)),
                selected: _topupTier == tier,
                onSelected: (_) => setState(() => _topupTier = tier),
              ),
          ],
        ),
        if (status != null) status,
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: const ValueKey('api-topup-connect'),
            onPressed: _topupBusy ? null : _connectTopup,
            child: Text(t('Connect wallet')),
          ),
        ),
      ]);
    }
    return Column(
      key: const ValueKey('api-topup'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_heading(t('Auto top-up')), ...children],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('API'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            t('Call Nymbot\'s models from your own code with an OpenAI-compatible API. Requests spend the same balances as the app: Nymbot Auto uses the standard balance, any other model the Pro balance. Unlike chats in the app, API requests are not end-to-end encrypted.'),
            style: TextStyle(fontSize: 12, height: 1.45, color: theme.hintColor),
          ),
          if (_free) _freeNote(),
          _heading(t('Base URL')),
          _baseUrl(),
          _heading(t('Balances')),
          _balances(),
          _heading(t('Quick start')),
          _quickStart(),
          _heading(t('Keys')),
          _keyList(),
          _heading(t('Recent API calls')),
          _historyList(),
          if (!_topupHidden) _topupSection(),
        ],
      ),
    );
  }
}

const _expiryChoices = ['never', '7', '30', '90', '365'];

class _KeyEditor extends StatefulWidget {
  const _KeyEditor({required this.api, this.existing});

  final ApiAccess api;
  final ApiKey? existing;

  @override
  State<_KeyEditor> createState() => _KeyEditorState();
}

class _KeyEditorState extends State<_KeyEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _cap = TextEditingController(
      text: widget.existing?.limitSats == null
          ? ''
          : '${widget.existing!.limitSats}');
  late String _period = widget.existing?.resetPeriod ?? 'none';
  late String _expiry =
      widget.existing?.expireAt != null ? 'keep' : 'never';
  String? _status;
  bool _warn = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cap.addListener(_capChanged);
  }

  void _capChanged() => setState(() {});

  @override
  void dispose() {
    _cap.removeListener(_capChanged);
    _name.dispose();
    _cap.dispose();
    super.dispose();
  }

  String _expiryLabel(String choice) => switch (choice) {
        'keep' => t('Keep {date}',
            {'date': _day(widget.existing!.expireAt!.toLocal())}),
        'never' => t('Never'),
        '365' => t('1 year'),
        _ => t('{n} days', {'n': choice}),
      };

  DateTime? _expiryAt(String choice) {
    final days = int.tryParse(choice);
    return days == null ? null : DateTime.now().add(Duration(days: days));
  }

  void _say(String? text, {bool warn = false}) => setState(() {
        _status = text;
        _warn = warn;
      });

  Future<void> _save() async {
    final name = _name.text.trim();
    final capText = _cap.text.trim();
    final cap = capText.isEmpty ? null : int.tryParse(capText);
    if (name.isEmpty) {
      _say(t('Give the key a name.'), warn: true);
      return;
    }
    if (name.length > kApiKeyNameMax) {
      _say(t('Keep the name to 40 characters.'), warn: true);
      return;
    }
    if (capText.isNotEmpty && (cap == null || cap < 1)) {
      _say(t('The cap is a whole number of sats, 1 or more.'), warn: true);
      return;
    }
    final period = _period == 'none' ? null : _period;
    if (period != null && cap == null) {
      _say(t('A reset period needs a cap.'), warn: true);
      return;
    }
    final existing = widget.existing;
    final changes = existing == null
        ? const <String, Object?>{}
        : <String, Object?>{
            if (name != existing.name) 'name': name,
            if (cap != existing.limitSats) 'limit_sats': cap,
            if (period != existing.resetPeriod) 'reset_period': period,
            if (_expiry != 'keep' &&
                !(_expiry == 'never' && existing.expireAt == null))
              'expire_at': _expiryAt(_expiry)?.toUtc().toIso8601String(),
          };
    if (existing != null && changes.isEmpty) {
      _say(t('Nothing changed.'));
      return;
    }
    setState(() {
      _status = existing == null ? t('Making the key…') : t('Saving…');
      _warn = false;
      _saving = true;
    });
    ApiReply reply;
    if (existing == null) {
      reply = await widget.api.createKey(
        name: name,
        limitSats: cap,
        resetPeriod: period,
        expireAt: _expiryAt(_expiry),
      );
    } else {
      reply = await widget.api.updateKey(existing.id, changes);
    }
    if (!mounted) return;
    if (!reply.ok) {
      setState(() {
        _saving = false;
        _status = _replyError(reply);
        _warn = true;
      });
      return;
    }
    Navigator.pop(
        context,
        ApiKey.fromJson(reply.data) ??
            ApiKey(id: existing?.id ?? '', name: name));
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final choices = [
      if (existing?.expireAt != null) 'keep',
      ..._expiryChoices,
    ];
    final label = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return AlertDialog(
      title: Text(existing == null
          ? t('New key')
          : t('Edit {name}', {'name': existing.name})),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('api-key-name'),
            controller: _name,
            maxLength: kApiKeyNameMax,
            autofocus: existing == null,
            decoration: InputDecoration(labelText: t('Name'), hintText: 'Laptop'),
          ),
          TextField(
            key: const ValueKey('api-key-cap'),
            controller: _cap,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: t('Spending cap (sats, optional)'),
              hintText: t('No cap'),
            ),
          ),
          const SizedBox(height: 12),
          Text(t('Cap resets'), style: label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in ['none', ...kApiResetPeriods])
                ChoiceChip(
                  key: ValueKey('api-period-$p'),
                  label: Text(_periodName(p)),
                  selected: _period == p,
                  onSelected: (_) => setState(() => _period = p),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(t('Expires (optional)'), style: label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in choices)
                ChoiceChip(
                  key: ValueKey('api-expiry-$c'),
                  label: Text(_expiryLabel(c)),
                  selected: _expiry == c,
                  onSelected: (_) => setState(() => _expiry = c),
                ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_status!,
                  style: TextStyle(
                      fontSize: 12,
                      color: _statusColor(context, _warn ? 'warn' : null))),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(t('Cancel')),
        ),
        FilledButton(
          key: const ValueKey('api-key-save'),
          onPressed: _saving ? null : _save,
          child: Text(existing == null ? t('Create key') : t('Save changes')),
        ),
      ],
    );
  }
}

class _NewKeyDialog extends StatefulWidget {
  const _NewKeyDialog({required this.secret, required this.name});

  final String secret;
  final String name;

  @override
  State<_NewKeyDialog> createState() => _NewKeyDialogState();
}

class _NewKeyDialogState extends State<_NewKeyDialog> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return SecretGuard(
      child: AlertDialog(
        title: Text(t('Your new key')),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.name.isNotEmpty)
              Text(widget.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              t('Copy this key now. You will not see it again: Nymbot keeps only a hash of it.'),
              style: const TextStyle(
                  fontSize: 12, height: 1.4, color: NymbotColors.lightning),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
              ),
              child: Text(
                widget.secret,
                key: const ValueKey('api-new-key'),
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('api-new-key-done'),
            onPressed: () => Navigator.pop(context),
            child: Text(t('I saved it')),
          ),
          FilledButton(
            key: const ValueKey('api-new-key-copy'),
            onPressed: () async {
              await SecretScreen.copy(widget.secret);
              if (mounted) setState(() => _copied = true);
            },
            child: Text(_copied ? t('Copied.') : t('Copy')),
          ),
        ],
      ),
    );
  }
}
