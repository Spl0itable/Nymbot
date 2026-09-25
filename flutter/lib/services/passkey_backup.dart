import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/keys.dart';
import '../core/crypto/nip44.dart' as nip44;
import '../core/crypto/schnorr.dart' as schnorr;
import '../features/i18n/i18n.dart';
import '../models/nostr_event.dart';
import 'key_backup.dart';
import 'relay_pool.dart';

const String passkeyFormat = 'nym-passkey-backup-v1';
const String passkeyRpId = 'nymbot.ai';
const String passkeyRpName = 'Nymbot';
const String passkeyPrfContext = 'nym-key-backup-v1';
const String passkeyEncLabel = 'nym-passkey-enc';
const String passkeyLocatorLabel = 'nym-passkey-locator';
const int passkeyBackupKind = 30078;
const String passkeyBackupD = 'nym-key-backup';

const List<String> passkeyDefaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
  'wss://nostr.mom',
];

final BigInt _curveN = BigInt.parse(
  'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
  radix: 16,
);

Uint8List passkeyPrfSalt() =>
    Uint8List.fromList(crypto.sha256.convert(utf8.encode(passkeyPrfContext)).bytes);

Uint8List passkeyHkdf(Uint8List ikm, String label) => nip44.hkdfExpand(
    nip44.hkdfExtract(Uint8List(0), ikm),
    Uint8List.fromList(utf8.encode(label)),
    32);

class PasskeyKeys {
  PasskeyKeys(this.encKey, this.locatorSecret, this.locatorPubkey);
  final Uint8List encKey;
  final Uint8List locatorSecret;
  final String locatorPubkey;

  void wipe() {
    wipeBytes(encKey);
    wipeBytes(locatorSecret);
  }
}

PasskeyKeys passkeyKeys(Uint8List prfOutput) {
  final encKey = passkeyHkdf(prfOutput, passkeyEncLabel);
  final locator = passkeyHkdf(prfOutput, passkeyLocatorLabel);
  final n = BigInt.parse(bytesToHex(locator), radix: 16);
  if (n == BigInt.zero || n >= _curveN) {
    wipeBytes(encKey);
    wipeBytes(locator);
    throw BackupFailure(
        t('This passkey gave a key that can\'t be used. Try another passkey.'));
  }
  return PasskeyKeys(encKey, locator, getPublicKeyHex(locator));
}

NostrEvent passkeyLocatorEvent(String payload, Uint8List locatorSecret,
        {int? createdAt}) =>
    schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: '',
        createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: passkeyBackupKind,
        tags: const [
          ['d', passkeyBackupD],
        ],
        content: payload,
      ),
      locatorSecret,
    );

bool isPasskeyBackupEvent(NostrEvent event, String locatorPubkey) {
  if (event.kind != passkeyBackupKind || event.pubkey != locatorPubkey) {
    return false;
  }
  final tagged = event.tags
      .any((tag) => tag.length >= 2 && tag[0] == 'd' && tag[1] == passkeyBackupD);
  if (!tagged) return false;
  return schnorr.verifyEvent(event);
}

NostrEvent? newestPasskeyBackup(List<NostrEvent> events, String locatorPubkey) {
  final valid =
      events.where((e) => isPasskeyBackupEvent(e, locatorPubkey)).toList()
        ..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
  return valid.isEmpty ? null : valid.first;
}

List<String> passkeyBackupRelays() =>
    {...NymbotConfig.relays, ...passkeyDefaultRelays}.toList();

Uint8List passkeyBlobFor(Uint8List secretKey, {String? pq}) =>
    Uint8List.fromList(utf8.encode(backupPlaintext(secretKey, pq: pq)));

BackupBundle? readPasskeyBlob(Uint8List? blob) {
  if (blob == null) return null;
  final String text;
  try {
    text = utf8.decode(blob);
  } catch (_) {
    return null;
  }
  return parseBackupPlaintext(text);
}

String passkeyUserName(String pubkey) {
  final npub = bech32.encodeNpub(pubkey);
  return '$passkeyRpName key backup · ${npub.substring(0, 12)}…${npub.substring(npub.length - 6)}';
}

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _unb64u(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  } catch (_) {
    return null;
  }
}

class PasskeyResult {
  PasskeyResult({
    required this.credentialId,
    this.prf,
    this.prfEnabled = false,
    this.largeBlobSupported = false,
    this.largeBlob,
    this.largeBlobWritten = false,
  });

