import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config.dart';
import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/keys.dart';
import '../core/crypto/nip44.dart' as nip44;
import '../features/i18n/i18n.dart';

enum BackupProvider { google, apple }

extension BackupProviderInfo on BackupProvider {
  String get context => switch (this) {
        BackupProvider.google => 'nym-google-backup',
        BackupProvider.apple => 'nym-apple-backup',
      };

  String get label => switch (this) {
        BackupProvider.google => 'Google',
        BackupProvider.apple => 'Apple',
      };
}

const int backupIterations = 600000;
const String backupFormat = 'nym-key-backup-v1';

final RegExp _pinPattern = RegExp(r'^[0-9]{4,8}$');
final RegExp _secretPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp backupFilePattern = RegExp(r'^nym_bk_[0-9a-f-]{36}\.bin$');
final RegExp backupItemPattern = RegExp(r'^nym_bk_[0-9a-f-]{36}$');

bool isValidBackupPin(String pin) => _pinPattern.hasMatch(pin);

Uint8List backupSalt(String context, String accountId) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, utf8.encode(context))
        .convert(utf8.encode(accountId))
        .bytes);

Future<Uint8List> deriveBackupKeyNow(String pin, Uint8List salt) async {
  if (!isValidBackupPin(pin)) throw ArgumentError('pin');
  final pbkdf2 = DartPbkdf2(
    macAlgorithm: DartHmac.sha256(),
    iterations: backupIterations,
    bits: 256,
  );
  final key = await pbkdf2.deriveKeyFromPassword(password: pin, nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

Future<Uint8List> _deriveInIsolate(({String pin, Uint8List salt}) input) =>
    deriveBackupKeyNow(input.pin, input.salt);

typedef BackupKeyDeriver = Future<Uint8List> Function(
    BackupProvider provider, String accountId, String pin);

Future<Uint8List> deriveBackupKey(
    BackupProvider provider, String accountId, String pin) {
  if (!isValidBackupPin(pin)) throw ArgumentError('pin');
  final salt = backupSalt(provider.context, accountId);
  return compute(_deriveInIsolate, (pin: pin, salt: salt));
}

class BackupBundle {
  BackupBundle(this.secret, {this.pq});
  final Uint8List secret;
  final String? pq;

  void wipe() => wipeBytes(secret);
}

String backupPlaintext(Uint8List secretKey, {String? pq}) => jsonEncode({
      'v': 1,
      'sk': bytesToHex(secretKey),
      if (pq != null && pq.isNotEmpty) 'pq': pq,
    });

BackupBundle? parseBackupPlaintext(String text) {
  if (_secretPattern.hasMatch(text)) return BackupBundle(hexToBytes(text));
  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (parsed is! Map || parsed['v'] != 1) return null;
  final sk = parsed['sk'];
  if (sk is! String || !_secretPattern.hasMatch(sk)) return null;
  final pq = parsed['pq'];
  return BackupBundle(hexToBytes(sk),
      pq: pq is String && pq.isNotEmpty ? pq : null);
}

String encryptBackup(Uint8List secretKey, Uint8List key,
        {String? pq, Uint8List? nonce}) =>
    nip44.encrypt(backupPlaintext(secretKey, pq: pq), key, nonce: nonce);

BackupBundle? decryptBackup(String payload, Uint8List key) {
  try {
    return parseBackupPlaintext(nip44.decrypt(payload.trim(), key));
  } catch (_) {
    return null;
  }
}

void wipeBytes(Uint8List? bytes) {
  if (bytes == null) return;
  bytes.fillRange(0, bytes.length, 0);
}

String uuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = bytesToHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

String newBackupFileName() => 'nym_bk_${uuidV4()}.bin';

String newBackupItemName() => 'nym_bk_${uuidV4()}';

String? subFromIdToken(String? idToken) {
  if (idToken == null) return null;
  final parts = idToken.split('.');
  if (parts.length < 2) return null;
  try {
    final body = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final sub = body is Map ? body['sub'] : null;
    return sub is String && sub.isNotEmpty ? sub : null;
  } catch (_) {
    return null;
  }
}

class BackupCancelled implements Exception {
  const BackupCancelled();
}

class BackupFailure implements Exception {
  const BackupFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class StoredBackup {
  const StoredBackup(this.id, this.payload);
  final String id;
  final String payload;
}

class BackupCandidate {
  BackupCandidate(this.secret, this.pubkey, this.ids, {this.pq});
  final Uint8List secret;
  final String pubkey;
  final List<String> ids;
  String? pq;

  String get npub => bech32.encodeNpub(pubkey);

  String get shortNpub {
    final full = npub;
    if (full.length <= 24) return full;
    return '${full.substring(0, 12)}…${full.substring(full.length - 8)}';
  }

  void wipe() => wipeBytes(secret);
}

List<BackupCandidate> openBackups(List<StoredBackup> backups, Uint8List key) {
  final byPubkey = <String, BackupCandidate>{};
  for (final backup in backups) {
    final bundle = decryptBackup(backup.payload, key);
    if (bundle == null) continue;
    final secret = bundle.secret;
    final String pubkey;
    try {
      pubkey = getPublicKeyHex(secret);
    } catch (_) {
      wipeBytes(secret);
      continue;
    }
    final seen = byPubkey[pubkey];
    if (seen != null) {
      seen.ids.add(backup.id);
      seen.pq ??= bundle.pq;
      wipeBytes(secret);
    } else {
      byPubkey[pubkey] =
          BackupCandidate(secret, pubkey, [backup.id], pq: bundle.pq);
    }
  }
  return byPubkey.values.toList();
}

abstract class BackupStore {
  BackupProvider get provider;
  Future<String> signIn();
  Future<List<StoredBackup>> readAll();
  Future<void> write(String payload);
  Future<void> delete(String id);
  Future<void> signOut();
}

class DriveFile {
  const DriveFile(this.id, this.name, this.modifiedTime);
  final String id;
  final String name;
  final String? modifiedTime;
}

typedef AccessTokenSource = Future<String> Function({bool refresh});

class DriveAppData {
  DriveAppData(this._token, {http.Client? client})
      : _client = client ?? http.Client();

  static const host = 'www.googleapis.com';

  final AccessTokenSource _token;
  final http.Client _client;

  Future<http.Response> _send(
      Future<http.Response> Function(Map<String, String> auth) request) async {
    var token = await _token();
    var res = await request({'Authorization': 'Bearer $token'});
    if (res.statusCode != 401) return res;
    token = await _token(refresh: true);
    res = await request({'Authorization': 'Bearer $token'});
    if (res.statusCode == 401) {
      throw BackupFailure(
          t('Google did not accept the sign-in. Sign in again and try once more.'));
    }
    return res;
  }

  void _check(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    throw BackupFailure(
        t('Google Drive did not answer as expected (error {code}). Try again.',
            {'code': res.statusCode}));
  }

  Future<List<DriveFile>> list() async {
    final uri = Uri.https(host, '/drive/v3/files', {
      'spaces': 'appDataFolder',
      'q': "name contains 'nym_bk_'",
      'fields': 'files(id,name,modifiedTime)',
      'pageSize': '100',
    });
    final res = await _send((auth) => _client.get(uri, headers: auth));
    _check(res);
    final body = jsonDecode(res.body);
    final files = body is Map ? body['files'] : null;
    if (files is! List) return const [];
    return [
      for (final f in files.whereType<Map>())
        if (f['id'] is String &&
            f['name'] is String &&
            backupFilePattern.hasMatch(f['name'] as String))
          DriveFile(f['id'] as String, f['name'] as String,
              f['modifiedTime'] as String?),
    ];
  }

  Future<String> download(String id) async {
    final uri = Uri.https(host, '/drive/v3/files/$id', {'alt': 'media'});
    final res = await _send((auth) => _client.get(uri, headers: auth));
    _check(res);
    return utf8.decode(res.bodyBytes).trim();
  }

  Future<String> upload(String name, String payload) async {
    if (!backupFilePattern.hasMatch(name)) throw ArgumentError('name');
    final uri = Uri.https(
        host, '/upload/drive/v3/files', {'uploadType': 'multipart'});
    final boundary = 'nym_bk_${uuidV4().replaceAll('-', '')}';
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
    });
    final body = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'
        '$payload\r\n'
        '--$boundary--\r\n';
    final res = await _send((auth) => _client.post(uri,
        headers: {
          ...auth,
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: utf8.encode(body)));
    _check(res);
    final decoded = jsonDecode(res.body);
    final id = decoded is Map ? decoded['id'] : null;
    return id is String ? id : '';
  }

  Future<void> delete(String id) async {
    final uri = Uri.https(host, '/drive/v3/files/$id');
    final res = await _send((auth) => _client.delete(uri, headers: auth));
    if (res.statusCode == 404) return;
    _check(res);
  }
}

class GoogleBackupStore implements BackupStore {
  GoogleBackupStore({http.Client? client}) {
    drive = DriveAppData(_accessToken, client: client);
  }

  static const scopes = [
    'openid',
    'https://www.googleapis.com/auth/drive.appdata',
  ];

  static bool get available {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => NymbotConfig.googleServerClientId.isNotEmpty,
      TargetPlatform.iOS => NymbotConfig.googleIosClientId.isNotEmpty,
      _ => false,
    };
  }

  late final DriveAppData drive;
  static Future<void>? _initialized;
  GoogleSignInAccount? _account;
  String? _token;

  @override
  BackupProvider get provider => BackupProvider.google;

  Future<void> _init() => _initialized ??= GoogleSignIn.instance.initialize(
        clientId: defaultTargetPlatform == TargetPlatform.iOS &&
                NymbotConfig.googleIosClientId.isNotEmpty
            ? NymbotConfig.googleIosClientId
            : null,
        serverClientId: NymbotConfig.googleServerClientId.isNotEmpty
            ? NymbotConfig.googleServerClientId
            : null,
      );

  @override
  Future<String> signIn() async {
    try {
      await _init();
      final account =
          await GoogleSignIn.instance.authenticate(scopeHint: scopes);
      _account = account;
      _token = null;
      await _accessToken();
      final sub = subFromIdToken(account.authentication.idToken) ?? account.id;
      if (sub.isEmpty) throw BackupFailure(t('Google did not say which account signed in.'));
      return sub;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.clientConfigurationError) {
        _initialized = null;
      }
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        throw const BackupCancelled();
      }
      throw BackupFailure(t('Google sign-in did not go through. Try again.'));
    }
  }

  Future<String> _accessToken({bool refresh = false}) async {
    final account = _account;
    if (account == null) {
      throw BackupFailure(t('Sign in with Google first.'));
    }
    final client = account.authorizationClient;
    final old = _token;
    if (refresh && old != null) {
      await client.clearAuthorizationToken(accessToken: old);
      _token = null;
    }
    final cached = _token;
    if (cached != null) return cached;
    try {
      final authz = await client.authorizationForScopes(scopes) ??
          await client.authorizeScopes(scopes);
      _token = authz.accessToken;
      return authz.accessToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const BackupCancelled();
      }
      throw BackupFailure(
          t('Google did not grant access to the app\'s Drive folder. Try again.'));
    }
  }

  @override
  Future<List<StoredBackup>> readAll() async {
    final files = await drive.list();
    final out = <StoredBackup>[];
    for (final file in files) {
      out.add(StoredBackup(file.id, await drive.download(file.id)));
    }
    return out;
  }

  @override
  Future<void> write(String payload) async {
    await drive.upload(newBackupFileName(), payload);
  }

  @override
  Future<void> delete(String id) => drive.delete(id);

  @override
  Future<void> signOut() async {
    _token = null;
    _account = null;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}

