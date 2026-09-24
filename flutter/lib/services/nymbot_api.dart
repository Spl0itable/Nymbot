import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/keys.dart';
import '../models/nostr_event.dart';
import '../models/notice.dart';
import 'nostr/event_signer.dart';
import 'server_runs.dart';
import 'signed_body.dart';

typedef ApiResult = ({int status, Map<String, dynamic> data});

/// The Nymbot worker client.
///
/// Every request carries a kind-27235 auth event bound to this endpoint, method
/// and action, so a captured signature cannot be replayed against a different
/// one. The money actions are signed fresh each time; the worker enforces
/// single-use for those.
class NymbotApi {
  NymbotApi({http.Client? client}) : _client = client ?? http.Client();

  static const _money = {
    'transfer-credits',
    'create-invoice',
    'claim-credits',
    'clear-history',
    'voucher-issue',
    'voucher-redeem',
    'pm-revert',
    'git-apply',
    'mcp-probe',
    'runner-run',
    'gift-create',
    'gift-redeem',
    'gift-cancel',
  };

  final http.Client _client;
  final Map<String, NostrEvent> _authCache = {};

  static const _serial = {'pm'};

  static const _busyStatus = {429, 503, 529};
  static final _busyText = RegExp(
      r'rate[- ]?limit|too many requests|overloaded|over capacity|no capacity'
      r'|try again later|temporarily unavailable',
      caseSensitive: false);

  static bool busy(int status, Map<String, dynamic> data) {
    if (_busyStatus.contains(status)) return true;
    final text = data['error'] ?? data['message'];
    return text is String && _busyText.hasMatch(text);
  }

  Future<void> _gate = Future<void>.value();

  Future<ApiResult> _queued(Future<ApiResult> Function() run) {
    final mine = _gate.then((_) => run(), onError: (_) => run());
    _gate = mine.then((_) {}, onError: (_) {});
    return mine;
  }

  static bool signsFresh(String action) => _money.contains(action);