  factory PasskeyResult.fromJson(Map<String, dynamic> json) {
    final ext = json['clientExtensionResults'];
    final extensions = ext is Map ? ext : const {};
    final prf = extensions['prf'];
    final prfMap = prf is Map ? prf : const {};
    final results = prfMap['results'];
    final largeBlob = extensions['largeBlob'];
    final blobMap = largeBlob is Map ? largeBlob : const {};
    return PasskeyResult(
      credentialId: _unb64u(json['rawId']) ?? _unb64u(json['id']) ?? Uint8List(0),
      prf: results is Map ? _unb64u(results['first']) : null,
      prfEnabled: prfMap['enabled'] == true,
      largeBlobSupported: blobMap['supported'] == true,
      largeBlob: _unb64u(blobMap['blob']),
      largeBlobWritten: blobMap['written'] == true,
    );
  }

  final Uint8List credentialId;
  final Uint8List? prf;
  final bool prfEnabled;
  final bool largeBlobSupported;
  final Uint8List? largeBlob;
  final bool largeBlobWritten;

  void wipe() {
    wipeBytes(prf);
    wipeBytes(largeBlob);
  }
}

class PasskeyPlatform {
  PasskeyPlatform({MethodChannel? channel, bool? supported})
      : _channel = channel ?? defaultChannel,
        _supported = supported;

  static const defaultChannel = MethodChannel('ai.nymbot/passkey');

  final MethodChannel _channel;
  final bool? _supported;

  bool get _platformOk =>
      _supported ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.android));

  Future<bool> available() async {
    if (!_platformOk) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<PasskeyResult> _call(String method, Map<String, dynamic> request) async {
    Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>(method, {
        'request': jsonEncode(request),
      });
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw const BackupCancelled();
      if (e.code == 'none') throw const PasskeyNone();
      throw BackupFailure(t('Your passkey could not be used.'));
    } on MissingPluginException {
      throw BackupFailure(t('Passkeys are not available on this device.'));
    }
    if (raw is! String) throw BackupFailure(t('Your passkey could not be used.'));
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw BackupFailure(t('Your passkey could not be used.'));
    }
    if (decoded is! Map<String, dynamic>) {
      throw BackupFailure(t('Your passkey could not be used.'));
    }
    return PasskeyResult.fromJson(decoded);
  }

  Future<PasskeyResult> create({
    required Uint8List userId,
    required String userName,
    required Uint8List prfSalt,
  }) =>
      _call('create', {
        'challenge': _b64u(randomBytes(32)),
        'rp': {'id': passkeyRpId, 'name': passkeyRpName},
        'user': {'id': _b64u(userId), 'name': userName, 'displayName': userName},
        'pubKeyCredParams': [
          {'type': 'public-key', 'alg': -7},
          {'type': 'public-key', 'alg': -257},
        ],
        'authenticatorSelection': {
          'residentKey': 'required',
          'requireResidentKey': true,
          'userVerification': 'required',
        },
        'timeout': 60000,
        'extensions': {
          'prf': {
            'eval': {'first': _b64u(prfSalt)},
          },
          'largeBlob': {'support': 'preferred'},
        },
      });

  Future<PasskeyResult> get({
    Uint8List? credentialId,
    Uint8List? prfSalt,
    bool largeBlobRead = false,
    Uint8List? largeBlobWrite,
  }) =>
      _call('get', {
        'challenge': _b64u(randomBytes(32)),
        'rpId': passkeyRpId,
        'allowCredentials': [
          if (credentialId != null) {'type': 'public-key', 'id': _b64u(credentialId)},
        ],
        'userVerification': 'required',
        'timeout': 60000,
        'extensions': {
          if (prfSalt != null)
            'prf': {
              'eval': {'first': _b64u(prfSalt)},
            },
          if (largeBlobWrite != null)
            'largeBlob': {'write': _b64u(largeBlobWrite)}
          else if (largeBlobRead)
            'largeBlob': {'read': true},
        },
      });
}

class PasskeyNone implements Exception {
  const PasskeyNone();
}

class PasskeyUnsupported implements Exception {
  const PasskeyUnsupported();
}

class PasskeyNotFound implements Exception {
  const PasskeyNotFound();
}

class PasskeyOtherKey implements Exception {
  const PasskeyOtherKey();
}

typedef PasskeyProgress = void Function(String text);

class PasskeyBackup {
  PasskeyBackup({required this.relays, PasskeyPlatform? platform})
      : platform = platform ?? PasskeyPlatform();

  final RelayPool relays;
  final PasskeyPlatform platform;

  Future<bool> available() => platform.available();

