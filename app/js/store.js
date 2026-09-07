// Everything the app keeps on the device: the identity, the conversation list,
// and each conversation's messages.
//
// localStorage rather than IndexedDB because every value here is small and
// every read is synchronous at startup. Messages are capped per conversation so
// a long-running chat cannot fill the origin's quota and start throwing on
// writes it needs to make.
(function () {
    'use strict';

    const P = window.NymbotConfig.storagePrefix;
    const MSG_CAP = 400;

    function read(key, fallback) {
        try {
            const raw = localStorage.getItem(P + key);
            return raw == null ? fallback : JSON.parse(raw);
        } catch (_) { return fallback; }
    }

    function write(key, value) {
        try {
            localStorage.setItem(P + key, JSON.stringify(value));
            return true;
        } catch (_) { return false; }
    }

    function drop(key) {
        try { localStorage.removeItem(P + key); } catch (_) { }
    }

    function uid() {
        const b = crypto.getRandomValues(new Uint8Array(8));
        return Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('');
    }

    const Store = {
        uid,
        read,
        write,
        drop,

        // --- identity ------------------------------------------------------
        // `secret` is the hex nsec for a local key, absent for a signer login.
        // When the vault is on it is replaced by `vault`, and the plaintext key
        // lives only in memory for the session.
        identity() { return read('identity', null); },
        setIdentity(id) { return write('identity', id); },
        clearIdentity() { drop('identity'); },

        // --- settings ------------------------------------------------------
        settings() {
            return Object.assign({
                tier: 'standard',
                proModel: null,
                git: null,
                anon: false,
                theme: 'system'
            }, read('settings', {}));
        },
        setSettings(patch) {
            const next = Object.assign(this.settings(), patch);
            write('settings', next);
            return next;
        },

        // --- conversations -------------------------------------------------
        conversations() {
            const list = read('conversations', []);
            return Array.isArray(list) ? list : [];
        },

        saveConversations(list) {
            write('conversations', list.slice(0, 200));
        },

        conversation(id) {
            return this.conversations().find(c => c.id === id) || null;
        },

        createConversation() {
            const conv = { id: uid(), title: '', createdAt: Date.now(), updatedAt: Date.now() };
            const list = this.conversations();
            list.unshift(conv);
            this.saveConversations(list);
            return conv;
        },

        updateConversation(id, patch) {
            const list = this.conversations();
            const i = list.findIndex(c => c.id === id);
            if (i === -1) return null;
            list[i] = Object.assign(list[i], patch, { updatedAt: Date.now() });
            const conv = list[i];
            list.splice(i, 1);
            list.unshift(conv);
            this.saveConversations(list);
            return conv;
        },

        deleteConversation(id) {
            this.saveConversations(this.conversations().filter(c => c.id !== id));
            drop('msgs_' + id);
            drop('thread_' + id);
        },

        // --- messages ------------------------------------------------------
        messages(convId) {
            const list = read('msgs_' + convId, []);
            return Array.isArray(list) ? list : [];
        },

        saveMessages(convId, list) {
            write('msgs_' + convId, list.slice(-MSG_CAP));
        },

        addMessage(convId, msg) {
            const list = this.messages(convId);
            list.push(msg);
            this.saveMessages(convId, list);
            return msg;
        },

        patchMessage(convId, msgId, patch) {
            const list = this.messages(convId);
            const i = list.findIndex(m => m.id === msgId);
            if (i === -1) return null;
            list[i] = Object.assign(list[i], patch);
            this.saveMessages(convId, list);
            return list[i];
        },

        // The wrap ids this conversation is made of, in order. The worker keeps
        // its own thread per pubkey, so switching conversations means telling it
        // to forget that one and replaying this one's history from here.
        thread(convId) {
            const ids = read('thread_' + convId, []);
            return Array.isArray(ids) ? ids : [];
        },

        setThread(convId, ids) {
            write('thread_' + convId, ids.slice(-40));
        },

        // Everything, gone. Not a logout: there is nothing on a server to log
        // out of, so this is the only kind of deletion there is.
        wipe() {
            const keys = [];
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                if (k && k.startsWith(P)) keys.push(k);
            }
            for (const k of keys) localStorage.removeItem(k);
        }
    };

    window.NymbotStore = Store;
})();
