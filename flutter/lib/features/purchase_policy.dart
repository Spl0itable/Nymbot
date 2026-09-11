import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Whether credits can be bought from inside the app, per platform.
///
/// Apple does not allow an app to sell digital goods through anything but its
/// own in-app purchase, and credits are a consumable digital good that settles
/// in sats over Lightning. Rather than carry a whole store-billing integration
/// for one platform — receipt validation, a product tier ladder, console upkeep
/// — the iOS build simply does not sell: it keeps every credit already on the
/// account working, and states where a purchase is made instead.
///
/// This mirrors `shop_purchase_policy.dart` in the Nymchat app, and like it the
/// notice is deliberately a STATEMENT, not a call to action: no button, no
/// tappable link, no price. Apple's 3.1.1 prohibits "buttons, external links,
/// or other calls to action that direct customers to purchasing mechanisms
/// other than in-app purchase", and a plain sentence is not one of those.
/// Adding a tap target here would change that, so don't.
///
/// Android is untouched — the Lightning invoice flow has passed Play review
/// repeatedly and continues to run in-app.
bool get creditPurchasesDisabled {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}
