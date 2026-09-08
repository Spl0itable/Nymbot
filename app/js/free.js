// The free daily allowance, as this device sees it.
//
// The real count is the worker's: it is claimed under the same lock every
// balance moves under, and nothing here can grant a reply the worker will not.
// What this adds is a count of what THIS DEVICE has used today, whatever key
// was signed in at the time — because the server's count is keyed to a pubkey,
// and generating another pubkey is a keystroke in this app's own gate.
//
// It is deliberately a speed bump and not a control. Anyone who opens devtools
// or clears site data walks straight past it, and that is fine: the point is
// that "log out, make a new key, keep going" does not work by simply doing it.
//
// The one thing it must never do is tell the worker about itself. A device
// counter reported to the server would link a person's keys to each other,
// which is the exact thing this app is built not to do — a stronger cap bought
// with the product's whole premise. So it stays here, the client declines to
// offer a free reply, and the worker never learns a device exists.
(function () {
    'use strict';

    const KEY = 'nymbot_free_device';

    // The day is UTC, because that is what the worker resets on and two
    // different midnights would be worse than one inconvenient one.
    function today() {
        return new Date().toISOString().slice(0, 10);
    }

    function read() {
        try {
            const raw = localStorage.getItem(KEY);
            if (!raw) return { day: today(), used: 0 };
            const held = JSON.parse(raw);
            if (!held || held.day !== today()) return { day: today(), used: 0 };
            return { day: held.day, used: Math.max(0, Math.floor(held.used) || 0) };
        } catch (_) {
            // Private mode, cleared storage, a browser that refuses: the
            // allowance is the worker's to enforce, so this failing open is
            // the right way for it to fail.
            return { day: today(), used: 0 };
        }
    }

    function write(state) {
        try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (_) { }
    }

    const Free = {
        /// What this device has spent today, and what the worker last said was
        /// left on the key that is signed in. The lower of the two is what the
        /// app offers.
        state(limit) {
            const cap = Math.max(0, Math.floor(limit) || 0);
            const here = read();
            return {
                used: here.used,
                limit: cap,
                left: cap ? Math.max(0, cap - here.used) : 0,
                resetsAt: Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(),
                    new Date().getUTCDate() + 1)
            };
        },

        /// Whether this device still has a free reply in it. A balance is
        /// never gated by this: someone who has paid is not on the free tier
        /// at all, and must never be told they are.
        allows(limit, balance) {
            if (balance > 0) return true;
            const cap = Math.max(0, Math.floor(limit) || 0);
            if (!cap) return true;
            return read().used < cap;
        },

        /// One free reply came back. Counted here whichever key asked for it.
        spent() {
            const here = read();
            write({ day: here.day, used: here.used + 1 });
            return here.used + 1;
        },

        /// The worker is the authority on the key's own count, so when it says
        /// more has been used than this device has seen, this device believes
        /// it — a second device, or the same one after its storage was
        /// cleared. It never revises the count downwards, which is what would
        /// make a fresh key reset the device.
        observe(used) {
            const n = Math.floor(used);
            if (!(n > 0)) return;
            const here = read();
            if (n > here.used) write({ day: here.day, used: n });
        },

        /// Only for a test, or for someone who asked to be forgotten.
        forget() {
            try { localStorage.removeItem(KEY); } catch (_) { }
        }
    };

    window.NymbotFree = Free;
})();
