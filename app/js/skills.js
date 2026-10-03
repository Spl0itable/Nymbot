(function () {
    'use strict';

    const NAME_MAX = 60;
    const DESCRIPTION_MAX = 160;
    const BODY_MAX = 8000;
    const SLUG_MAX = 40;
    const MAX_SKILLS = 100;
    const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
    const KEY = 'skills';

    const BUILTIN = [
        {
            id: 'builtin-summarize',
            name: 'Summarize this thread',
            description: 'The decisions, open questions and next steps so far',
            body: 'Summarize this conversation so far for someone who has not read it. Start with a one-sentence overview, then list the decisions made, the open questions and the agreed next steps as short bullet points. Keep every name, number and date exactly as written. Do not add anything that was not said.'
        },
        {
            id: 'builtin-code-review',
            name: 'Code review',
            description: 'Real defects first, each with the case that breaks it',
            body: 'Review the code in this message as a demanding senior reviewer. Report only real defects and concrete simplifications, most severe first. For each one give the file or line, what goes wrong, a concrete input or scenario that triggers it, and the smallest fix. Skip praise, style nits and a summary of what the code does. If you find nothing wrong, say so in one line.'
        },
        {
            id: 'builtin-release-notes',
            name: 'Write release notes',
            description: 'User-facing notes from changes or a diff',
            body: 'Write release notes from the changes in this message for the people who use the product, not its developers. Group them under New, Improved and Fixed, leaving out empty groups. One line per change, in plain words that say what the user can now do or what no longer goes wrong. Leave out internal refactors, dependency bumps and anything a user would never notice.'
        },
        {
            id: 'builtin-explain-new',
            name: 'Explain like I\'m new',
            description: 'Plain words, one example, no jargon',
            body: 'Explain the topic in this message to someone who is new to it. Start from what they already know from everyday life, use one concrete example before any definition, and replace every piece of jargon with plain words, or define it the first time it appears. Keep it short, then end with the one idea they should remember.'
        }
    ];

    function lowerAscii(s) {
        return String(s).replace(/[A-Z]/g, c => String.fromCharCode(c.charCodeAt(0) + 32));
    }

    function clean(v) {
        let s = typeof v === 'string' ? v : '';
        s = s.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').replace(/\s+/g, ' ').replace(/^ +| +$/g, '');
        return s;
    }

    function cleanBody(v) {
        const s = typeof v === 'string' ? v : '';
        return s.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').replace(/^\s+|\s+$/g, '');
    }

    function normalize(raw) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'name' };
        const name = clean(raw.name);
        if (!name) return { error: 'name' };
        if (name.length > NAME_MAX) return { error: 'name-long' };
        const description = clean(raw.description);
        if (description.length > DESCRIPTION_MAX) return { error: 'description-long' };
        const body = cleanBody(raw.body);
        if (!body) return { error: 'body' };
        if (body.length > BODY_MAX) return { error: 'body-long' };
        const order = Number.isInteger(raw.order) && raw.order >= 0 ? raw.order : 0;
        const updatedAt = typeof raw.updatedAt === 'number' && Number.isFinite(raw.updatedAt) && raw.updatedAt > 0 ? Math.floor(raw.updatedAt) : 0;
        return {
            skill: {
                id: typeof raw.id === 'string' && ID_RE.test(raw.id) ? raw.id : '',
                name, description, body, order, updatedAt
            }
        };
    }

    function slug(name) {
        let s = lowerAscii(name).replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
        if (s.length > SLUG_MAX) s = s.slice(0, SLUG_MAX).replace(/-+$/g, '');
        return s;
    }

    function slugOf(skill) {
        return slug(skill && skill.name) || ('skill-' + lowerAscii(String((skill && skill.id) || '')).replace(/[^a-z0-9]/g, '').slice(0, 8));
    }

    function ordered(list) {
        return (Array.isArray(list) ? list : []).map((s, i) => ({ s, i })).sort((a, b) => (a.s.order - b.s.order) || (a.i - b.i)).map(x => x.s);
    }

    function catalog(own) {
        return ordered(own).concat(BUILTIN);
    }

    function invocation(text, list) {
        const m = /^\/([A-Za-z0-9-]{1,48})(?=\s|$)/.exec(typeof text === 'string' ? text : '');
        if (!m) return null;
        const want = lowerAscii(m[1]);
        const hit = (list || []).find(s => slugOf(s) === want);
        if (!hit) return null;
        return { id: hit.id, rest: text.slice(m[0].length).replace(/^\s+|\s+$/g, '') };
    }

    function block(skill) {
        return '[skill: ' + skill.name + ']\n' + skill.body;
    }

    function score(skill, term) {
        if (!term) return 1;
        const s = slugOf(skill);
        if (s === term) return 1000;
        if (s.startsWith(term)) return 500 - s.length;
        if (s.includes(term)) return 200 - s.length;
        if (lowerAscii(skill.name).includes(term)) return 100;
        if (lowerAscii(skill.description || '').includes(term)) return 50;
        return 0;
    }

    function match(term, list, limit) {
        const needle = lowerAscii(String(term || '')).replace(/^\//, '').replace(/^\s+|\s+$/g, '');
        return (list || []).map((s, i) => ({ s, i, n: score(s, needle) }))
            .filter(x => x.n > 0)
            .sort((a, b) => (b.n - a.n) || (a.i - b.i))
            .slice(0, limit || 8)
            .map(x => x.s);
    }

    function move(list, id, delta) {
        const out = ordered(list).slice();
        const at = out.findIndex(s => s.id === id);
        if (at < 0) return out.map((s, i) => Object.assign({}, s, { order: i }));
        const to = Math.max(0, Math.min(out.length - 1, at + delta));
        const [item] = out.splice(at, 1);
        out.splice(to, 0, item);
        return out.map((s, i) => Object.assign({}, s, { order: i }));
    }

    const Store = () => window.NymbotStore;

    function own() {
        const raw = Store().read(KEY, []);
        return ordered(Array.isArray(raw) ? raw.filter(s => s && typeof s === 'object' && typeof s.id === 'string' && s.id) : []);
    }

    function errorText(code) {
        switch (code) {
            case 'name': return t('Give the skill a name.');
            case 'name-long': return t('A skill name can be at most {n} characters.', { n: NAME_MAX });
            case 'description-long': return t('A skill description can be at most {n} characters.', { n: DESCRIPTION_MAX });
            case 'body': return t('Write the instructions the skill gives Nymbot.');
            case 'body-long': return t('Skill instructions can be at most {n} characters.', { n: BODY_MAX });
            case 'full': return t('You can keep up to {n} skills.', { n: MAX_SKILLS });
            default: return t('That skill could not be saved.');
        }
    }

    function builtinName(s) {
        switch (s.id) {
            case 'builtin-summarize': return t('Summarize this thread');
            case 'builtin-code-review': return t('Code review');
            case 'builtin-release-notes': return t('Write release notes');
            case 'builtin-explain-new': return t('Explain like I\'m new');
            default: return s.name;
        }
    }

    function builtinDescription(s) {
        switch (s.id) {
            case 'builtin-summarize': return t('The decisions, open questions and next steps so far');
            case 'builtin-code-review': return t('Real defects first, each with the case that breaks it');
            case 'builtin-release-notes': return t('User-facing notes from changes or a diff');
            case 'builtin-explain-new': return t('Plain words, one example, no jargon');
            default: return s.description || '';
        }
    }

    const Skills = {
        NAME_MAX, DESCRIPTION_MAX, BODY_MAX, MAX_SKILLS, BUILTIN,
        normalize, slug, slugOf, invocation, block, match, move, ordered, catalog, errorText,

        isBuiltin(id) { return BUILTIN.some(s => s.id === id); },
        own,
        all() { return catalog(own()); },
        get(id) { return id ? (this.all().find(s => s.id === id) || null) : null; },
        label(s) { return s && this.isBuiltin(s.id) ? builtinName(s) : (s ? s.name : ''); },
        describe(s) { return s && this.isBuiltin(s.id) ? builtinDescription(s) : (s ? s.description || '' : ''); },

        save(raw) {
            const got = normalize(raw);
            if (got.error) return got;
            const list = own();
            const skill = got.skill;
            const at = skill.id ? list.findIndex(s => s.id === skill.id) : -1;
            if (at < 0 && list.length >= MAX_SKILLS) return { error: 'full' };
            if (!skill.id || this.isBuiltin(skill.id)) skill.id = Store().uid();
            skill.updatedAt = Date.now();
            if (at < 0) {
                skill.order = list.length ? Math.max(...list.map(s => s.order || 0)) + 1 : 0;
                list.push(skill);
            } else {
                skill.order = list[at].order || 0;
                list[at] = skill;
            }
            Store().write(KEY, list);
            return { skill };
        },

        duplicate(id) {
            const from = this.get(id);
            if (!from) return { error: 'name' };
            const name = this.label(from);
            const copy = this.isBuiltin(id) ? name : t('{name} (copy)', { name });
            return this.save({ name: copy.slice(0, NAME_MAX), description: this.describe(from), body: from.body });
        },

        remove(id) {
            if (this.isBuiltin(id)) return false;
            const list = own();
            if (!list.some(s => s.id === id)) return false;
            Store().bury(id);
            Store().write(KEY, list.filter(s => s.id !== id));
            for (const conv of Store().conversations()) {
                if (conv.skillId === id) Store().updateConversation(conv.id, { skillId: null });
            }
            return true;
        },

        reorder(id, delta) {
            const now = Date.now();
            const next = move(own(), id, delta).map(s => Object.assign(s, { updatedAt: now }));
            Store().write(KEY, next);
            return next;
        },

        forConv(conv) {
            return conv && conv.skillId ? this.get(conv.skillId) : null;
        },

        wire(conv, text) {
            const used = invocation(text, this.all());
            const skill = used ? this.get(used.id) : null;
            const attached = this.forConv(conv);
            const blocks = [];
            if (attached) blocks.push(block(attached));
            if (skill && (!attached || attached.id !== skill.id)) blocks.push(block(skill));
            return { text: skill ? (used.rest || skill.name) : text, blocks, skill };
        },

        open(ui, filter) {
            this.editing = null;
            this.resetForm(ui);
            const search = document.getElementById('skillSearch');
            if (search) {
                search.value = filter || '';
                if (!search.dataset.bound) {
                    search.dataset.bound = '1';
                    search.addEventListener('input', () => this.render(ui));
                }
            }
            const body = document.getElementById('skillBody');
            if (body && !body.dataset.bound) {
                body.dataset.bound = '1';
                body.addEventListener('input', () => this.count());
            }
            this.render(ui);
            ui.openModal('modalSkills');
        },

        count() {
            const body = document.getElementById('skillBody');
            const out = document.getElementById('skillCount');
            if (!body || !out) return;
            const n = body.value.length;
            out.textContent = n ? t('{n} of {max} characters', { n: n.toLocaleString(), max: BODY_MAX.toLocaleString() }) : '';
        },

        button(label, role, run, opts) {
            const o = opts || {};
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'row-btn' + (o.danger ? ' danger' : '');
            b.textContent = label;
            b.dataset.role = role;
            if (o.aria) b.setAttribute('aria-label', o.aria);
            if (o.pressed != null) b.setAttribute('aria-pressed', String(!!o.pressed));
            if (o.disabled) b.disabled = true;
            b.addEventListener('click', run);
            return b;
        },

        render(ui) {
            const list = document.getElementById('skillList');
            if (!list) return;
            const term = ((document.getElementById('skillSearch') || {}).value || '').trim();
            const all = this.all();
            const shown = term ? match(term, all, all.length) : all;
            const mine = own();
            const attached = ui.conv ? ui.conv.skillId : null;
            list.innerHTML = '';
            for (const skill of shown) {
                const builtin = this.isBuiltin(skill.id);
                const name = this.label(skill);
                const row = document.createElement('div');
                row.className = 'skill-row' + (attached === skill.id ? ' is-on' : '');
                row.dataset.id = skill.id;
                const main = document.createElement('div');
                main.className = 'skill-main';
                const head = document.createElement('span');
                head.className = 'skill-name';
                head.textContent = name;
                if (builtin) {
                    const tag = document.createElement('span');
                    tag.className = 'skill-tag';
                    tag.textContent = t('Built-in');
                    head.appendChild(tag);
                }
                if (attached === skill.id) {
                    const tag = document.createElement('span');
                    tag.className = 'skill-tag is-on';
                    tag.textContent = t('On in this chat');
                    head.appendChild(tag);
                }
                main.appendChild(head);
                const code = document.createElement('code');
                code.className = 'skill-slug';
                code.textContent = '/' + slugOf(skill);
                main.appendChild(code);
                const about = this.describe(skill);
                if (about) {
                    const sub = document.createElement('span');
                    sub.className = 'skill-sub';
                    sub.textContent = about;
                    main.appendChild(sub);
                }
                row.appendChild(main);
                const actions = document.createElement('div');
                actions.className = 'row-actions';
                actions.appendChild(this.button(t('Run'), 'skill-run', () => this.run(ui, skill.id), { aria: t('Run {name} on the next message', { name }) }));
                if (ui.conv && !ui.conv.support) {
                    const on = attached === skill.id;
                    actions.appendChild(this.button(on ? t('Detach') : t('Attach'), 'skill-attach', () => this.attach(ui, skill.id),
                        { aria: on ? t('Stop using {name} in this chat', { name }) : t('Use {name} on every message in this chat', { name }), pressed: on }));
                }
                actions.appendChild(this.button(t('New chat'), 'skill-new-chat', () => this.newChat(ui, skill.id), { aria: t('Start a new chat with {name}', { name }) }));
                actions.appendChild(this.button(t('Duplicate'), 'skill-duplicate', () => this.copy(ui, skill.id), { aria: t('Duplicate {name}', { name }) }));
                if (!builtin) {
                    const at = mine.findIndex(x => x.id === skill.id);
                    actions.appendChild(this.button(t('Edit'), 'skill-edit', () => this.edit(ui, skill.id), { aria: t('Edit {name}', { name }) }));
                    actions.appendChild(this.button(t('Move up'), 'skill-up', () => this.shift(ui, skill.id, -1), { aria: t('Move {name} up', { name }), disabled: at <= 0 || !!term }));
                    actions.appendChild(this.button(t('Move down'), 'skill-down', () => this.shift(ui, skill.id, 1), { aria: t('Move {name} down', { name }), disabled: at === mine.length - 1 || !!term }));
                    actions.appendChild(this.button(t('Delete'), 'skill-delete', () => this.drop(ui, skill.id), { danger: true, aria: t('Delete {name}', { name }) }));
                }
                row.appendChild(actions);
                list.appendChild(row);
            }
            if (!list.children.length) {
                const p = document.createElement('p');
                p.className = 'hint';
                p.textContent = t('Nothing matches that.');
                list.appendChild(p);
            }
        },

        resetForm(ui) {
            this.editing = null;
            const set = (id, v) => { const n = document.getElementById(id); if (n) n.value = v; };
            set('skillName', '');
            set('skillDescription', '');
            set('skillBody', '');
            const title = document.getElementById('skillFormTitle');
            if (title) title.textContent = t('New skill');
            const save = document.getElementById('skillSaveBtn');
            if (save) save.textContent = t('Save skill');
            const reset = document.getElementById('skillResetBtn');
            if (reset) reset.hidden = true;
            this.count();
            if (ui) ui.modalStatus('skillStatus', '');
        },

        edit(ui, id) {
            const skill = own().find(x => x.id === id);
            if (!skill) return;
            this.editing = id;
            document.getElementById('skillName').value = skill.name;
            document.getElementById('skillDescription').value = skill.description || '';
            document.getElementById('skillBody').value = skill.body;
            document.getElementById('skillFormTitle').textContent = t('Edit skill');
            document.getElementById('skillSaveBtn').textContent = t('Save changes');
            document.getElementById('skillResetBtn').hidden = false;
            this.count();
            ui.modalStatus('skillStatus', '');
            document.getElementById('skillName').focus();
        },

        saveForm(ui) {
            const got = this.save({
                id: this.editing || undefined,
                name: document.getElementById('skillName').value,
                description: document.getElementById('skillDescription').value,
                body: document.getElementById('skillBody').value
            });
            if (got.error) {
                ui.modalStatus('skillStatus', errorText(got.error), 'warn');
                return null;
            }
            this.resetForm(ui);
            this.render(ui);
            ui.refreshToolbar();
            ui.modalStatus('skillStatus', t('Saved. Run it with /{slug}.', { slug: slugOf(got.skill) }), 'ok');
            return got.skill;
        },

        copy(ui, id) {
            const got = this.duplicate(id);
            if (got.error) {
                ui.modalStatus('skillStatus', errorText(got.error), 'warn');
                return;
            }
            this.render(ui);
            this.edit(ui, got.skill.id);
            ui.modalStatus('skillStatus', t('Copied. Edit it below.'), 'ok');
        },

        async drop(ui, id) {
            const skill = this.get(id);
            if (!skill) return;
            const yes = await ui.ask({
                title: t('Delete {name}?', { name: this.label(skill) }),
                body: t('The skill is deleted from this device and from your other devices. Chats that use it stop using it.'),
                confirm: t('Delete'),
                danger: true
            });
            if (!yes) return;
            this.remove(id);
            if (ui.conv) ui.conv = Store().conversation(ui.conv.id) || ui.conv;
            if (this.editing === id) this.resetForm(ui);
            this.render(ui);
            ui.refreshToolbar();
        },

        shift(ui, id, delta) {
            this.reorder(id, delta);
            this.render(ui);
            const row = document.querySelector('#skillList .skill-row[data-id="' + id + '"] [data-role="' + (delta < 0 ? 'skill-up' : 'skill-down') + '"]');
            const fallback = document.querySelector('#skillList .skill-row[data-id="' + id + '"] [data-role="skill-edit"]');
            const target = row && !row.disabled ? row : fallback;
            if (target) target.focus();
        },

        run(ui, id) {
            const skill = this.get(id);
            if (!skill) return;
            ui.closeModals();
            const input = document.getElementById('input');
            const typed = String(input.value || '');
            const used = invocation(typed, this.all());
            const rest = used ? used.rest : typed.replace(/^\s+/, '');
            input.value = '/' + slugOf(skill) + ' ' + rest;
            ui.autoGrow();
            ui.updateHints();
            input.focus();
            const end = input.value.length;
            try { input.setSelectionRange(end, end); } catch (_) { }
        },

        attach(ui, id) {
            if (!ui.conv) return;
            const on = ui.conv.skillId === id;
            ui.conv = Store().updateConversation(ui.conv.id, { skillId: on ? null : id });
            ui.refreshToolbar();
            ui.updateHints();
            this.render(ui);
            const skill = this.get(id);
            ui.toast(on ? t('{name} is off for this chat.', { name: this.label(skill) }) : t('{name} now applies to every message in this chat.', { name: this.label(skill) }));
        },

        newChat(ui, id) {
            const conv = ui.newConversation({ skillId: id });
            ui.closeModals();
            ui.open(conv);
            ui.renderList();
            const input = document.getElementById('input');
            if (input) input.focus();
        },

        chip(ui) {
            const chip = document.getElementById('chipSkill');
            if (!chip) return;
            const on = ui.conv ? this.forConv(ui.conv) : null;
            chip.classList.toggle('is-active', !!on);
            chip.querySelector('.chip-label').textContent = on ? this.label(on) : t('Skills');
            chip.title = on ? t('{name} applies to every message in this chat', { name: this.label(on) }) : t('Run a saved skill or attach one to this chat');
        },

        suggest(value) {
            const m = /^\/([A-Za-z0-9-]*)$/.exec(String(value || ''));
            if (!m) return null;
            return match(m[1], this.all(), 8);
        }
    };

    window.NymbotSkills = Skills;
})();
