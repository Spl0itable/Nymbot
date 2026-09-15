window.NymbotConfig = {
    apiHost: 'nymbot.ai',

    botPubkey: 'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2',
    botName: 'Nymbot',
    botAvatar: '/images/nymbot-icon.png',

    relays: [
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.primal.net',
        'wss://offchain.pub',
        'wss://nostr21.com',
        'wss://relay.snort.social',
        'wss://relay.nostr.net',
        'wss://nostr-pub.wellorder.net',
        'wss://relay.0xchat.com',
        'wss://nostr.mom'
    ],

    pqDTag: 'nym-pq',
    pqAlg: 'mlkem768',
    pqTtlSec: 30 * 24 * 3600,

    satsPerCredit: { standard: 10, pro: 100 },

    pmTimeoutMs: 180000,

    storagePrefix: 'nymbot_'
};