  Future<String> backUp(Uint8List secretKey,
      {String? pq, PasskeyProgress? progress}) async {
    final step = progress ?? (_) {};
    final salt = passkeyPrfSalt();
    final made = await platform.create(
      userId: randomBytes(16),
      userName: passkeyUserName(getPublicKeyHex(secretKey)),
      prfSalt: salt,
    );
    var output = made.prf;
    try {
      if (output == null && made.prfEnabled) {
        step(t('Confirm with your passkey once more…'));
        final again =
            await platform.get(credentialId: made.credentialId, prfSalt: salt);
        output = again.prf;
        wipeBytes(again.largeBlob);
      }
      if (output != null) {
        final keys = passkeyKeys(output);
        try {
          step(t('Saving the encrypted copy to Nostr relays…'));
          await _publish(keys, secretKey, pq);
        } finally {
          keys.wipe();
        }
        return 'prf';
      }
      if (made.largeBlobSupported) {
        step(t('Confirm with your passkey once more to save the backup in it…'));
        await _writeBlob(made.credentialId, secretKey, pq);
        return 'largeBlob';
      }
      throw const PasskeyUnsupported();
    } finally {
      wipeBytes(output);
      made.wipe();
    }
  }

  Future<String> update(Uint8List secretKey,
      {String? pq, PasskeyProgress? progress}) async {
    final step = progress ?? (_) {};
    final pubkey = getPublicKeyHex(secretKey);
    final got = await platform.get(prfSalt: passkeyPrfSalt(), largeBlobRead: true);
    try {
      final output = got.prf;
      if (output != null) {
        final keys = passkeyKeys(output);
        try {
          step(t('Looking for your encrypted key on Nostr relays…'));
          final held = await _find(keys);
          final bundle = held.bundle;
          final same = bundle != null && getPublicKeyHex(bundle.secret) == pubkey;
          bundle?.wipe();
          if (same) {
            step(t('Saving the encrypted copy to Nostr relays…'));
            await _publish(keys, secretKey, pq, after: held.createdAt);
            return 'prf';
          }
        } finally {
          keys.wipe();
        }
      }
      final blob = readPasskeyBlob(got.largeBlob);
      if (blob != null) {
        final same = getPublicKeyHex(blob.secret) == pubkey;
        blob.wipe();
        if (same) {
          step(t('Confirm with your passkey once more to save the backup in it…'));
          await _writeBlob(got.credentialId, secretKey, pq);
          return 'largeBlob';
        }
      }
    } finally {
      got.wipe();
    }
    throw const PasskeyOtherKey();
  }

  Future<void> _writeBlob(Uint8List credentialId, Uint8List secretKey, String? pq) async {
    final blob = passkeyBlobFor(secretKey, pq: pq);
    try {
      final written =
          await platform.get(credentialId: credentialId, largeBlobWrite: blob);
      if (!written.largeBlobWritten) {
        throw BackupFailure(t('The passkey did not save the backup. Try again, '
            'or use another passkey provider.'));
      }
    } finally {
      wipeBytes(blob);
    }
  }

  Future<void> _publish(PasskeyKeys keys, Uint8List secretKey, String? pq,
      {int? after}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final event = passkeyLocatorEvent(
        encryptBackup(secretKey, keys.encKey, pq: pq), keys.locatorSecret,
        createdAt: after != null && after >= now ? after + 1 : now);
    final results = await Future.wait([
      relays.publish(event, timeout: const Duration(seconds: 8)),
      relays.publishTo(passkeyBackupRelays(), event,
          timeout: const Duration(seconds: 8)),
    ]);
    if (results[0] + results[1] < 1) {
      throw BackupFailure(t('No relay accepted the encrypted copy. Check your '
          'connection and try again.'));
    }
  }

  Future<({BackupBundle? bundle, int? createdAt})> _find(PasskeyKeys keys) async {
    final filter = {
      'kinds': [passkeyBackupKind],
      'authors': [keys.locatorPubkey],
      '#d': [passkeyBackupD],
    };
    final found = await Future.wait([
      relays.fetch(filter, timeout: const Duration(seconds: 8)),
      relays.fetchFrom(
          passkeyBackupRelays()
              .where((u) => !NymbotConfig.relays.contains(u))
              .toList(),
          filter,
          timeout: const Duration(seconds: 8)),
    ]);
    final newest =
        newestPasskeyBackup([...found[0], ...found[1]], keys.locatorPubkey);
    if (newest == null) return (bundle: null, createdAt: null);
    return (
      bundle: decryptBackup(newest.content, keys.encKey),
      createdAt: newest.createdAt,
    );
  }

  Future<BackupBundle> restore({PasskeyProgress? progress}) async {
    final step = progress ?? (_) {};
    final got = await platform.get(prfSalt: passkeyPrfSalt(), largeBlobRead: true);
    BackupBundle? bundle;
    try {
      final output = got.prf;
      if (output != null) {
        final keys = passkeyKeys(output);
        try {
          step(t('Looking for your encrypted key on Nostr relays…'));
          bundle = (await _find(keys)).bundle;
        } finally {
          keys.wipe();
        }
      }
      bundle ??= readPasskeyBlob(got.largeBlob);
    } finally {
      got.wipe();
    }
    if (bundle == null) throw const PasskeyNotFound();
    return bundle;
  }
}
