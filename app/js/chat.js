// One turn, end to end: seal, publish, ask the worker, open the reply.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Identity = window.NymbotIdentity;
    const Relays = window.NymbotRelays;
    const PQ = window.NymbotPQ;
    const Wire = window.NymbotWire;
    const Api = window.NymbotApi;
    const Anon = window.NymbotAnon;

    /// A reply can carry its chain of thought ahead of the answer.
    function splitThinking(text) {
        const m = /^\s*<think>([\s\S]*?)<\/think>\s*/i.exec(text || '');
        if (!m) return { thinking: null, body: text || '' };
        return { thinking: m[1].trim(), body: (text || '').slice(m[0].length) };
    }

    /// A conversation is named after the first thing you say in it. Done here,
    /// on the device: the worker is never asked to summarise anything, and
    /// never sees the title.
    function titleFor(text) {
        let title = String(text || '')
            .replace(/```[\s\S]*?```/g, ' ')
            .replace(/[`*_>#|]/g, '')
            .replace(/https?:\/\/\S+/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (!title) return t('New chat');
        // A leading command is what the message is about only when nothing
        // follows it.
        const cmd = /^\?(\w+)\s*(.*)$/.exec(title);
        if (cmd) title = cmd[2] || cmd[1];
        title = title.replace(/^[!\s]+/, '');
        if (title.length <= 48) return title.charAt(0).toUpperCase() + title.slice(1);
        const cut = title.slice(0, 48);
        const space = cut.lastIndexOf(' ');
        return (space > 24 ? cut.slice(0, space) : cut).replace(/[,;:.\-]$/, '') + '…';
    }

    const Chat = {
        onStatus: null,    // (text|null) => void

        _say(text) { if (this.onStatus) this.onStatus(text); },

        /// Publishes the message and collects the reply.
        ///
        /// Returns { reply, thinking, cost, balance, pro } or throws with a
        /// message worth showing.
        async send(conv, text, settings) {
            if (!PQ.botKey) { try { await PQ.resolveBot(); } catch (_) { } }
            if (Relays.connected === 0) {
                throw new Error(t('Not connected to any relay yet — your message cannot be published.'));
            }

            // Anonymous mode: the throwaway key signs the rumor, the seal and
            // the request, and the reply comes back to it. The account key
            // signs nothing in this conversation at all.
            const anon = !!conv.anon && Anon.ready();
            const sender = anon ? Anon.sender() : null;
            const senderPubkey = anon ? sender.pubkey : Identity.pubkey;
            const selfKemPk = anon
                ? (Anon.kem() ? Anon.kem().publicKey : null)
                : Identity.kemPk;

            const botKem = PQ.botKey ? PQ.botKey.pk : null;
            const msgId = Wire.sharedId();
            const rumor = Wire.rumor(text, C.botPubkey, conv.rootId, msgId, senderPubkey);

            const wrap = await Wire.wrap(rumor, C.botPubkey, botKem, sender);
            const accepted = await Relays.publish(wrap, 5000);
            if (accepted === 0) {
                throw new Error(t('No relay accepted your message. Check your connection and try again.'));
            }

            // Our own copy, so the conversation restores on another device.
            try {
                const selfWrap = await Wire.wrap(rumor, senderPubkey, selfKemPk, sender);
                Relays.publish(selfWrap, 3000);
            } catch (_) { /* the archive copy is best effort */ }

            const extra = {
                eventId: wrap.id,
                fresh: /^\s*!\s*\S/.test(text)
            };
            const announcement = anon ? Anon.announcement() : PQ.selfAnnouncement;
            if (announcement) extra.pqAnnouncement = announcement;
            if (settings.proModel) {
                extra.proModel = settings.proModel.key;
                const git = settings.git;
                if (git && git.token && git.repo) {
                    extra.git = {
                        provider: git.provider || 'github',
                        host: git.host || '',
                        token: git.token,
                        repo: git.repo,
                        branch: git.branch || '',
                        allowWrites: !!git.allowWrites
                    };
                }
            }

            // `pending` means an earlier attempt at this same message is still
            // generating. Asking again with the same event id collects that
            // reply rather than paying for a second one.
            let status, data;
            for (let tries = 0; ; tries++) {
                ({ status, data } = await Api.call('pm', extra, {
                    timeout: C.pmTimeoutMs,
                    signer: anon ? Anon.signer() : null
                }));
                if (!data || !data.pending || tries >= 5) break;
                this._say(t('Still working on that one…'));
                await new Promise(r => setTimeout(r, 3000));
            }

            if (data && data.pending) {
                throw new Error(data.message
                    || t('Nymbot is still working on that message — its reply will arrive shortly.'));
            }
            if (data && data.noCredits) {
                const err = new Error(data.error
                    || (data.pro ? t('You are out of Pro credits.') : t('You are out of credits.')));
                err.noCredits = true;
                err.pro = !!data.pro;
                err.balance = data.balance || 0;
                throw err;
            }
            if (status >= 400 || !data || data.error) {
                throw new Error((data && data.error) || t('The request failed.'));
            }
            if (!data.event) throw new Error(t('Nymbot sent no reply.'));

            // Both copies go to the relays: the reply so it restores like any
            // other message, and the bot's self-addressed copy so the worker
            // can re-read its own turn as context next time.
            Relays.publish(data.event, 3000);
            if (data.selfEvent && /^[0-9a-f]{64}$/i.test(data.selfEvent.id || '')) {
                Relays.publish(data.selfEvent, 3000);
            }

            const opened = await Wire.unwrap(data.event, anon ? Anon.recipient() : null);
            if (!opened || !opened.rumor) throw new Error(t('Nymbot replied, but this device could not decrypt it.'));

            const ids = Store.thread(conv.id);
            ids.push(wrap.id);
            if (data.selfEvent && data.selfEvent.id) ids.push(data.selfEvent.id);
            Store.setThread(conv.id, ids);

            const split = splitThinking(opened.rumor.content || '');
            return {
                reply: split.body,
                thinking: split.thinking,
                cost: data.cost || 0,
                balance: typeof data.balance === 'number' ? data.balance : null,
                pro: !!data.pro,
                modelCalls: data.modelCalls || 1,
                lowBalance: !!data.lowBalance,
                taskType: data.taskType || null
            };
        },

        titleFor,
        splitThinking
    };

    window.NymbotChat = Chat;
})();