class AppleBackupStore implements BackupStore {
  AppleBackupStore({FlutterSecureStorage? storage, this.getCredential})
      : _storage = storage ?? const FlutterSecureStorage();

  static const service = 'com.nym.apple-backup';

  static bool get available =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      NymbotConfig.appleBackup;

  final FlutterSecureStorage _storage;
  final Future<String?> Function()? getCredential;

  @override
  BackupProvider get provider => BackupProvider.apple;

  IOSOptions get _options => IOSOptions(
        accountName: service,
        groupId: NymbotConfig.appleKeychainGroup.isNotEmpty
            ? NymbotConfig.appleKeychainGroup
            : null,
        synchronizable: true,
        accessibility: KeychainAccessibility.first_unlock,
      );

  @override
  Future<String> signIn() async {
    String? user;
    try {
      final fetch = getCredential;
      if (fetch != null) {
        user = await fetch();
      } else {
        final credential =
            await SignInWithApple.getAppleIDCredential(scopes: const []);
        user = credential.userIdentifier;
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const BackupCancelled();
      }
      throw BackupFailure(t('Sign in with Apple did not go through. Try again.'));
    } on SignInWithAppleException {
      throw BackupFailure(t('Sign in with Apple did not go through. Try again.'));
    }
    if (user == null || user.isEmpty) {
      throw BackupFailure(t('Apple did not say which account signed in.'));
    }
    return user;
  }

