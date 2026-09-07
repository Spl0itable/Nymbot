// Where the app points and what it talks to.
//
// The worker is Nymchat's: one identity, one credit balance and one set of
// Nymbot conversations across both services, which is the whole reason an
// account works in either.
window.NymbotConfig = {
    apiHost: 'web.nymchat.app',

    botPubkey: 'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2',
    botName: 'Nymbot',
    botAvatar: '/images/nymbot-icon.png',

    // The worker fetches a wrap by id from exactly these relays, so a message
    // published anywhere else is one it can never open (bot.js FETCH_RELAYS).
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

    // A reply can outlast the request that asked for it; the worker holds the
    // answer and hands it back on a resend.
    pmTimeoutMs: 180000,

    storagePrefix: 'nymbot_'
};
