// No-FFI stand-in: [sharedX] always defers to the pure-Dart fallback.

import 'dart:typed_data';

bool get isAvailable => false;

Uint8List? sharedX({
  required Uint8List privkey,
  required String pubkeyHex,
}) =>
    null;
