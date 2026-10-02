import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';

const String kApiBaseUrl = 'https://nymbot.ai/api/v1';
const String kApiAnthropicBaseUrl = 'https://nymbot.ai/api';
const String kApiDocsUrl = 'https://nymbot.ai/docs/api/';
const String kApiDocsRoot = 'https://nymbot.ai/docs/';
const Map<String, dynamic> kApiAutoModel = {
  'id': 'nymbot/auto',
  'object': 'model',
  'type': 'chat',
  'owned_by': 'Nymbot',
  'name': 'Nymbot Auto',
  'balance': 'standard',
  'pricing': {'type': 'variable', 'currency': 'USD'},
};
const int kApiKeyNameMax = 40;
const int kAutoTopupMinSats = 1000;
const int kAutoTopupMaxSats = 1000000;
const List<String> kApiResetPeriods = ['daily', 'weekly', 'monthly'];

class ApiReply {
  const ApiReply(this.status, this.body);

  final int status;
  final Object? body;

  bool get ok => status >= 200 && status < 300;

  bool get unavailable => status == 501;

  Map<String, dynamic> get json =>
      body is Map<String, dynamic> ? body as Map<String, dynamic> : const {};

  Object? get data => json.containsKey('data') ? json['data'] : body;

  String? get error {
    if (ok) return null;
    final e = json['error'];
    if (e is Map && e['message'] is String) return e['message'] as String;
    if (e is String && e.isNotEmpty) return e;
    final m = json['message'];
    if (m is String && m.isNotEmpty) return m;
    return null;
  }
}

DateTime? _time(Object? raw) {
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw)?.toLocal();
  if (raw is num && raw > 0) {
    final ms = raw < 1e12 ? raw * 1000 : raw;
    return DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  }
  return null;
}

int? _int(Object? raw) => raw is num ? raw.toInt() : null;

class ApiKey {
  const ApiKey({
    required this.id,
    required this.name,
    this.hint = '',
    this.limitSats,
    this.resetPeriod,
    this.resetAt,
    this.expireAt,
    this.periodUsedSats = 0,
    this.totalUsedSats = 0,
    this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
    this.secret,
  });

  final String id;
  final String name;
  final String hint;
  final int? limitSats;
  final String? resetPeriod;
  final DateTime? resetAt;
  final DateTime? expireAt;
  final int periodUsedSats;
  final int totalUsedSats;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;
  final String? secret;

  bool get revoked => revokedAt != null;

  bool expiredAt(DateTime now) => expireAt != null && !expireAt!.isAfter(now);

  static ApiKey? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final key = raw['key'];
    return ApiKey(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '',
      hint: raw['hint'] is String ? raw['hint'] as String : '',
      limitSats: _int(raw['limit_sats']),
      resetPeriod:
          raw['reset_period'] is String ? raw['reset_period'] as String : null,
      resetAt: _time(raw['reset_at']),
      expireAt: _time(raw['expire_at']),
      periodUsedSats: _int(raw['period_used_sats']) ?? 0,
      totalUsedSats: _int(raw['total_used_sats']) ?? 0,
      createdAt: _time(raw['created_at']),
      lastUsedAt: _time(raw['last_used_at']),
      revokedAt: _time(raw['revoked_at']),
      secret: key is String && key.isNotEmpty ? key : null,
    );
  }
}

class ApiQuery {
  const ApiQuery({
    required this.id,
    this.timestamp,
    this.model = '',
    this.type = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.costSats = 0,
    this.balance = '',
    this.status = 'ok',
    this.keyId = '',
    this.webSearch = false,
  });

  final String id;
  final DateTime? timestamp;
  final String model;
  final String type;
  final int inputTokens;
  final int outputTokens;
  final num costSats;
  final String balance;
  final String status;
  final String keyId;
  final bool webSearch;

  static ApiQuery? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ApiQuery(
      id: '${raw['id'] ?? ''}',
      timestamp: _time(raw['timestamp']),
      model: raw['model'] is String ? raw['model'] as String : '',
      type: raw['type'] is String ? raw['type'] as String : '',
      inputTokens: _int(raw['input_tokens']) ?? 0,
      outputTokens: _int(raw['output_tokens']) ?? 0,
      costSats: raw['cost_sats'] is num ? raw['cost_sats'] as num : 0,
      balance: raw['balance'] is String ? raw['balance'] as String : '',
      status: raw['status'] is String ? raw['status'] as String : 'ok',
      keyId: raw['key_id'] is String ? raw['key_id'] as String : '',
      webSearch: raw['web_search'] == true,
    );
  }
}

class ApiBalance {
  const ApiBalance({this.sats, this.credits});

  final num? sats;
  final num? credits;

  static ApiBalance fromJson(Object? raw) {
    if (raw is num) return ApiBalance(sats: raw);
    if (raw is Map) {
      return ApiBalance(
        sats: raw['sats'] is num
            ? raw['sats'] as num
            : (raw['balance_sats'] is num ? raw['balance_sats'] as num : null),
        credits: raw['credits'] is num ? raw['credits'] as num : null,
      );
    }
    return const ApiBalance();
  }
}

class ApiAccount {
  const ApiAccount({
    this.pubkey = '',
    this.standard = const ApiBalance(),
    this.pro = const ApiBalance(),
    this.keysActive = 0,
  });

  final String pubkey;
  final ApiBalance standard;
  final ApiBalance pro;
  final int keysActive;

  bool get empty {
    bool none(ApiBalance b) => (b.sats ?? 0) <= 0 && (b.credits ?? 0) <= 0;
    return none(standard) && none(pro);
  }

