import 'package:url_launcher/url_launcher.dart';

import 'event_signer.dart';
import 'nip46.dart';
import 'nip55.dart';

RemoteSigner? restoreRemoteSigner(Map<String, dynamic> session,
    {Nip46SocketFactory? sockets}) {
  switch (session['method']) {
    case 'nip46':
      return Nip46Signer.restore(session, sockets: sockets)
        ?..onAuthUrl = (url) {
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
              .catchError((_) => false);
        };
    case 'nip55':
      return Nip55Signer.restore(session);
    default:
      return null;
  }
}
