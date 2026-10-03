import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/keys.dart';
import '../models/nostr_event.dart';
import '../models/notice.dart';
import '../features/i18n/i18n.dart';
import 'nostr/event_signer.dart';
import 'server_runs.dart';
import 'signed_body.dart';

typedef ApiResult = ({int status, Map<String, dynamic> data});

/// Nymbot worker client; each request carries a kind-27235 auth event bound to endpoint, method and action.
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
    'git-branch',
    'mcp-probe',
    'runner-run',
    'site-check',
    'gift-create',
    'gift-redeem',
    'gift-cancel',
    'schedule-put',
    'pm-answer',
    'pr-watch-put',
    'pr-watch-stop',
    'pr-watch-fix',
  };

  final http.Client _client;

  http.Client get client => _client;

  final Map<String, NostrEvent> _authCache = {};

  static const _busyStatus = {429, 503, 529};
  static final _busyText = RegExp(
      r'rate[- ]?limit|too many requests|overloaded|over capacity|no capacity'
      r'|try again later|temporarily unavailable',
      caseSensitive: false);

  static bool busy(int status, Map<String, dynamic> data) {
    if (data['priceUnavailable'] == true) return false;
    if (_busyStatus.contains(status)) return true;
    final text = data['error'] ?? data['message'];
    return text is String && _busyText.hasMatch(text);
  }

  static String priceUnavailableText() => t(
      'Nymbot could not check the bitcoin price just now, so nothing was sent or charged. Try again in a minute.');

  static Map<String, dynamic> priced(Map<String, dynamic> data) {
    if (data['priceUnavailable'] != true) return data;
    return {...data, 'error': priceUnavailableText(), 'retryable': true};
  }

  bool offline = false;

  static const aborted = <String, dynamic>{'error': 'aborted', 'aborted': true};

  static bool signsFresh(String action) => _money.contains(action);

  Future<NostrEvent> _auth(String action, EventSigner signer, String payload) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = '$action|${signer.pubkey}|$payload';
    final fresh = _money.contains(action);
    if (!fresh) {
      final hit = _authCache[key];
      // Well inside the worker's 120s window.
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

  /// Deletes this account's server rows; signed while the key is still here.
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
    Future<void>? abort,
  }) async {
    var stopped = false;
    unawaited(abort?.whenComplete(() => stopped = true));
    try {
      final body = await signedBody(action, signer, extra);
      if (stopped) return (status: -1, data: {...aborted});
      final request = abort == null
          ? http.Request('POST', Uri.parse(NymbotConfig.botUrl))
          : http.AbortableRequest('POST', Uri.parse(NymbotConfig.botUrl),
              abortTrigger: abort);
      request
        ..headers['Content-Type'] = 'application/json'
        ..headers['User-Agent'] = NymbotConfig.userAgent
        ..body = body;
      Future<http.Response> post() async =>
          http.Response.fromStream(await _client.send(request));
      final sent = post().timeout(timeout ?? const Duration(seconds: 30));
      final resp = abort == null
          ? await sent
          : await Future.any([
              sent,
              abort.then<http.Response>(
                  (_) => throw http.RequestAbortedException(request.url)),
            ]);
      offline = false;
      final decoded = jsonDecode(resp.body);
      return (
        status: resp.statusCode,
        data: priced(
            decoded is Map<String, dynamic> ? decoded : <String, dynamic>{})
      );
    } on TimeoutException {
      if (stopped) return (status: -1, data: {...aborted});
      return (status: 0, data: {'error': 'timed out', 'timedOut': true});
    } on http.RequestAbortedException {
      return (status: -1, data: {...aborted});
    } on FormatException {
      return (status: 0, data: {'error': 'network error'});
    } catch (_) {
      if (stopped) return (status: -1, data: {...aborted});
      offline = true;
      return (status: 0, data: {'error': 'network error'});
    }
  }

  Future<ApiResult> siteCheck(EventSigner signer, Map<String, dynamic> extra) =>
      call('site-check', signer, extra: extra, timeout: const Duration(seconds: 150));

  Future<ApiResult> cancelRun(EventSigner signer, String runId) =>
      call('pm-cancel', signer,
          extra: {'replyTo': runId}, timeout: const Duration(seconds: 10));

  Future<ApiResult> steerRun(EventSigner signer, String runId, String text) =>
      call('pm-steer', signer,
          extra: {'replyTo': runId, 'text': text},
          timeout: const Duration(seconds: 15));

  Future<ApiResult> steerStatus(EventSigner signer, List<String> ids) =>
      call('pm-steer-status', signer,
          extra: {'ids': ids}, timeout: const Duration(seconds: 15));

  Future<ApiResult> claimRun(EventSigner signer, String eventId) =>
      call('pm-claim', signer,
          extra: {'eventId': eventId}, timeout: const Duration(seconds: 20));

  Future<ApiResult> liveRuns(EventSigner signer, {String? thread, String? log}) =>
      call('pm-runs', signer,
          extra: {'thread': ?thread, 'log': ?log},
          timeout: const Duration(seconds: 15));

  Future<ApiResult> doneSince(EventSigner signer, int since, {String? log}) =>
      call('pm-done-since', signer,
          extra: {'since': since, 'log': ?log}, timeout: const Duration(seconds: 20));

  Future<ApiResult> schedulePut(
          EventSigner signer, Map<String, dynamic> schedule) =>
      call('schedule-put', signer,
          extra: {'schedule': schedule}, timeout: const Duration(seconds: 20));

  Future<ApiResult> scheduleDelete(EventSigner signer, String id) =>
      call('schedule-delete', signer,
          extra: {'id': id}, timeout: const Duration(seconds: 20));

  Future<ApiResult> scheduleClear(EventSigner signer) =>
      call('schedule-clear', signer, timeout: const Duration(seconds: 20));

  Future<ApiResult> answer(EventSigner signer, String runId, String pendingId,
          {List<Map<String, dynamic>>? answers, bool skipped = false, String? decision, Map<String, dynamic>? edits}) =>
      call('pm-answer', signer,
          extra: {
            'runId': runId,
            'pendingId': pendingId,
            if (decision != null) 'decision': decision
            else if (skipped) 'skipped': true
            else 'answers': answers ?? const [],
            'edits': ?edits,
          },
          timeout: const Duration(seconds: 20));

  Future<ApiResult> prWatchPut(EventSigner signer, Map<String, dynamic> body) =>
      call('pr-watch-put', signer, extra: body, timeout: const Duration(seconds: 20));

  Future<ApiResult> prWatchStop(EventSigner signer, String id) =>
      call('pr-watch-stop', signer,
          extra: {'id': id}, timeout: const Duration(seconds: 20));

  Future<ApiResult> prWatchList(EventSigner signer) =>
      call('pr-watch-list', signer, timeout: const Duration(seconds: 20));

  Future<ApiResult> prWatchPeek(EventSigner signer, Map<String, dynamic> git, Map<String, dynamic> watch) =>
      call('pr-watch-peek', signer,
          extra: {'git': git, 'watch': watch}, timeout: const Duration(seconds: 20));

  Future<ApiResult> prWatchFix(EventSigner signer, String id, int seq) =>
      call('pr-watch-fix', signer,
          extra: {'id': id, 'seq': seq}, timeout: const Duration(seconds: 20));

  Future<ApiResult> scheduleList(EventSigner signer) =>
      call('schedule-list', signer, timeout: const Duration(seconds: 20));

  Future<ApiResult> balance(EventSigner signer) => call('balance', signer);

  Future<ApiResult> clearHistory(EventSigner signer) =>
      call('clear-history', signer);

  /// Public catalog; the one call that needs no identity.
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

  Future<Map<String, dynamic>?> pqKey(String pubkey) async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'pq-key', 'pubkey': pubkey}),
          )
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      final event = decoded['event'];
      return event is Map<String, dynamic> ? event : null;
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
        data: priced(
            decoded is Map<String, dynamic> ? decoded : <String, dynamic>{})
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
        error: decoded is Map<String, dynamic> ? priced(decoded) : {'error': 'The request failed.'},
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
        'recipientPubkey': ?recipientPubkey,
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

  Future<ApiResult> voucherKeys() async {
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'voucher-keys'}),
          )
          .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(resp.body);
      return (
        status: resp.statusCode,
        data: priced(
            decoded is Map<String, dynamic> ? decoded : <String, dynamic>{})
      );
    } on TimeoutException {
      return (status: 0, data: {'error': 'timed out'});
    } catch (_) {
      return (status: 0, data: {'error': 'network error'});
    }
  }

  Future<ApiResult> voucherIssue(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-issue', signer, extra: payload);

  Future<ApiResult> voucherRedeem(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-redeem', signer, extra: payload);
}
