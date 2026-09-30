import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/crypto/schnorr.dart' as schnorr;
import '../models/nostr_event.dart';

const String kDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';
const String kCanaryUrl =
    'https://raw.githubusercontent.com/Spl0itable/Nymbot/main/canary.json';
const String kCanaryPageUrl =
    'https://github.com/Spl0itable/Nymbot/blob/main/canary.json';
const String kCanaryDTag = 'nymbot-warrant-canary';
const int kCanaryKind = 30078;

enum CanaryState { ok, stale, gone, forged, unsigned }

class CanaryResult {
  const CanaryResult({
    required this.state,
    this.statement = '',
    this.updatedAt,
    this.dueBy,
    this.overdue = false,
    this.btcBlockHeight,
    this.btcBlockHash,
    this.id = '',
  });

  final CanaryState state;
  final String statement;
  final DateTime? updatedAt;
  final DateTime? dueBy;
  final bool overdue;
  final int? btcBlockHeight;
  final String? btcBlockHash;
  final String id;

  bool get signed =>
      state == CanaryState.ok || state == CanaryState.stale;
}

bool _pinned(Map<String, dynamic> doc, String pubkey) {
  try {
    final event = NostrEvent.fromJson(doc);
    if (event.id.isEmpty) return false;
    if (event.pubkey != pubkey || event.kind != kCanaryKind) return false;
    if (event.tagValue('d') != kCanaryDTag) return false;
    return schnorr.verifyEvent(event);
  } catch (_) {
    return false;
  }
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

CanaryResult evaluateCanary(
  int statusCode,
  List<int> body, {
  DateTime? now,
  String pubkey = kDeveloperPubkey,
}) {
  if (statusCode == 404) return const CanaryResult(state: CanaryState.gone);
  if (statusCode < 200 || statusCode >= 300) {
    throw http.ClientException('canary http $statusCode');
  }
  final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('canary is not an object');
  }
  final signed = '${decoded['sig'] ?? ''}'.isNotEmpty;
  if (!signed) {
    return CanaryResult(
      state: CanaryState.unsigned,
      statement: decoded['statement'] is String
          ? decoded['statement'] as String
          : '',
    );
  }
  if (!_pinned(decoded, pubkey)) {
    return const CanaryResult(state: CanaryState.forged);
  }
  Map<String, dynamic> c = const {};
  try {
    final inner = jsonDecode(decoded['content'] as String);
    if (inner is Map<String, dynamic>) c = inner;
  } catch (_) {}
  final dueBy = _date(c['nextUpdateBy']);
  final overdue = dueBy != null && (now ?? DateTime.now()).isAfter(dueBy);
  final clear = c.isNotEmpty && c['allClear'] != false && !overdue;
  final btc = c['btcBlock'];
  return CanaryResult(
    state: clear ? CanaryState.ok : CanaryState.stale,
    statement: c['statement'] is String ? c['statement'] as String : '',
    updatedAt: _date(c['updatedAt']),
    dueBy: dueBy,
    overdue: overdue,
    btcBlockHeight:
        btc is Map && btc['height'] is num ? (btc['height'] as num).toInt() : null,
    btcBlockHash:
        btc is Map && btc['hash'] is String ? btc['hash'] as String : null,
    id: decoded['id'] as String,
  );
}

Future<CanaryResult> fetchCanary({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(Uri.parse(kCanaryUrl), headers: const {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 10));
    return evaluateCanary(res.statusCode, res.bodyBytes);
  } finally {
    if (client == null) c.close();
  }
}
