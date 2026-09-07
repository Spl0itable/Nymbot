(function () {
    'use strict';

    const Store = window.NymbotStore;

    /// Standing facts about you, carried between chats.
    ///
    /// Kept as separate entries rather than one rolling summary, because a
    /// summary cannot be corrected: you can read this list, fix the line that
    /// is wrong and throw away the one you never meant to save. Nothing here is
    /// uploaded — the entries that bear on a question travel inside that
    /// message like everything else you send, and the rest never leave.

    // What a fact may cost the context window. Enough for a handful of short
    // entries; memory that crowds out the conversation is memory that makes
    // answers worse.
    const SEND_CAP = 1200;
    const MAX_SENT = 8;

    /// Patterns that read as a durable fact about the person typing, rather
    /// than as part of the question they are asking. Deliberately narrow: a
    /// false save is a line of nonsense the model carries into every later
    /// chat, so the rules only fire on sentences that are explicitly about
    /// the speaker and explicitly in the present.
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

    // A question is not a statement about yourself, however it is phrased.
    const ASKING = /^\s*(?:what|who|when|where|why|how|which|can|could|would|should|does|do|did|is|are|was|were|will)\b/i;

    const Memory = {
        /// Reads one message for facts worth keeping. Returns proposals, never
        /// saves: nothing enters memory without the writer seeing it happen.
        propose(text, conv) {
            const body = String(text || '').trim();
            if (!body || body.length > 2000) return [];
            if (conv && conv.ephemeral) return [];
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

        /// Everything a chat is allowed to see: what was saved with no
        /// workspace, plus what was saved inside this one. A ghost chat sees
        /// nothing — the whole point of it is that it is not part of a record.
        forConv(conv) {
            if (!conv || conv.ephemeral) return [];
            const scope = conv.workspaceId || null;
            return Store.memories().filter(m => !m.scope || m.scope === scope);
        },

        /// The entries that bear on this question, plus the ones that hold
        /// whatever the person asked to be remembered about how to answer —
        /// those apply to every message, not just the ones that mention them.
        block(conv, query) {
            const all = this.forConv(conv);
            if (!all.length) return '';
            const Chat = window.NymbotChat;
            const always = all.filter(m => m.topic === 'How to answer' || m.topic === 'Name');
            const rest = all.filter(m => always.indexOf(m) === -1);
            // Ranked with the same search the workspace files use, so what is
            // remembered arrives for the same reason and by the same rule.
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
