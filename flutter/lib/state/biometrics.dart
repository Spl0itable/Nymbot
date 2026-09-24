import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../features/i18n/i18n.dart';

class BiometricCancelled implements Exception {
  const BiometricCancelled();
}

class BiometricError implements Exception {
  const BiometricError(this.detail);
  final String detail;
  @override
  String toString() => detail;
}

abstract class Biometrics {
  Future<bool> available();
  Future<void> store(String secret, String reason);
  Future<String?> load(String reason);
  Future<void> erase();
}

class DeviceBiometrics implements Biometrics {
  DeviceBiometrics([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  static const channel = MethodChannel('ai.nymbot/vault_key');

  final LocalAuthentication _auth;

  @override
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) return false;
      final types = await _auth.getAvailableBiometrics();
      return types.any((type) => type != BiometricType.weak);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> store(String secret, String reason) => _call('store', {
        'secret': secret,
        'title': reason,
        'cancel': t('Cancel'),
      });

  @override
  Future<String?> load(String reason) => _call('load', {
        'title': reason,
        'cancel': t('Cancel'),
      });

  @override
  Future<void> erase() async {
    try {
      await channel.invokeMethod<void>('erase');
    } catch (_) {}
  }

  static Future<T?> _call<T>(String method, Map<String, String> args) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'cancelled':
          throw const BiometricCancelled();
        case 'invalidated':
          return null;
        default:
          throw BiometricError(e.message ?? e.code);
      }
    } on MissingPluginException catch (e) {
      throw BiometricError(e.message ?? 'missing');
    }
  }
}
