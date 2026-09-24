import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/i18n/i18n.dart';
import 'biometrics.dart';

class VaultLocked implements Exception {
  const VaultLocked();
  @override
  String toString() => t('Unlock Nymbot first.');
}

class VaultWrongPassphrase implements Exception {
  const VaultWrongPassphrase();
  @override
  String toString() => t('Wrong passphrase.');
}

class VaultBiometricFailed implements Exception {
  const VaultBiometricFailed();
  @override
  String toString() => t('The biometric check did not go through. Nothing was changed.');
}

class VaultBiometricInvalidated implements Exception {
  const VaultBiometricInvalidated();
  @override
  String toString() => t('The fingerprints or face data on this device changed, so its '
      "biometric key no longer opens Nymbot. Use Can't unlock? to start over, then sign "
      'back in with your saved nsec and recovery code.');
}

class VaultFailure implements Exception {
  const VaultFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class Vault {
  Vault(this._prefs, this._secure,
      {this.iterations = defaultIterations, Biometrics? biometrics})
      : biometrics = biometrics ?? DeviceBiometrics();

  static const defaultIterations = 310000;
  static const minLength = 4;
  static const prefix = 'enc:v1:';
  static const checkText = 'nymbot-vault-ok';
  static const enabledKey = 'vault_enabled';
  static const saltKey = 'vault_salt';
  static const checkKey = 'vault_check';
  static const methodKey = 'vault_method';
  static const legacyBioKey = 'vault_bio_secret';
  static const passphraseMethod = 'passphrase';
  static const biometricMethod = 'biometric';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final int iterations;
  final Biometrics biometrics;

  static final _aes = AesGcm.with256bits();

  SecretKey? _key;
  Future<void> _tail = Future.value();

  bool get enabled => _prefs.getBool(enabledKey) ?? false;
  bool get locked => enabled && _key == null;

  String get method =>
      _prefs.getString(methodKey) == biometricMethod ? biometricMethod : passphraseMethod;

  bool get biometric => enabled && method == biometricMethod;

  static bool sealed(String? value) => value != null && value.startsWith(prefix);

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String?> read(String name) => _serial(() => _read(name));

  Future<void> write(String name, String value) =>
      _serial(() => _write(name, value));

  Future<void> remove(String name) => _serial(() => _secure.delete(key: name));

  Future<String?> _read(String name) async {
    final raw = await _secure.read(key: name);
    if (!sealed(raw)) return raw;
    final key = _key;
    if (key == null) throw const VaultLocked();
    return _open(key, raw!);
  }

  Future<void> _write(String name, String value) async {
    if (!enabled) {
      await _secure.write(key: name, value: value);
      return;
    }
    final key = _key;
    if (key == null) throw const VaultLocked();
    await _secure.write(key: name, value: await _seal(key, value));
  }

  Future<bool> check(String passphrase) async {
    if (!enabled) return false;
    return await _verified(passphrase) != null;
  }

  Future<void> unlockBiometric() => _serial(() async {
        if (!enabled) return;
        final key = await _biometricKey();
        _key = key;
        await _sealLoose(key);
      });

  Future<void> enableBiometric() => _serial(() async {
        if (enabled) {
          throw VaultFailure(t('Identity encryption is already on.'));
        }
        final secret = await _newBioSecret();
        try {
          await _enable(secret, method: biometricMethod);
        } catch (_) {
          await biometrics.erase();
          rethrow;
        }
      });

  Future<void> disableBiometric() => _serial(() async {
        if (!enabled) return;
        final key = await _biometricOrOpenKey();
        await _disable(key);
        await _dropBioSecret();
      });

  Future<void> useBiometric(String passphrase) => _serial(() async {
        if (!enabled) throw VaultFailure(t('Identity encryption is off.'));
        final key = await _verified(passphrase);
        if (key == null) throw const VaultWrongPassphrase();
        final secret = await _newBioSecret();
        try {
          await _disable(key);
          await _enable(secret, method: biometricMethod);
        } catch (_) {
          if (!enabled) await biometrics.erase();
          rethrow;
        }
      });

  Future<void> usePassphrase(String next) => _serial(() async {
        if (!enabled) throw VaultFailure(t('Identity encryption is off.'));
        _require(next);
        final key = await _biometricOrOpenKey();
        await _disable(key);
        await _enable(next);
        await _dropBioSecret();
      });

  static String get _reason => t('Unlock your Nymbot identity');

  Future<String> _newBioSecret() async {
    final secret = base64Encode(_randomBytes(32));
    await _protect(secret);
    return secret;
  }

  Future<void> _protect(String secret) async {
    try {
      await biometrics.store(secret, _reason);
      if (await biometrics.load(_reason) != secret) {
        throw VaultFailure(t('Could not set up encryption. Nothing was changed.'));
      }
    } on BiometricCancelled {
      await biometrics.erase();
      throw const VaultBiometricFailed();
    } on BiometricError {
      await biometrics.erase();
      throw const VaultBiometricFailed();
    } catch (_) {
      await biometrics.erase();
      rethrow;
    }
  }

  Future<void> _dropBioSecret() async {
    await biometrics.erase();
    await _secure.delete(key: legacyBioKey);
  }

  Future<SecretKey> _biometricOrOpenKey() async {
    try {
      return await _biometricKey();
    } on VaultBiometricInvalidated {
      final open = _key;
      if (open == null) rethrow;
      return open;
    }
  }

  Future<SecretKey> _biometricKey() async {
    final plain = await _secure.read(key: legacyBioKey);
    final legacy = plain == null ? null : await _verified(plain);
    if (legacy != null) {
      await _protect(plain!);
      await _secure.delete(key: legacyBioKey);
      return legacy;
    }
    final String? secret;
    try {
      secret = await biometrics.load(_reason);
    } on BiometricCancelled {
      throw const VaultBiometricFailed();
    } on BiometricError {
      throw const VaultBiometricFailed();
    }
    final key = secret == null ? null : await _verified(secret);
    if (key == null) throw const VaultBiometricInvalidated();
    return key;
  }

  Future<void> unlock(String passphrase) => _serial(() async {
        if (!enabled) return;
        final key = await _verified(passphrase);
        if (key == null) throw const VaultWrongPassphrase();
        _key = key;
        await _sealLoose(key);
      });

  Future<void> enable(String passphrase) => _serial(() async {
        if (enabled) {
          throw VaultFailure(t('Identity encryption is already on.'));
        }
        _require(passphrase);
        await _enable(passphrase);
      });

  Future<void> disable(String passphrase) => _serial(() async {
        if (!enabled) return;
        final key = await _verified(passphrase);
        if (key == null) throw const VaultWrongPassphrase();
        await _disable(key);
      });

  Future<void> change(String current, String next) => _serial(() async {
        if (!enabled) throw VaultFailure(t('Identity encryption is off.'));
        _require(next);
        final key = await _verified(current);
        if (key == null) throw const VaultWrongPassphrase();
        await _disable(key);
        await _enable(next);
      });

  void forget() => _key = null;

  void _require(String passphrase) {
    if (passphrase.length < minLength) {
      throw VaultFailure(t('Use at least 4 characters.'));
    }
  }

  Future<void> _enable(String passphrase, {String method = passphraseMethod}) async {
    final salt = _randomBytes(16);
    final key = await _derive(passphrase, salt, iterations);
    final check = await _seal(key, checkText);
    if (await _open(key, check) != checkText) {
      throw VaultFailure(t('Could not set up encryption. Nothing was changed.'));
    }
    final plain = <String, String>{};
    final boxes = <String, String>{};
    for (final e in (await _secure.readAll()).entries) {
      if (sealed(e.value) || e.key == legacyBioKey) continue;
      final box = await _seal(key, e.value);
      if (await _open(key, box) != e.value) {
        throw VaultFailure(t('Could not set up encryption. Nothing was changed.'));
      }
      plain[e.key] = e.value;
      boxes[e.key] = box;
    }
    await _prefs.setString(saltKey, base64Encode(salt));
    await _prefs.setString(checkKey, check);
    await _prefs.setString(methodKey, method);
    await _prefs.setBool(enabledKey, true);
    _key = key;
    final touched = <String>[];
    try {
      for (final e in boxes.entries) {
        touched.add(e.key);
        await _secure.write(key: e.key, value: e.value);
        final back = await _secure.read(key: e.key);
        if (back == null || await _open(key, back) != plain[e.key]) {
          throw VaultFailure(t('Could not set up encryption. Nothing was changed.'));
        }
      }
    } catch (_) {
      for (final name in touched) {
        await _secure.write(key: name, value: plain[name]!);
      }
      await _clearMeta();
      _key = null;
      rethrow;
    }
  }

  Future<void> _disable(SecretKey key) async {
    for (final e in (await _secure.readAll()).entries) {
      if (!sealed(e.value)) continue;
      final value = await _open(key, e.value);
      await _secure.write(key: e.key, value: value);
      if (await _secure.read(key: e.key) != value) {
        throw VaultFailure(t('Could not turn encryption off. Try again.'));
      }
    }
    await _clearMeta();
    _key = null;
  }

  Future<void> _sealLoose(SecretKey key) async {
    for (final e in (await _secure.readAll()).entries) {
      if (sealed(e.value) || e.key == legacyBioKey) continue;
      final box = await _seal(key, e.value);
      if (await _open(key, box) != e.value) continue;
      await _secure.write(key: e.key, value: box);
    }
  }

  Future<void> _clearMeta() async {
    await _prefs.remove(enabledKey);
    await _prefs.remove(saltKey);
    await _prefs.remove(checkKey);
    await _prefs.remove(methodKey);
  }

  Future<SecretKey?> _verified(String passphrase) async {
    final salt = _prefs.getString(saltKey);
    final check = _prefs.getString(checkKey);
    if (salt == null || check == null || passphrase.isEmpty) return null;
    try {
      final key = await _derive(passphrase, base64Decode(salt), iterations);
      return await _open(key, check) == checkText ? key : null;
    } catch (_) {
      return null;
    }
  }

  static Future<SecretKey> _derive(
      String passphrase, List<int> salt, int iterations) async {
    final bytes = await Isolate.run(() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
      return key.extractBytes();
    });
    return SecretKey(bytes);
  }

  static Future<String> _seal(SecretKey key, String plaintext) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey: key, nonce: nonce);
    final body = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return '$prefix${base64Encode(nonce)}:${base64Encode(body)}';
  }

  static Future<String> _open(SecretKey key, String blob) async {
    final parts = blob.split(':');
    if (parts.length != 4 || parts[0] != 'enc' || parts[1] != 'v1') {
      throw const FormatException('bad blob');
    }
    final nonce = base64Decode(parts[2]);
    final body = base64Decode(parts[3]);
    if (body.length < 16) throw const FormatException('bad blob');
    final clear = await _aes.decrypt(
      SecretBox(body.sublist(0, body.length - 16),
          nonce: nonce, mac: Mac(body.sublist(body.length - 16))),
      secretKey: key,
    );
    return utf8.decode(clear);
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
  }
}
