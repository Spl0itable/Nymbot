import 'package:flutter/material.dart';

import 'app.dart';
import 'core/crypto/native_schnorr.dart';
import 'features/i18n/i18n.dart';
import 'state/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads the bundled libsecp256k1 that signing, verification and NIP-44's
  // raw-X ECDH prefer. It never throws: the pure-Dart paths stay correct if the
  // library is unavailable, just slower.
  await NativeSchnorr.ensureLoaded();
  final controller = await AppController.boot();
  // Before the first frame, so the app never shows English and then repaints.
  await I18n.load(preferred: controller.preferredLanguage);
  runApp(NymbotApp(controller: controller));
}