  Future<NostrEvent> _auth(String action, EventSigner signer, String payload) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = '$action|${signer.pubkey}|$payload';
    final fresh = _money.contains(action);
    if (!fresh) {
      final hit = _authCache[key];
      // Well inside the worker's 120s window, so an edge-of-window reject is
      // not something a cached signature can cause.
      if (hit != null && nowSec - hit.createdAt < 90) return hit;
    }
    final signed = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: nowSec,
      kind: 27235,
      tags: [
        const ['domain', 'nymbot-pm'],
        const ['method', 'POST'],
        ['u', NymbotConfig.botUrl],
        ['action', action],
        ['payload', payload],
        if (fresh) ['nonce', bytesToHex(randomBytes(16))],
      ],
      content: 'nymbot-pm-auth',
    ));
    if (!fresh) {
      _authCache.removeWhere((_, held) => nowSec - held.createdAt >= 90);
      _authCache[key] = signed;
    }
    return signed;
  }

  Future<String> signedBody(String action, EventSigner signer, Map<String, dynamic> extra) async {
    final text = SignedBody.text({'action': action, 'pubkey': signer.pubkey, ...extra});
    final auth = await _auth(action, signer, SignedBody.hash(text));
    return SignedBody.withAuth(text, auth.toJson());
  }

  /// Deletes this account's Nymbot rows on the server, on the way out of a
  /// wipe. Signed while the key is still here; the worker verifies the
  /// signature, so nobody can purge a pubkey they do not hold.
  Future<bool> purgeAccount(EventSigner signer, {Duration? timeout}) async {
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final text = SignedBody.text({
        'action': 'account-purge',
        'app': 'nymbot',
        'pubkey': signer.pubkey,
      });
      final auth = await signer.sign(UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: nowSec,
        kind: 27235,
        tags: [
          const ['domain', 'nymbot-sync'],
          const ['method', 'POST'],
          ['u', NymbotConfig.storageUrl],
          const ['action', 'account-purge'],
          ['payload', SignedBody.hash(text)],
        ],
        content: 'nymbot-sync-auth',
      ));
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.storageUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: SignedBody.withAuth(text, auth.toJson()),
          )
          .timeout(timeout ?? const Duration(seconds: 5));
      final decoded = jsonDecode(resp.body);
      return decoded is Map && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<ApiResult> call(
    String action,
    EventSigner signer, {
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  }) {
    Future<ApiResult> attempt() =>
        _call(action, signer, extra: extra, timeout: timeout);
    return _serial.contains(action) ? _queued(attempt) : attempt();
  }

  Future<ApiResult> _call(
    String action,
    EventSigner signer, {
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  }) async {
    try {
      final body = await signedBody(action, signer, extra);
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: body,
          )
          .timeout(timeout ?? const Duration(seconds: 30));
      final decoded = jsonDecode(resp.body);
      return (
        status: resp.statusCode,
        data: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{}
      );
    } on TimeoutException {
      return (status: 0, data: {'error': 'timed out'});
    } catch (_) {
      return (status: 0, data: {'error': 'network error'});
    }
  }

  Future<ApiResult> balance(EventSigner signer) => call('balance', signer);

  Future<ApiResult> clearHistory(EventSigner signer) =>
      call('clear-history', signer);

  /// Public catalog data: it has to render before anyone has a balance, so it
  /// is the one call that needs no identity.
  Future<Map<String, dynamic>?> models() async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'models'}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic> || decoded['models'] == null) {
        return null;
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<ApiResult> teamEstimate(Map<String, dynamic> body) async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'team-estimate', ...body}),
          )
          .timeout(const Duration(seconds: 20));
      Object? decoded;
      try {
        decoded = jsonDecode(resp.body);
      } catch (_) {
        decoded = null;
      }
      return (
        status: resp.statusCode,
        data: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{}
      );
    } catch (_) {
      return (status: 0, data: <String, dynamic>{'error': 'network error'});
    }
  }

  Future<RunnerInfo> runnerInfo() async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'runner-info'}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return const RunnerInfo();
      return RunnerInfo.fromJson(jsonDecode(resp.body));
    } catch (_) {
      return const RunnerInfo();
    }
  }

  Future<ServerRunResponse> runnerRun(EventSigner signer, Map<String, dynamic> extra) async {
    try {
      final request = http.Request('POST', Uri.parse(NymbotConfig.botUrl))
        ..headers['Content-Type'] = 'application/json'
        ..headers['User-Agent'] = NymbotConfig.userAgent
        ..body = await signedBody('runner-run', signer, extra);
      final resp = await _client.send(request).timeout(const Duration(seconds: 60));
      final type = resp.headers['content-type'] ?? '';
      if (resp.statusCode == 200 && type.contains('ndjson')) {
        final events = resp.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map(ServerRuns.decodeLine)
            .where((e) => e != null)
            .cast<ServerRunEvent>();
        return ServerRunResponse(status: 200, events: events);
      }
      final text = await resp.stream.bytesToString().timeout(const Duration(seconds: 30));
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
      return ServerRunResponse(
        status: resp.statusCode == 200 ? 502 : resp.statusCode,
        error: decoded is Map<String, dynamic> ? decoded : {'error': 'The request failed.'},
      );
    } on TimeoutException {
      return const ServerRunResponse(status: 0, error: {'error': 'timed out'});
    } catch (_) {
      return const ServerRunResponse(status: 0, error: {'error': 'network error'});
    }
  }

  Future<List<Notice>> notices({String platform = 'app'}) async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'notices', 'platform': platform}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return const [];
      final decoded = jsonDecode(resp.body);
      final list = decoded is Map ? decoded['notices'] : null;
      if (list is! List) return const [];
      return list.map(Notice.fromJson).whereType<Notice>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<ApiResult> createInvoice(
    EventSigner signer, {
    required int amountSats,
    required String tier,
    String? recipientPubkey,
  }) =>
      call('create-invoice', signer, extra: {
        'amountSats': amountSats,
        'tier': tier,
        if (recipientPubkey != null) 'recipientPubkey': recipientPubkey,
      });

  Future<ApiResult> checkInvoice(EventSigner signer, String invoiceId) =>
      call('check-invoice', signer, extra: {'invoiceId': invoiceId});

  Future<ApiResult> claimCredits(EventSigner signer, String invoiceId) =>
      call('claim-credits', signer, extra: {'invoiceId': invoiceId});

  Future<ApiResult> transferCredits(EventSigner signer, String targetPubkey) =>
      call('transfer-credits', signer, extra: {'targetPubkey': targetPubkey});

  Future<ApiResult> giftCreate(EventSigner signer,
          {required String tier, required int amount, required String code}) =>
      call('gift-create', signer,
          extra: {'tier': tier, 'amount': amount, 'code': code});

  Future<ApiResult> giftRedeem(EventSigner signer, String code) =>
      call('gift-redeem', signer, extra: {'code': code});

  Future<ApiResult> giftCancel(EventSigner signer, String id) =>
      call('gift-cancel', signer, extra: {'id': id});

  Future<ApiResult> giftList(EventSigner signer) => call('gift-list', signer);

  Future<ApiResult> giftPeek(EventSigner signer, String code) =>
      call('gift-peek', signer, extra: {'code': code});

  Future<ApiResult> voucherKeys(EventSigner signer) =>
      call('voucher-keys', signer);

  Future<ApiResult> voucherIssue(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-issue', signer, extra: payload);

  Future<ApiResult> voucherRedeem(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-redeem', signer, extra: payload);
}
