(function () {
    'use strict';

    const COMMAND = /^\s*\?research\b[ \t]*/i;
    let armed = false;
    let loading = null;

    function command(text) {
        const s = String(text || '');
        if (!COMMAND.test(s)) return null;
        return s.replace(COMMAND, '').trim();
    }

    function pinned(ui, conv) {
        const c = conv || ui.conv || {};
        return c.proModel || (ui.settings && ui.settings.proModel) || null;
    }

    function entryFor(ui, model) {
        if (!model || !ui.models || !Array.isArray(ui.models.models)) return null;
        return ui.models.models.find(m => m.key === model.key) || null;
    }

    function estimate(entry) {
        const r = entry && entry.research;
        if (!r) return null;
        const low = Math.max(0, Math.round(Number(r.low) || 0));
        const high = Math.max(low, Math.round(Number(r.high) || 0));
        const max = Math.max(high, Math.round(Number(r.max) || 0));
        return max > 0 ? { low, high, max } : null;
    }

    function ensureModels(ui) {
        if (ui.models || loading) return;
        loading = window.NymbotApi.models().then((data) => {
            if (data && data.models) ui.models = data;
            loading = null;
            ui.updateHints();
        }, () => { loading = null; });
    }

    function needsPro() {
        return t('Deep research needs a Pro model: it runs many searches and model calls. Pick one with ?model first.');
    }

    function priceLine(model, est) {
        if (!est) return t('Deep research with {model}', { model: model.label || model.key });
        if (est.low === est.high) {
            return t('Deep research with {model} · about {n} Pro credits, up to {max}',
                { model: model.label || model.key, n: est.low, max: est.max });
        }
        return t('Deep research with {model} · about {low}–{high} Pro credits, up to {max}',
            { model: model.label || model.key, low: est.low, high: est.high, max: est.max });
    }

    function hint(ui, text) {
        const typed = command(text);
        if (!armed && !(typed && typed.length)) return '';
        const model = pinned(ui);
        if (!model) return needsPro();
        ensureModels(ui);
        return priceLine(model, estimate(entryFor(ui, model)));
    }

    function payload(ui, conv) {
        const est = estimate(entryFor(ui, pinned(ui, conv)));
        return est ? { max: est.max } : true;
    }

    function toggle(ui) {
        if (!armed && !pinned(ui)) {
            ui.toast(needsPro());
            return;
        }
        armed = !armed;
        ui.refreshToolbar();
        if (armed) {
            ensureModels(ui);
            ui.toast(t('Research is on for your next message. It searches, reads and writes a report with sources.'));
        }
    }

    function handle(ui, arg) {
        if (!pinned(ui)) {
            ui.note(needsPro());
            return true;
        }
        if (arg) return false;
        if (!armed) toggle(ui);
        return true;
    }

    function claim(ui, conv, typed) {
        const asked = command(typed);
        if (asked == null && !armed) return null;
        const question = asked != null ? asked : typed;
        if (armed) {
            armed = false;
            ui.refreshToolbar();
        }
        if (!pinned(ui, conv)) return { blocked: needsPro() };
        if (!question) return { blocked: t('Say what to research after ?research.') };
        return { question, payload: payload(ui, conv) };
    }

    function refreshChip(ui) {
        const chip = document.getElementById('chipResearch');
        if (!chip) return;
        chip.classList.toggle('is-active', armed);
        const label = chip.querySelector('.chip-label');
        if (label) label.textContent = t('Research');
    }

    function host(value) {
        return String(value || '').replace(/^www\./, '');
    }

    function stepLine(step) {
        if (!step || step.kind !== 'research') return '';
        switch (step.stage) {
            case 'plan': return t('Planning the research');
            case 'planned': return t('Planned {n} questions to answer', { n: step.subs || 0 });
            case 'resume': return t('Picking the research back up');
            case 'search':
                return step.news
                    ? t('Searching the news for “{query}”', { query: step.query || '' })
                    : t('Searching for “{query}”', { query: step.query || '' });
            case 'read': return t('Reading {host}', { host: host(step.host) });
            case 'note':
                return step.found
                    ? t('Noted {n} findings', { n: step.found })
                    : t('Nothing new on that round');
            case 'write': return t('Writing the report from {n} sources', { n: step.sources || 0 });
            case 'pause': return t('Pausing here to carry on in a new step');
            default: return '';
        }
    }

    function isResearchStep(step) {
        return !!(step && step.kind === 'research');
    }

    function stepList(lines, empty, finished) {
        const list = document.createElement('ol');
        list.className = 'research-steps';
        if (!lines.length) {
            const li = document.createElement('li');
            li.className = 'research-step is-current';
            li.textContent = empty;
            list.appendChild(li);
        }
        lines.forEach((item, i) => {
            const li = document.createElement('li');
            const current = !finished && i === lines.length - 1;
            li.className = 'research-step' + (current ? ' is-current' : ' is-done')
                + ' is-' + item.stage;
            li.textContent = item.line;
            list.appendChild(li);
        });
        return list;
    }

    function render(box, steps) {
        box.innerHTML = '';
        const lines = [];
        for (const step of steps || []) {
            if (!isResearchStep(step)) continue;
            const line = stepLine(step);
            if (!line || (lines.length && lines[lines.length - 1].line === line)) continue;
            lines.push({ line, stage: step.stage });
        }
        box.appendChild(stepList(lines, t('Starting the research')));
    }

    function helpTopic() {
        return {
            title: t('Deep research'),
            body: t('Turn on the Research chip, or start a message with ?research, and the next message becomes a research task for the pinned Pro model. It plans the questions to answer, searches the web in several rounds with different phrasings, reads the most promising pages, and writes a long report with numbered sources you can open. The composer says what it will probably cost and the most it can cost before you send; it is charged on the tokens it actually uses and nothing if it fails. The chip turns itself off after one message. A long run may pause and carry on in a second step within the same ceiling.')
        };
    }

    window.NymbotResearch = {
        command,
        estimate,
        hint,
        payload,
        toggle,
        handle,
        claim,
        refreshChip,
        stepLine,
        render,
        stepList,
        helpTopic,
        get armed() { return armed; },
        reset() { armed = false; }
    };
})();
