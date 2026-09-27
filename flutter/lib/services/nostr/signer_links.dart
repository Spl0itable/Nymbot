import 'package:flutter/foundation.dart';

import 'event_signer.dart';
import 'nip46.dart';
import 'nip55.dart';

final ValueNotifier<String?> signerAuthUrl = ValueNotifier<String?>(null);

RemoteSigner? restoreRemoteSigner(Map<String, dynamic> session,
    {Nip46SocketFactory? sockets}) {
  switch (session['method']) {
    case 'nip46':
      return Nip46Signer.restore(session, sockets: sockets)
        ?..onAuthUrl = (url) {
          signerAuthUrl.value = url;
        };
    case 'nip55':
      return Nip55Signer.restore(session);
    default:
      return null;
  }
}
