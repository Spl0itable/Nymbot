(function () {
    'use strict';

    const LOCAL = [
        { name: 'help', args: '', group: 'local', hint: () => t('List every command') },
        { name: 'balance', args: '', group: 'local', hint: () => t('Check your credit balance') },
        { name: 'buy', args: '[credits]', group: 'local', hint: () => t('Buy credits over Lightning') },
        { name: 'model', args: '[name|off]', group: 'local', hint: () => t('Pin a Pro model, or go back to auto-routing') },
        { name: 'compare', args: '', group: 'local', hint: () => t('Ask two models the same thing') },
        { name: 'git', args: '[add|list|use|writes on|off|disconnect]', group: 'local', hint: () => t('Manage the repositories this chat can read') },
        { name: 'repo', args: '[name]', group: 'local', hint: () => t('Toggle a repository for this chat') },
        { name: 'anon', args: '', group: 'local', hint: () => t('Chat from a throwaway key') },
        { name: 'persona', args: '[name|off]', group: 'local', hint: () => t('Apply custom instructions to this chat') },
        { name: 'workspace', args: '[name|off]', group: 'local', hint: () => t('Start this chat from a workspace') },
        { name: 'bot', args: '[name|off]', group: 'local', hint: () => t('Answer this chat as one of your bots') },
        { name: 'ghost', args: '', group: 'local', hint: () => t('Keep this chat off this device entirely') },
        { name: 'schedule', args: '[prompt]', group: 'local', hint: () => t('Have Nymbot ask something on a schedule') },
        { name: 'system', args: '[text]', group: 'local', hint: () => t('Set this chat\'s custom instructions') },
        { name: 'prompt', args: '[title]', group: 'local', hint: () => t('Insert a saved prompt') },
        { name: 'save', args: '[title]', group: 'local', hint: () => t('Save the composer text as a prompt') },
        { name: 'search', args: '[text]', group: 'local', hint: () => t('Search every conversation') },
        { name: 'effort', args: '[normal|careful|deep]', group: 'local', hint: () => t('How hard to think about each reply') },
        { name: 'remember', args: '[text]', group: 'local', hint: () => t('Keep a standing fact between chats') },
        { name: 'memory', args: '', group: 'local', hint: () => t('Read what Nymbot remembers about you') },
        { name: 'forget', args: '', group: 'local', hint: () => t('Throw away what Nymbot remembers') },
        { name: 'pin', args: '', group: 'local', hint: () => t('Pin this conversation') },
        { name: 'archive', args: '', group: 'local', hint: () => t('Archive this conversation') },
        { name: 'tag', args: '[name]', group: 'local', hint: () => t('Tag this conversation') },
        { name: 'folder', args: '[name]', group: 'local', hint: () => t('File this conversation in a folder') },
        { name: 'rename', args: '[title]', group: 'local', hint: () => t('Rename this conversation') },
        { name: 'fork', args: '', group: 'local', hint: () => t('Branch a copy of this conversation') },
        { name: 'export', args: '[md|json|txt]', group: 'local', hint: () => t('Download this conversation') },
        { name: 'stats', args: '', group: 'local', hint: () => t('What this chat has cost so far') },
        { name: 'theme', args: '[dark|light|system]', group: 'local', hint: () => t('Switch the theme') },
        { name: 'settings', args: '', group: 'local', hint: () => t('Open appearance and behaviour') },
        { name: 'shortcuts', args: '', group: 'local', hint: () => t('Keyboard shortcuts') },
        { name: 'guide', args: '[topic]', group: 'local', hint: () => t('Open the help guide') },
        { name: 'voice', args: '', group: 'local', hint: () => t('Dictate a message') },
        { name: 'retry', args: '', group: 'local', hint: () => t('Ask the last question again') },
        { name: 'clear', args: '', group: 'local', hint: () => t('Clear this chat and reset the context') }
    ];

    const REMOTE = [
        { name: 'ask', args: '<question>', group: 'charged', hint: () => t('One question, no history') },
        { name: 'image', args: '<prompt>', group: 'charged', hint: () => t('Generate an image') },
        { name: 'speak', args: '<text>', group: 'charged', hint: () => t('Read something aloud') },
        { name: 'translate', args: '<text>', group: 'charged', hint: () => t('Translate') },
        { name: 'define', args: '<word>', group: 'charged', hint: () => t('Define a word') },
        { name: 'news', args: '[topic]', group: 'charged', hint: () => t('Headlines') },
        { name: 'math', args: '<expression>', group: 'charged', hint: () => t('Work out a sum') },
        { name: 'units', args: '<value>', group: 'charged', hint: () => t('Convert units') },
        { name: 'time', args: '[place]', group: 'charged', hint: () => t('The time somewhere') },
        { name: 'btc', args: '', group: 'charged', hint: () => t('The Bitcoin price') },
        { name: 'web', args: '<query>', group: 'charged', hint: () => t('Search the web') },
        { name: 'summarise', args: '<text>', group: 'charged', hint: () => t('Summarise something') },
        { name: 'code', args: '<task>', group: 'charged', hint: () => t('Write code') },
        { name: 'review', args: '', group: 'charged', hint: () => t('Review the connected repositories') },
        { name: 'trivia', args: '', group: 'games', hint: () => t('A trivia question') },
        { name: 'joke', args: '', group: 'games', hint: () => t('A joke') },
        { name: 'riddle', args: '', group: 'games', hint: () => t('A riddle') },
        { name: 'wordplay', args: '', group: 'games', hint: () => t('Wordplay') },
        { name: 'flip', args: '', group: 'games', hint: () => t('Flip a coin') },
        { name: '8ball', args: '<question>', group: 'games', hint: () => t('Ask the magic 8-ball') },
        { name: 'pick', args: '<a, b, c>', group: 'games', hint: () => t('Pick one') }
    ];

    const ALL = LOCAL.concat(REMOTE);

    function score(entry, term) {
        const name = entry.name;
        if (!term) return 1;
        if (name === term) return 1000;
        if (name.startsWith(term)) return 500 - name.length;
        if (name.includes(term)) return 200 - name.length;
        if (entry.hint().toLowerCase().includes(term)) return 50;
        return 0;
    }

    function match(term, limit) {
        const needle = String(term || '').toLowerCase().replace(/^\?/, '').trim().split(/\s+/)[0] || '';
        return ALL
            .map(e => ({ entry: e, score: score(e, needle) }))
            .filter(x => x.score > 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, limit || 8)
            .map(x => x.entry);
    }

    function isLocal(name) {
        return LOCAL.some(e => e.name === String(name || '').toLowerCase());
    }

    function helpText() {
        return [
            t('Free, on this device:') + ' ' + LOCAL.map(e => '?' + e.name).join(' '),
            t('Charged:') + ' ' + REMOTE.filter(e => e.group === 'charged').map(e => '?' + e.name).join(' '),
            t('Games:') + ' ' + REMOTE.filter(e => e.group === 'games').map(e => '?' + e.name).join(' '),
            t('Start a message with ! to send it without this chat\'s history.')
        ].join('\n');
    }

    window.NymbotCommands = { LOCAL, REMOTE, ALL, match, isLocal, helpText };
})();
