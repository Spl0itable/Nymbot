// Native secp256k1 ECDH returning the raw shared X (NIP-44), since coinlib's ecdh() hashes it; null when unavailable.

import 'dart:typed_data';

import 'native_ecdh_stub.dart'
    if (dart.library.ffi) 'native_ecdh_ffi.dart' as impl;

class NativeEcdh {
  NativeEcdh._();

  /// Loaded lazily per isolate; false until the first [sharedX] call.
  static bool get isAvailable => impl.isAvailable;

  /// Raw 32-byte X of the shared point (NIP-44 `ecdh_shared_x`); null if native is unavailable, throws on invalid input.
  static Uint8List? sharedX({
    required Uint8List privkey,
    required String pubkeyHex,
  }) =>
      impl.sharedX(privkey: privkey, pubkeyHex: pubkeyHex);
}
