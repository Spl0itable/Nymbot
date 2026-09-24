import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../features/i18n/i18n.dart';
import '../../models/nostr_event.dart';
import 'event_signer.dart';

typedef SignerApp = ({String package, String name});

const List<Map<String, Object>> nip55Permissions = [
  {'type': 'sign_event', 'kind': 27235},
  {'type': 'sign_event', 'kind': 13},
  {'type': 'sign_event', 'kind': 30078},
  {'type': 'sign_event', 'kind': 1},
  {'type': 'nip44_encrypt'},
  {'type': 'nip44_decrypt'},
];

class Nip55Signer implements RemoteSigner {
  Nip55Signer._(this.package, this._pubkey);

  static const channel = MethodChannel('ai.nymbot/signer');

  final String package;
  final String _pubkey;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  String get pubkey => _pubkey;

  @override
  bool get isRemote => true;

  @override
  String get method => 'nip55';

  @override
  Map<String, dynamic> get session =>
      {'method': 'nip55', 'package': package, 'pubkey': _pubkey};

  static Nip55Signer? restore(Map<String, dynamic> session) {
    final package = session['package'];
    final pubkey = session['pubkey'];
    if (package is! String || package.isEmpty) return null;
    if (pubkey is! String || !_isKey(pubkey)) return null;
    return Nip55Signer._(package, pubkey);
  }

  static Future<List<SignerApp>> apps() async {
    if (!supported) return const [];
    try {
      final found = await channel.invokeListMethod<Object?>('apps') ?? const [];
      return [
        for (final item in found)
          if (item is Map && item['package'] is String)
            (
              package: item['package'] as String,
              name: (item['name'] as String?) ?? item['package'] as String,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<Nip55Signer> connect({String? package}) async {
    final reply = await _call('getPublicKey', {
      'package': package,
      'permissions': jsonEncode(nip55Permissions),
    });
    final raw = ((reply['result'] ?? reply['pubkey']) as String? ?? '').trim();
    final hex = raw.startsWith('npub1') ? _npubHex(raw) : raw.toLowerCase();
    final chosen = (reply['package'] as String?) ?? package;
    if (hex == null || !_isKey(hex)) {
      throw SignerFailure(t('The signer app returned a public key that is not valid.'));
    }
    if (chosen == null || chosen.isEmpty) {
      throw SignerFailure(t('The signer app did not say which app it is.'));
    }
    return Nip55Signer._(chosen, hex);
  }

  static String? _npubHex(String npub) {
    try {
      return bech32.decodeNpub(npub);
    } catch (_) {
      return null;
    }
  }

  static bool _isKey(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static Future<Map<String, Object?>> _call(
      String method, Map<String, Object?> args) async {
    if (!supported) {
      throw SignerFailure(t('Signer apps are only available on Android.'));
    }
    try {
      final reply = await channel.invokeMapMethod<String, Object?>(method, args);
      if (reply == null) {
        throw SignerFailure(t('The signer app did not answer.'));
      }
      return reply;
    } on PlatformException catch (e) {
      throw SignerFailure(switch (e.code) {
        'rejected' => t('Your signer app declined the request.'),
        'unavailable' => t('No signer app is installed that can do this.'),
        _ => t('The signer app did not answer.'),
      });
    } on MissingPluginException {
      throw SignerFailure(t('Signer apps are only available on Android.'));
    }
  }

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) async {
    final asked = UnsignedEvent(
      pubkey: _pubkey,
      createdAt: unsigned.createdAt,
      kind: unsigned.kind,
      tags: unsigned.tags,
      content: unsigned.content,
    );
    final id = asked.computeId();
    final reply = await _call('signEvent', {
      'package': package,
      'event': jsonEncode({'id': id, ...asked.toJson()}),
      'id': id,
      'current': _pubkey,
    });
    NostrEvent signed;
    final event = reply['event'];
    if (event is String && event.isNotEmpty) {
      try {
        signed = NostrEvent.fromJson(jsonDecode(event) as Map<String, dynamic>);
      } catch (_) {
        throw SignerFailure(t('Your signer returned something that is not a signed event.'));
      }
    } else {
      final sig = reply['result'];
      if (sig is! String || sig.isEmpty) {
        throw SignerFailure(t('Your signer returned something that is not a signed event.'));
      }
      signed = NostrEvent(
        id: id,
        pubkey: _pubkey,
        createdAt: asked.createdAt,
        kind: asked.kind,
        tags: asked.tags,
        content: asked.content,
        sig: sig,
      );
    }
    return checkSigned(asked, signed, _pubkey);
  }

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) async {
    final reply = await _call('nip44Encrypt', {
      'package': package,
      'text': plaintext,
      'peer': peerPubkey,
      'current': _pubkey,
    });
    final result = reply['result'];
    if (result is! String || result.isEmpty) {
      throw SignerFailure(t('Your signer could not encrypt that.'));
    }
    return result;
  }

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) async {
    final reply = await _call('nip44Decrypt', {
      'package': package,
      'text': ciphertext,
      'peer': peerPubkey,
      'current': _pubkey,
    });
    final result = reply['result'];
    if (result is! String) {
      throw SignerFailure(t('Your signer could not decrypt that.'));
    }
    return result;
  }

  @override
  Future<void> close() async {}
}
