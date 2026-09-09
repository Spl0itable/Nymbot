import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';

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
  };

  final http.Client _client;
  final Map<String, NostrEvent> _authCache = {};

  Future<NostrEvent> _auth(String action, EventSigner signer) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = '$action|${signer.pubkey}';
    if (!_money.contains(action)) {
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
      ],
      content: 'nymbot-pm-auth',
    ));
    if (!_money.contains(action)) _authCache[key] = signed;
    return signed;
  }

  /// Deletes this account's Nymbot rows on the server, on the way out of a
  /// wipe. Signed while the key is still here; the worker verifies the
  /// signature, so nobody can purge a pubkey they do not hold.
  Future<bool> purgeAccount(EventSigner signer, {Duration? timeout}) async {
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final auth = await signer.sign(UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: nowSec,
        kind: 27235,
        tags: [
          const ['domain', 'nymbot-sync'],
          const ['method', 'POST'],
          ['u', NymbotConfig.storageUrl],
          const ['action', 'account-purge'],
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
            body: jsonEncode({
              'action': 'account-purge',
              'app': 'nymbot',
              'pubkey': signer.pubkey,
              'auth': auth.toJson(),
            }),
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
  }) async {
    try {
      final auth = await _auth(action, signer);
      final body = <String, dynamic>{
        'action': action,
        'pubkey': signer.pubkey,
        'auth': auth.toJson(),
        ...extra,
      };
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.botUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode(body),
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
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'action': 'models'}),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
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

  Future<ApiResult> voucherKeys(EventSigner signer) =>
      call('voucher-keys', signer);

  Future<ApiResult> voucherIssue(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-issue', signer, extra: payload);

  Future<ApiResult> voucherRedeem(
          EventSigner signer, Map<String, dynamic> payload) =>
      call('voucher-redeem', signer, extra: payload);
}
