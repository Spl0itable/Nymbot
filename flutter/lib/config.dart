library;

class NymbotConfig {
  static const String apiHost = 'nymbot.ai';
  static String get botUrl => 'https://$apiHost/api/bot';
  static String get storageUrl => 'https://$apiHost/api/storage';

  static const String botPubkey =
      'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';
  static const String botName = 'Nymbot';

  static const List<String> relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
    'wss://offchain.pub',
    'wss://nostr21.com',
    'wss://relay.snort.social',
    'wss://relay.nostr.net',
    'wss://nostr-pub.wellorder.net',
    'wss://relay.0xchat.com',
    'wss://nostr.mom',
  ];

  static const String pqDTag = 'nym-pq';
  static const String pqAlg = 'mlkem768';
  static const int pqTtlSec = 30 * 24 * 3600;

  static const Map<String, int> satsPerCredit = {'standard': 10, 'pro': 100};

  /// A reply can outlast the request that asked for it; the worker holds the
  /// answer and hands it back on a resend.
  static const Duration pmTimeout = Duration(seconds: 180);

  /// The shape the worker's client gate looks for (`_client.js`), so the
  /// native builds reach the API the way the Nymchat apps do.
  static const String userAgent = 'NymbotApp/1.0';
}
