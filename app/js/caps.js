(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;

    const num = (v) => window.NymbotI18n.count(v);
    const $ = (id) => document.getElementById(id);

    function positive(v) {
        const n = Number(v);
        return Number.isFinite(n) && n > 0 ? Math.floor(n) : null;
    }

    function stricter(a, b) {
        const x = positive(a);
        const y = positive(b);
        if (x == null) return y;
        if (y == null) return x;
        return Math.min(x, y);
    }

    function isPro(m) {
        return m.pro === true || (m.pro == null && !!m.model);
    }

    const Caps = {
        TOTAL: 'capSats',
        PER_REPLY: 'askAboveSats',
        SPENT: 'sats',

        _ui: null,
        _conv: null,
        _resolve: null,

        rates(pricing) {
            const tier = pricing && pricing.satsPerCreditTier;
            return {
                standard: Number(tier && tier.standard) || C.satsPerCredit.standard,
                pro: Number(tier && tier.pro) || C.satsPerCredit.pro
            };
        },

        satsFor(credits, pro, pricing) {
            return (Number(credits) || 0) * this.rates(pricing)[pro ? 'pro' : 'standard'];
        },

        botOf(conv) {
            const Bots = window.NymbotBots;
            return conv && conv.botId && Bots ? Bots.get(conv.botId) : null;
        },

        limits(conv) {
            const bot = this.botOf(conv);
            const own = conv || {};
            const total = stricter(own[this.TOTAL], bot && bot[this.TOTAL]);
            const perReply = stricter(own[this.PER_REPLY], bot && bot[this.PER_REPLY]);
            return {
                total,
                perReply,
                totalFromBot: total != null && positive(own[this.TOTAL]) !== total,
                perReplyFromBot: perReply != null && positive(own[this.PER_REPLY]) !== perReply,
                bot
            };
        },

        any(conv) {
            const lim = this.limits(conv);
            return lim.total != null || lim.perReply != null;
        },

        legacySpent(conv, pricing) {
            const credits = Number(conv && conv.stats && conv.stats.credits) || 0;
            if (!(credits > 0)) return 0;
            let sats = 0;
            let paid = 0;
            for (const m of Store.messages(conv.id)) {
                if (m.role !== 'bot' || !(m.cost > 0)) continue;
                sats += this.satsFor(m.cost, isPro(m), pricing);
                paid += m.cost;
            }
            const rate = paid > 0 ? sats / paid : this.rates(pricing).standard;
            return credits * rate;
        },

        spent(conv, pricing) {
            const held = conv && conv.stats && conv.stats[this.SPENT];
            if (typeof held === 'number' && Number.isFinite(held)) return held;
            return conv ? this.legacySpent(conv, pricing) : 0;
        },

        nextSpent(conv, cost, pro, pricing) {
            return Math.round((this.spent(conv, pricing) + this.satsFor(cost, pro, pricing)) * 1000) / 1000;
        },

        room(conv, pricing) {
            const lim = this.limits(conv);
            return lim.total == null ? null : Math.max(0, lim.total - this.spent(conv, pricing));
        },

        estimate(ui, text, conv, opts) {
            const media = ui.mediaModel(conv);
            const model = (conv && conv.proModel) || ui.settings.proModel;
            if (media && String(text || '').trim() && !/^[?!]/.test(String(text).trim())
                && Number(media.credits) > 0) {
                const credits = Number(media.max) > 0 ? Number(media.max) : Number(media.credits);
                return { tier: (model || media.proKey) ? 'pro' : 'standard', low: Number(media.credits), high: credits };
            }
            return window.NymbotChat.estimateCredits(text, ui.settings, conv, opts, ui.models);
        },

        check(conv, est, pricing) {
            const lim = this.limits(conv);
            const spent = this.spent(conv, pricing);
            const pro = !!est && est.tier === 'pro';
            const high = est ? this.satsFor(est.high, pro, pricing) : 0;
            const out = {
                limits: lim, spent, high, pro,
                room: lim.total == null ? null : Math.max(0, lim.total - spent),
                state: 'ok', reason: null
            };
            if (lim.total != null && spent >= lim.total) {
                out.state = 'block';
                out.reason = 'total';
            } else if (lim.total != null && spent + high > lim.total) {
                out.state = 'ask';
                out.reason = 'total';
            } else if (lim.perReply != null && high > lim.perReply) {
                out.state = 'ask';
                out.reason = 'reply';
            }
            return out;
        },

        maxCost(conv, pro, pricing) {
            const lim = this.limits(conv);
            let sats = lim.perReply;
            if (lim.total != null) {
                const room = Math.max(0, lim.total - this.spent(conv, pricing));
                sats = sats == null ? room : Math.min(sats, room);
            }
            if (sats == null) return null;
            const credits = Math.floor(sats / this.rates(pricing)[pro ? 'pro' : 'standard'] * 1000) / 1000;
            return Math.max(0.001, credits);
        },

        usedLine(conv, pricing) {
            const lim = this.limits(conv);
            if (lim.total == null) return '';
            return t('{n} of {m} sats used', {
                n: num(Math.round(this.spent(conv, pricing))), m: num(lim.total)
            });
        },

        roomLine(conv, pricing) {
            const room = this.room(conv, pricing);
            if (room == null) return '';
            return room <= 0
                ? t('this chat is at its cap')
                : t('{n} sats left under this chat\'s cap', { n: num(Math.floor(room)) });
        },

        renderBadge(ui) {
            const badge = $('chatCap');
            if (!badge) return;
            const conv = ui && ui.conv;
            const line = conv ? this.usedLine(conv, ui.models) : '';
            badge.textContent = line;
            badge.hidden = !line;
            const room = conv ? this.room(conv, ui.models) : null;
            badge.classList.toggle('is-full', room != null && room <= 0);
        },

        askBody(check, est) {
            const pro = check.pro;
            const credits = est ? est.high : 0;
            const estimate = t('{sats} sats ({n} {tier} credits)', {
                sats: num(Math.ceil(check.high)),
                n: window.amount ? window.amount(credits, 2) : String(credits),
                tier: pro ? t('Pro') : t('standard')
            });
            if (check.reason === 'total') {
                return t('This reply could cost up to {estimate}. The chat has used {spent} of its {cap} sat cap, so it could go past it.', {
                    estimate,
                    spent: num(Math.round(check.spent)),
                    cap: num(check.limits.total)
                });
            }
            return t('This reply could cost up to {estimate}, more than the {cap} sats you asked to be warned above.', {
                estimate,
                cap: num(check.limits.perReply)
            });
        },

        confirm(options) {
            const o = options || {};
            this.settle('cancel');
            $('capDialogTitle').textContent = o.title || '';
            $('capDialogBody').textContent = o.body || '';
            $('capSendOnce').hidden = !o.sendOnce;
            $('capScrim').hidden = false;
            $('capDialog').hidden = false;
            ($('capSendOnce').hidden ? $('capRaise') : $('capSendOnce')).focus();
            return new Promise((resolve) => { this._resolve = resolve; });
        },

        settle(choice) {
            const resolve = this._resolve;
            this._resolve = null;
            if ($('capDialog')) $('capDialog').hidden = true;
            if ($('capScrim')) $('capScrim').hidden = true;
            if (resolve) resolve(choice);
        },

        async gate(ui, conv, est, opts) {
            const o = opts || {};
            const check = this.check(conv, est, ui.models);
            if (check.state === 'ok') return { go: true, check };
            if (o.unattended) {
                ui.note(check.state === 'block'
                    ? t('Not sent: this chat has reached its spending cap.')
                    : t('Not sent: this reply could go past the chat\'s spending cap, and nobody was here to agree to it.'), conv.id);
                return { go: false, check };
            }
            const choice = check.state === 'block'
                ? await this.confirm({
                    title: t('This chat has reached its cap'),
                    body: t('It has used {spent} of the {cap} sats you set for it. Raise the cap to keep going.', {
                        spent: num(Math.round(check.spent)), cap: num(check.limits.total)
                    }),
                    sendOnce: false
                })
                : await this.confirm({
                    title: t('Over this chat\'s cap?'),
                    body: this.askBody(check, est),
                    sendOnce: true
                });
            if (choice === 'raise') this.openEditor(ui, conv);
            return { go: choice === 'send', waived: choice === 'send', check };
        },

        async refused(ui, conv, err) {
            const required = Number(err.required) || 0;
            const pro = !!err.pro;
            const vars = {
                sats: num(Math.ceil(this.satsFor(required, pro, ui.models))),
                n: window.amount ? window.amount(required, 2) : String(required),
                tier: pro ? t('Pro') : t('standard')
            };
            const choice = await this.confirm({
                title: t('Over this chat\'s cap?'),
                body: err.team
                    ? t('Team mode holds up to {sats} sats ({n} {tier} credits) for this reply, more than the cap allows. Nothing was sent to a model and nothing was charged. Raise the cap, use fewer or cheaper workers, or send it once anyway.', vars)
                    : t('Nymbot holds up to {sats} sats ({n} {tier} credits) for this reply, more than the cap allows. Nothing was charged.', vars),
                sendOnce: true
            });
            if (choice === 'raise') this.openEditor(ui, conv);
            return choice;
        },

        openEditor(ui, conv) {
            this._ui = ui;
            const target = conv || ui.conv;
            if (!target) return;
            this._conv = target.id;
            $('capTotal').value = positive(target[this.TOTAL]) != null ? String(positive(target[this.TOTAL])) : '';
            $('capReply').value = positive(target[this.PER_REPLY]) != null ? String(positive(target[this.PER_REPLY])) : '';
            const lim = this.limits(target);
            const bits = [];
            const used = t('Spent here so far: {n} sats.', { n: num(Math.round(this.spent(target, ui.models))) });
            bits.push(used);
            if (lim.bot && (positive(lim.bot[this.TOTAL]) != null || positive(lim.bot[this.PER_REPLY]) != null)) {
                bits.push(t('{bot} also sets caps; the stricter of the two applies.', { bot: lim.bot.name || t('This bot') }));
            }
            $('capUsed').textContent = bits.join(' ');
            ui.modalStatus('capStatus', '');
            ui.openModal('modalCaps');
            $('capTotal').focus();
        },

        readField(id) {
            const raw = String($(id).value || '').trim();
            if (!raw) return { value: null };
            const n = Number(raw);
            if (!Number.isFinite(n) || n < 0) return { error: true };
            return { value: n > 0 ? Math.floor(n) : null };
        },

        saveEditor() {
            const ui = this._ui;
            const conv = this._conv ? Store.conversation(this._conv) : null;
            if (!ui || !conv) return;
            const total = this.readField('capTotal');
            const reply = this.readField('capReply');
            if (total.error || reply.error) {
                ui.modalStatus('capStatus', t('Caps are whole numbers of sats.'), 'warn');
                return;
            }
            const patch = {};
            patch[this.TOTAL] = total.value;
            patch[this.PER_REPLY] = reply.value;
            ui.patchChat(conv, patch);
            this.renderBadge(ui);
            ui.updateHints();
            ui.closeModals();
            ui.toast(total.value == null && reply.value == null ? t('Caps removed.') : t('Caps saved.'));
        },

        clearEditor() {
            $('capTotal').value = '';
            $('capReply').value = '';
            this.saveEditor();
        },

        fillBotForm(bot) {
            $('botCapTotal').value = bot && positive(bot[this.TOTAL]) != null ? String(positive(bot[this.TOTAL])) : '';
            $('botCapReply').value = bot && positive(bot[this.PER_REPLY]) != null ? String(positive(bot[this.PER_REPLY])) : '';
        },

        readBotForm() {
            const total = this.readField('botCapTotal');
            const reply = this.readField('botCapReply');
            if (total.error || reply.error) return null;
            const out = {};
            out[this.TOTAL] = total.value;
            out[this.PER_REPLY] = reply.value;
            return out;
        },

        bind() {
            if (!$('capDialog')) return;
            $('capSendOnce').addEventListener('click', () => this.settle('send'));
            $('capRaise').addEventListener('click', () => this.settle('raise'));
            $('capCancel').addEventListener('click', () => this.settle('cancel'));
            $('capScrim').addEventListener('click', () => this.settle('cancel'));
            $('capDialog').addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { e.stopPropagation(); this.settle('cancel'); }
            });
            $('capSave').addEventListener('click', () => this.saveEditor());
            $('capClear').addEventListener('click', () => this.clearEditor());
        }
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => Caps.bind());
    } else {
        Caps.bind();
    }

    window.NymbotCaps = Caps;
})();
