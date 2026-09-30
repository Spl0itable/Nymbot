// A per-device speed bump only; never report it to the worker, which would link a person's keys.
(function () {
    'use strict';

    const KEY = 'nymbot_free_device';

    // UTC, matching the worker's reset.
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
            // Fails open: the worker enforces the allowance.
            return { day: today(), used: 0 };
        }
    }

    function write(state) {
        try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (_) { }
    }

    const Free = {
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

        /// A paid balance is never gated by this.
        allows(limit, balance) {
            if (balance > 0) return true;
            const cap = Math.max(0, Math.floor(limit) || 0);
            if (!cap) return true;
            return read().used < cap;
        },

        spent() {
            const here = read();
            write({ day: here.day, used: here.used + 1 });
            return here.used + 1;
        },

        /// Adopts a higher worker count but never revises downwards, so a fresh key cannot reset the device.
        observe(used) {
            const n = Math.floor(used);
            if (!(n > 0)) return;
            const here = read();
            if (n > here.used) write({ day: here.day, used: n });
        },

        forget() {
            try { localStorage.removeItem(KEY); } catch (_) { }
        }
    };

    window.NymbotFree = Free;
})();