  static ApiAccount fromJson(Object? raw) {
    if (raw is! Map) return const ApiAccount();
    final balances = raw['balances'] is Map ? raw['balances'] as Map : raw;
    return ApiAccount(
      pubkey: raw['pubkey'] is String ? raw['pubkey'] as String : '',
      standard: ApiBalance.fromJson(balances['standard']),
      pro: ApiBalance.fromJson(balances['pro']),
      keysActive: _int(raw['keys_active']) ?? 0,
    );
  }
}

class AutoTopup {
  const AutoTopup({
    this.connected = false,
    this.thresholdSats,
    this.topupSats,
    this.tier = 'pro',
    this.wallet = '',
    this.lastTopupAt,
    this.lastTopupSats,
    this.lastError,
  });

  final bool connected;
  final int? thresholdSats;
  final int? topupSats;
  final String tier;
  final String wallet;
  final DateTime? lastTopupAt;
  final int? lastTopupSats;
  final String? lastError;

  static AutoTopup fromJson(Object? raw) {
    if (raw is! Map) return const AutoTopup();
    final inner = raw['data'] is Map ? raw['data'] as Map : raw;
    final err = inner['last_error'];
    return AutoTopup(
      connected: inner['connected'] == true ||
          (inner['connected'] == null && inner['threshold_sats'] is num),
      thresholdSats: _int(inner['threshold_sats']),
      topupSats: _int(inner['topup_sats']),
      tier: inner['tier'] == 'standard' ? 'standard' : 'pro',
      wallet: inner['wallet'] is String
          ? inner['wallet'] as String
          : (inner['relay'] is String ? inner['relay'] as String : ''),
      lastTopupAt: _time(inner['last_topup_at']),
      lastTopupSats: _int(inner['last_topup_sats']),
      lastError: err is String && err.isNotEmpty ? err : null,
    );
  }
}

class ApiAccess {
  ApiAccess({required this._client, required this._signer});

  final http.Client _client;
  final EventSigner Function() _signer;

  static String sha256Hex(String body) =>
      crypto.sha256.convert(utf8.encode(body)).toString();

  static Uri url(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$kApiBaseUrl$path');
    return query == null || query.isEmpty ? u : u.replace(queryParameters: query);
  }

  Future<String> authorization(String method, Uri url, {String? body}) async {
    final signer = _signer();
    final rng = Random.secure();
    final nonce = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final event = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 27235,
      tags: [
        ['u', url.toString()],
        ['method', method],
        ['nonce', nonce],
        if (body != null) ['payload', sha256Hex(body)],
      ],
      content: '',
    ));
    return 'Nostr ${base64.encode(utf8.encode(jsonEncode(event.toJson())))}';
  }

  Future<ApiReply> send(String method, Uri url,
      {Map<String, Object?>? body, Duration? timeout, bool signed = true}) async {
    try {
      final text = body == null ? null : jsonEncode(body);
      final request = http.Request(method, url);
      if (signed) {
        request.headers['Authorization'] =
            await authorization(method, url, body: text);
      }
      request.headers['User-Agent'] = NymbotConfig.userAgent;
      request.headers['Accept'] = 'application/json';
      if (text != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = text;
      }
      final streamed = await _client
          .send(request)
          .timeout(timeout ?? const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed)
          .timeout(timeout ?? const Duration(seconds: 30));
      Object? decoded;
      try {
        decoded = resp.body.isEmpty ? null : jsonDecode(resp.body);
      } catch (_) {
        decoded = null;
      }
      return ApiReply(resp.statusCode, decoded);
    } on TimeoutException {
      return const ApiReply(0, {'error': 'timed out'});
    } catch (_) {
      return const ApiReply(0, {'error': 'network error'});
    }
  }

  Future<ApiReply> account() => send('GET', url('/account'));

  Future<ApiReply> models() =>
      send('GET', url('/models', {'type': 'all'}), signed: false);

  Future<ApiReply> listKeys() =>
      send('GET', url('/keys', {'include_revoked': 'true'}));

  Future<ApiReply> createKey({
    required String name,
    int? limitSats,
    String? resetPeriod,
    DateTime? expireAt,
  }) =>
      send('POST', url('/keys'), body: {
        'name': name,
        'limit_sats': ?limitSats,
        if (limitSats != null && resetPeriod != null) 'reset_period': resetPeriod,
        if (expireAt != null) 'expire_at': expireAt.toUtc().toIso8601String(),
      });

  Future<ApiReply> updateKey(String id, Map<String, Object?> changes) =>
      send('PATCH', url('/keys/${Uri.encodeComponent(id)}'), body: changes);

  Future<ApiReply> revokeKey(String id) =>
      send('DELETE', url('/keys/${Uri.encodeComponent(id)}'));

  Future<ApiReply> history() =>
      send('GET', url('/queries/history', {'all_keys': 'true'}));

  Future<ApiReply> autoTopup() => send('GET', url('/nwc-auto-topup'));

  Future<ApiReply> connectAutoTopup({
    required String nwcUrl,
    required int thresholdSats,
    required int topupSats,
    required String tier,
  }) =>
      send('POST', url('/nwc-auto-topup/connect'),
          body: {
            'nwc_url': nwcUrl,
            'threshold_sats': thresholdSats,
            'topup_sats': topupSats,
            'tier': tier,
          },
          timeout: const Duration(seconds: 45));

  Future<ApiReply> disconnectAutoTopup() =>
      send('DELETE', url('/nwc-auto-topup/connection'));
}
