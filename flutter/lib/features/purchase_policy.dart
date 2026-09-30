import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// iOS sells no credits (App Store 3.1.1): the notice must stay a plain statement with no tap target.
bool get creditPurchasesDisabled {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}