  @override
  Future<List<StoredBackup>> readAll() async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll(iOptions: _options);
    } catch (_) {
      throw BackupFailure(t('iCloud Keychain could not be read. Try again.'));
    }
    return [
      for (final entry in all.entries)
        if (backupItemPattern.hasMatch(entry.key))
          StoredBackup(entry.key, entry.value),
    ];
  }

  @override
  Future<void> write(String payload) async {
    try {
      await _storage.write(
          key: newBackupItemName(), value: payload, iOptions: _options);
    } catch (_) {
      throw BackupFailure(t('iCloud Keychain could not save the backup. Try again.'));
    }
  }

  @override
  Future<void> delete(String id) async {
    if (!backupItemPattern.hasMatch(id)) return;
    try {
      await _storage.delete(key: id, iOptions: _options);
    } catch (_) {
      throw BackupFailure(t('iCloud Keychain could not remove the backup. Try again.'));
    }
  }

  @override
  Future<void> signOut() async {}
}

class PinThrottle {
  int _failures = 0;
  DateTime? _until;

  int get failures => _failures;

  Duration get wait {
    final until = _until;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Duration failed() {
    _failures++;
    final seconds = min(300, 1 << min(_failures, 9));
    final delay = Duration(seconds: seconds);
    _until = DateTime.now().add(delay);
    return delay;
  }

  void succeeded() {
    _failures = 0;
    _until = null;
  }
}

class KeyBackups {
  KeyBackups({this.google, this.apple, BackupKeyDeriver? derive})
      : derive = derive ?? deriveBackupKey;

  factory KeyBackups.platform() => KeyBackups(
        google: GoogleBackupStore.available ? GoogleBackupStore() : null,
        apple: AppleBackupStore.available ? AppleBackupStore() : null,
      );

  final BackupStore? google;
  final BackupStore? apple;
  final BackupKeyDeriver derive;
  final PinThrottle throttle = PinThrottle();

  List<BackupStore> get stores => [
        for (final store in [apple, google])
          if (store != null) store,
      ];

  bool get any => google != null || apple != null;
}
