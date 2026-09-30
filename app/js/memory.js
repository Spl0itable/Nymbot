(function () {
    'use strict';

    const Store = window.NymbotStore;

    /// Separate entries so each can be corrected; only relevant ones travel inside a message, nothing is uploaded.

    const SEND_CAP = 1200;
    const MAX_SENT = 8;

    /// Deliberately narrow: a false save is carried into every later chat.
    const RULES = [
        { re: /\b(?:call me|my name(?:'s| is)|i(?:'m| am) called)\s+([^.,;!?\n]{2,60})/i, topic: 'Name' },
        { re: /\bi (?:work|am employed) (?:at|for)\s+([^.,;!?\n]{2,60})/i, topic: 'Work' },
        { re: /\bi(?:'m| am) an?\s+([^.,;!?\n]{2,60}?)\s+(?:by trade|by profession|developer|engineer|designer|writer)\b/i, topic: 'Work' },
        { re: /\bi (?:use|write|code) (?:in\s+)?([^.,;!?\n]{2,60}?)\s+(?:every day|at work|for everything|mostly)\b/i, topic: 'Tools' },
        { re: /\bi (?:prefer|always want|would rather have)\s+([^.,;!?\n]{2,80})/i, topic: 'Preference' },
        { re: /\b(?:please )?(?:always|never)\s+([^.,;!?\n]{4,80}?)\s+(?:when you (?:answer|reply)|in your (?:answers|replies))/i, topic: 'How to answer' },
        { re: /\bmy (?:timezone|time zone) is\s+([^.,;!?\n]{2,40})/i, topic: 'Timezone' },
        { re: /\bi(?:'m| am) (?:based|living|located) in\s+([^.,;!?\n]{2,60})/i, topic: 'Where' }
    ];

    const ASKING = /^\s*(?:what|who|when|where|why|how|which|can|could|would|should|does|do|did|is|are|was|were|will)\b/i;

    const Memory = {
        /// Returns proposals, never saves: nothing enters memory unseen.
        propose(text, conv) {
            const body = String(text || '').trim();
            if (!body || body.length > 2000) return [];
            if (conv && (conv.ephemeral || conv.anon)) return [];
            const scope = (conv && conv.workspaceId) || null;
            const out = [];
            for (const line of body.split(/[\n.!?]+/)) {
                const sentence = line.trim();
                if (!sentence || ASKING.test(sentence)) continue;
                for (const rule of RULES) {
                    const hit = rule.re.exec(sentence);
                    if (!hit) continue;
                    const kept = sentence.length > 200 ? hit[0].trim() : sentence;
                    if (out.some(o => o.text.toLowerCase() === kept.toLowerCase())) continue;
                    out.push({ text: kept, topic: rule.topic, scope, source: 'chat' });
                    break;
                }
            }
            return out.slice(0, 2);
        },

        /// A ghost chat sees no memory.
        forConv(conv) {
            if (!conv || conv.ephemeral || conv.anon) return [];
            const scope = conv.workspaceId || null;
            return Store.memories().filter(m => !m.scope || m.scope === scope);
        },

        /// Plus the entries about how to answer, which apply to every message.
        block(conv, query) {
            const all = this.forConv(conv);
            if (!all.length) return '';
            const Chat = window.NymbotChat;
            const always = all.filter(m => m.topic === 'How to answer' || m.topic === 'Name');
            const rest = all.filter(m => always.indexOf(m) === -1);
            const ranked = Chat && Chat.rankChunks
                ? Chat.rankChunks(
                    rest.map(m => ({ heading: m.topic, text: m.text, entry: m })),
                    query || ''
                ).map(hit => hit.chunk.entry)
                : rest;
            const picked = [];
            let budget = SEND_CAP;
            for (const entry of always.concat(ranked)) {
                if (picked.length >= MAX_SENT || entry.text.length > budget) continue;
                budget -= entry.text.length;
                picked.push(entry);
            }
            if (!picked.length) return '';
            return '[remembered about you]\n'
                + picked.map(m => '- ' + (m.topic ? m.topic + ': ' : '') + m.text).join('\n')
                + '\nThese were saved from earlier conversations. Treat them as true '
                + 'unless this conversation says otherwise, and never repeat them back '
                + 'as a list unless asked.';
        }
    };

    window.NymbotMemory = Memory;
})();
