package ai.nymbot

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity rather than FlutterActivity: platform plugins that
// present system dialogs (the keystore's biometric prompt among them) require a
// FragmentActivity host.
class MainActivity : FlutterFragmentActivity()
