window.NymbotConfig = {
    version: 'v1.0.7',
    apiHost: 'nymbot.ai',

    botPubkey: 'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2',
    botName: 'Nymbot',
    botAvatar: '/images/nymbot-icon.png',

    mediaHosts: [
        'blossom.band',
        '.blossom.band',
        'blossom.primal.net',
        'blossom.yakihonne.com',
        'files.sovbit.host',
        'nostr.download'
    ],

    shareHosts: [
        'https://blossom.yakihonne.com',
        'https://files.sovbit.host',
        'https://nostr.download'
    ],

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

    googleClientId: '435441872913-q30ml0k3dlgl65qu9qo6i5obb1v14t0d.apps.googleusercontent.com',

    storagePrefix: 'nymbot_',

    supportEmail: 'support@nymbot.ai',

    developerPubkey: 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
    sourceRepo: 'https://github.com/Spl0itable/Nymbot',
    attestationApi: 'https://api.github.com/repos/Spl0itable/Nymbot/attestations/sha256:',
    officialHosts: ['nymbot.ai'],
    canaryUrl: 'https://raw.githubusercontent.com/Spl0itable/Nymbot/main/canary.json',
    canaryDTag: 'nymbot-warrant-canary'
};
