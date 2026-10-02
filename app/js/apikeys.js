(function () {
    'use strict';

    const C = window.NymbotConfig;
    const BASE = 'https://nymbot.ai/api/v1';
    const DOCS = 'https://nymbot.ai/docs/api/';
    const DOCS_ROOT = 'https://nymbot.ai/docs/';
    const ANTHROPIC_BASE = BASE.replace(/\/v1$/, '');
    const AUTO = {
        id: 'nymbot/auto', object: 'model', type: 'chat', owned_by: 'Nymbot', name: 'Nymbot Auto',
        balance: 'standard', pricing: { type: 'variable', currency: 'USD' }
    };
    const KINDS = ['chat', 'image', 'video', 'speech', 'transcription', 'embedding'];
    const DOC_ANCHORS = {
        chat: 'api-chat/#chat-completions',
        anthropic: 'api-chat/#messages',
        image: 'api-media/#images',
        video: 'api-media/#video',
        speech: 'api-media/#speech',
        transcription: 'api-media/#transcription',
        embedding: 'api-media/#embeddings'
    };
    const IMAGE_URL = 'https://example.com/photo.jpg';
    const PLACEHOLDER = 'sk-nymbot-YOUR_KEY';
    const PERIODS = ['daily', 'weekly', 'monthly'];
    const NWC_MIN = 1000;
    const NWC_MAX = 1000000;
    const HISTORY_PAGE = 20;

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const num = (v) => window.NymbotI18n.count(v);
    const credits = (v) => {
        const n = Number(v) || 0;
        if (Number.isInteger(n)) return num(n);
        if (n > 0 && n < 0.01) return '<0.01';
        return window.amount(n, 2);
    };
    const ms = (v) => {
        if (v == null || v === '') return null;
        const n = typeof v === 'number' ? v : Date.parse(v);
        return Number.isFinite(n) ? n : null;
    };

    const endpoint = (p) => `https://${C.apiHost}/api/v1${p}`;

    function base64(text) {
        const bytes = new TextEncoder().encode(text);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin);
    }

    async function authHeader(method, url, body) {
        const nonce = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0')).join('');
        const tags = [['u', url], ['method', method], ['nonce', nonce]];
        if (body != null) tags.push(['payload', await window.NymbotApi.sha256Hex(body)]);
        const event = await window.NymbotIdentity.signEvent({
            kind: 27235,
            created_at: Math.floor(Date.now() / 1000),
            tags,
            content: ''
        });
        return 'Nostr ' + base64(JSON.stringify(event));
    }

    function errorText(data, status) {
        const e = data && data.error;
        if (e && typeof e === 'object' && e.message) return String(e.message);
        if (typeof e === 'string' && e) return e;
        return t('Nymbot answered with an error ({status}). Try again.', { status });
    }

    function unwrap(data) {
        if (data && data.data && typeof data.data === 'object' && !Array.isArray(data.data)) return data.data;
        return data;
    }

    async function request(method, path, payload) {
        const url = endpoint(path);
        const body = payload === undefined ? null : JSON.stringify(payload);
        let auth;
        try {
            auth = await authHeader(method, url, body);
        } catch (e) {
            return { ok: false, status: 0, data: null, error: (e && e.message) || t('Your key could not sign the request.') };
        }
        const headers = { Authorization: auth };
        if (body != null) headers['Content-Type'] = 'application/json';
        const Edge = window.NymbotEdge;
        let resp;
        try {
            const opts = { method, headers, body, credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer' };
            resp = Edge ? await Edge.fetch(url, opts) : await fetch(url, opts);
        } catch (_) {
            return {
                ok: false, status: 0, data: null,
                error: navigator.onLine === false
                    ? t('You are offline. Try again once you are back online.')
                    : t('Could not reach Nymbot. Check your connection and try again.')
            };
        }
        const data = await resp.json().catch(() => null);
        if (!resp.ok) return { ok: false, status: resp.status, data, error: errorText(data, resp.status) };
        return { ok: true, status: resp.status, data };
    }

    const Client = {
        account: () => request('GET', '/account'),
        keys: () => request('GET', '/keys?include_revoked=true'),
        key: (id) => request('GET', '/keys/' + encodeURIComponent(id)),
        createKey: (fields) => request('POST', '/keys', fields),
        updateKey: (id, fields) => request('PATCH', '/keys/' + encodeURIComponent(id), fields),
        revokeKey: (id) => request('DELETE', '/keys/' + encodeURIComponent(id)),
        history: (page) => request('GET', `/queries/history?all_keys=true&page=${page || 1}&page_count=${HISTORY_PAGE}`),
        nwc: () => request('GET', '/nwc-auto-topup'),
        nwcConnect: (fields) => request('POST', '/nwc-auto-topup/connect', fields),
        nwcDisconnect: () => request('DELETE', '/nwc-auto-topup/connection'),
        models: () => publicGet('/models?type=all')
    };

    async function publicGet(path) {
        const url = endpoint(path);
        const Edge = window.NymbotEdge;
        const opts = { method: 'GET', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer' };
        try {
            const resp = Edge ? await Edge.fetch(url, opts) : await fetch(url, opts);
            const data = await resp.json().catch(() => null);
            return resp.ok ? { ok: true, status: resp.status, data } : { ok: false, status: resp.status, data };
        } catch (_) {
            return { ok: false, status: 0, data: null };
        }
    }

    function kindOf(m) {
        if (!m) return 'chat';
        if (m.type === 'audio') return m.audio_type === 'transcription' ? 'transcription' : 'speech';
        return KINDS.includes(m.type) ? m.type : 'chat';
    }

    function isClaude(m) {
        return kindOf(m) === 'chat' && /^(anthropic\/|claude)/i.test(String(m.id || ''));
    }

    function tabsFor(m) {
        return isClaude(m) ? ['curl', 'python', 'js', 'anthropic'] : ['curl', 'python', 'js'];
    }

    function voiceFor(m) {
        const id = String(m.id || '');
        if (/aura-2/.test(id)) return 'luna';
        if (/melotts/.test(id)) return 'en';
        return 'alloy';
    }

    function secondsFor(m) {
        const n = Number(m.capabilities && m.capabilities.max_duration_seconds);
        return Number.isInteger(n) && n > 0 && n <= 60 ? n : 5;
    }

    const needsImage = (m) => !!(m.capabilities && m.capabilities.requires_image_url);
    const q = (v) => JSON.stringify(String(v));
    const openaiPy = () => [
        'from openai import OpenAI',
        '',
        `client = OpenAI(base_url="${BASE}", api_key="${PLACEHOLDER}")`
    ];
    const openaiJs = (head) => (head || []).concat([
        'import OpenAI from "openai";',
        '',
        `const client = new OpenAI({ baseURL: "${BASE}", apiKey: "${PLACEHOLDER}" });`
    ]);
    const curlJson = (path, body, tail) => [
        `curl ${BASE}${path} \\`,
        `  -H "Authorization: Bearer ${PLACEHOLDER}" \\`,
        '  -H "Content-Type: application/json" \\',
        `  -d '${body}'` + (tail ? ' \\' : '')
    ].concat(tail ? [tail] : []);

    const SHAPES = {
        chat: {
            curl: (m) => curlJson('/chat/completions', `{"model": ${q(m.id)}, "messages": [{"role": "user", "content": "Hello"}]}`),
            python: (m) => openaiPy().concat([
                'reply = client.chat.completions.create(',
                `    model=${q(m.id)},`,
                '    messages=[{"role": "user", "content": "Hello"}],',
                ')',
                'print(reply.choices[0].message.content)'
            ]),
            js: (m) => openaiJs().concat([
                'const reply = await client.chat.completions.create({',
                `  model: ${q(m.id)},`,
                '  messages: [{ role: "user", content: "Hello" }],',
                '});',
                'console.log(reply.choices[0].message.content);'
            ]),
            anthropic: (m) => [
                'import anthropic',
                '',
                `client = anthropic.Anthropic(base_url="${ANTHROPIC_BASE}", api_key="${PLACEHOLDER}")`,
                'message = client.messages.create(',
                `    model=${q(m.id)},`,
                '    max_tokens=1024,',
                '    messages=[{"role": "user", "content": "Hello"}],',
                ')',
                'print(message.content[0].text)'
            ]
        },
        image: {
            curl: (m) => curlJson('/images/generations',
                `{"model": ${q(m.id)}, "prompt": "A lighthouse at dusk", "size": "1024x1024"${needsImage(m) ? `, "image_url": "${IMAGE_URL}"` : ''}}`),
            python: (m) => openaiPy().concat([
                'image = client.images.generate(',
                `    model=${q(m.id)},`,
                '    prompt="A lighthouse at dusk",',
                '    size="1024x1024",'
            ], needsImage(m) ? [`    extra_body={"image_url": "${IMAGE_URL}"},`] : [], [
                ')',
                'print(image.data[0].url)'
            ]),
            js: (m) => openaiJs().concat([
                'const image = await client.images.generate({',
                `  model: ${q(m.id)},`,
                '  prompt: "A lighthouse at dusk",',
                '  size: "1024x1024",'
            ], needsImage(m) ? [`  image_url: "${IMAGE_URL}",`] : [], [
                '});',
                'console.log(image.data[0].url);'
            ])
        },
        video: {
            curl: (m) => curlJson('/videos',
                `{"model": ${q(m.id)}, "prompt": "Waves rolling onto a beach at sunrise", "duration": ${secondsFor(m)}${needsImage(m) ? `, "image_url": "${IMAGE_URL}"` : ''}}`).concat([
                '',
                `curl ${BASE}/videos/VIDEO_ID \\`,
                `  -H "Authorization: Bearer ${PLACEHOLDER}"`
            ]),
            python: (m) => [
                'import time',
                'import requests',
                '',
                `headers = {"Authorization": "Bearer ${PLACEHOLDER}"}`,
                'job = requests.post(',
                `    "${BASE}/videos",`,
                '    headers=headers,',
                `    json={"model": ${q(m.id)}, "prompt": "Waves rolling onto a beach at sunrise", "duration": ${secondsFor(m)}${needsImage(m) ? `, "image_url": "${IMAGE_URL}"` : ''}},`,
                ').json()',
                'while job.get("status") == "in_progress":',
                '    time.sleep(8)',
                `    job = requests.get("${BASE}/videos/" + job["id"], headers=headers).json()`,
                'print(job["data"]["url"] if job.get("status") == "completed" else job.get("error"))'
            ],
            js: (m) => [
                `const headers = { "Authorization": "Bearer ${PLACEHOLDER}", "Content-Type": "application/json" };`,
                `let job = await (await fetch("${BASE}/videos", {`,
                '  method: "POST",',
                '  headers,',
                `  body: JSON.stringify({ model: ${q(m.id)}, prompt: "Waves rolling onto a beach at sunrise", duration: ${secondsFor(m)}${needsImage(m) ? `, image_url: "${IMAGE_URL}"` : ''} }),`,
                '})).json();',
                'while (job.status === "in_progress") {',
                '  await new Promise((r) => setTimeout(r, 8000));',
                `  job = await (await fetch("${BASE}/videos/" + job.id, { headers })).json();`,
                '}',
                'console.log(job.status === "completed" ? job.data.url : job.error);'
            ]
        },
        speech: {
            curl: (m) => curlJson('/audio/speech',
                `{"model": ${q(m.id)}, "input": "Hello from Nymbot", "voice": ${q(voiceFor(m))}}`, '  --output speech.mp3'),
            python: (m) => openaiPy().concat([
                'audio = client.audio.speech.create(',
                `    model=${q(m.id)},`,
                `    voice=${q(voiceFor(m))},`,
                '    input="Hello from Nymbot",',
                ')',
                'audio.write_to_file("speech.mp3")'
            ]),
            js: (m) => openaiJs(['import { writeFile } from "node:fs/promises";']).concat([
                'const audio = await client.audio.speech.create({',
                `  model: ${q(m.id)},`,
                `  voice: ${q(voiceFor(m))},`,
                '  input: "Hello from Nymbot",',
                '});',
                'await writeFile("speech.mp3", Buffer.from(await audio.arrayBuffer()));'
            ])
        },
        transcription: {
            curl: (m) => [
                `curl ${BASE}/audio/transcriptions \\`,
                `  -H "Authorization: Bearer ${PLACEHOLDER}" \\`,
                '  -F file=@audio.mp3 \\',
                `  -F model=${m.id}`
            ],
            python: (m) => openaiPy().concat([
                `transcript = client.audio.transcriptions.create(model=${q(m.id)}, file=open("audio.mp3", "rb"))`,
                'print(transcript.text)'
            ]),
            js: (m) => openaiJs(['import fs from "node:fs";']).concat([
                'const transcript = await client.audio.transcriptions.create({',
                `  model: ${q(m.id)},`,
                '  file: fs.createReadStream("audio.mp3"),',
                '});',
                'console.log(transcript.text);'
            ])
        },
        embedding: {
            curl: (m) => curlJson('/embeddings', `{"model": ${q(m.id)}, "input": "Hello"}`),
            python: (m) => openaiPy().concat([
                `result = client.embeddings.create(model=${q(m.id)}, input="Hello")`,
                'print(len(result.data[0].embedding))'
            ]),
            js: (m) => openaiJs().concat([
                `const result = await client.embeddings.create({ model: ${q(m.id)}, input: "Hello" });`,
                'console.log(result.data[0].embedding.length);'
            ])
        }
    };

    function snippetText(tab, m) {
        const model = m || AUTO;
        const shape = SHAPES[kindOf(model)];
        const build = shape[tab] || shape.curl;
        return build(model).join('\n');
    }

    function docsFor(tab, m) {
        const kind = kindOf(m);
        return DOCS_ROOT + (kind === 'chat' && tab === 'anthropic' ? DOC_ANCHORS.anthropic : DOC_ANCHORS[kind]);
    }

    function usd(v) {
        const n = v == null || v === '' ? NaN : Number(v);
        if (!Number.isFinite(n)) return null;
        return '$' + String(Number(n.toPrecision(3)));
    }

    function amountOf(p, field) {
        const dollars = usd(p[field]);
        if (dollars) return dollars;
        const sats = p['sats_' + field];
        return sats != null && Number.isFinite(Number(sats)) ? t('{n} sats', { n: num(Number(sats)) }) : null;
    }

    function priceLine(m) {
        const p = (m && m.pricing) || {};
        if (m && m.id === AUTO.id) return t('Priced per reply by the model it picks.');
        const kind = kindOf(m);
        if (kind === 'chat') {
            if (p.type === 'per_request') {
                const each = amountOf(p, 'usd_per_request');
                return each ? t('{price} per request.', { price: each }) : '';
            }
            const inn = amountOf(p, 'input_per_1M_tokens');
            const out = amountOf(p, 'output_per_1M_tokens');
            return inn && out ? t('{in} in, {out} out per 1M tokens.', { in: inn, out }) : '';
        }
        const pick = {
            image: ['per_generation', (price) => t('{price} per image.', { price })],
            video: ['per_second', (price) => t('{price} per second.', { price })],
            speech: ['per_1k_chars', (price) => t('{price} per 1k characters.', { price })],
            transcription: ['per_minute', (price) => t('{price} per minute.', { price })],
            embedding: ['input_per_1M_tokens', (price) => t('{price} per 1M tokens.', { price })]
        }[kind];
        const price = amountOf(p, pick[0]);
        return price ? pick[1](price) : '';
    }

    function balanceLine(m) {
        return m && m.balance === 'pro' ? t('Spends the Pro balance.') : t('Spends the Standard balance.');
    }

    function hintFor(m) {
        return [priceLine(m), balanceLine(m)].filter(Boolean).join(' ');
    }

    function makerSlug(m) {
        if (!m || m.id === AUTO.id) return null;
        const id = String(m.id || '');
        if (id.includes('/') && !id.startsWith('@')) return id.split('/')[0].toLowerCase();
        const owner = String(m.owned_by || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
        return owner || null;
    }

    function pickerEntry(m) {
        const kind = kindOf(m);
        return {
            key: kind + ':' + m.id,
            id: m.id,
            label: m.name || m.id,
            description: m.description || '',
            author: m.owned_by || '',
            authorSlug: makerSlug(m),
            kind,
            source: m
        };
    }

    function groupWord(kind) {
        switch (kind) {
            case 'chat': return t('Chat');
            case 'image': return t('Image');
            case 'video': return t('Video');
            case 'speech': return t('Speech');
            case 'transcription': return t('Transcription');
            default: return t('Embeddings');
        }
    }

    const SNIPPETS = {
        curl: (m) => snippetText('curl', m),
        python: (m) => snippetText('python', m),
        js: (m) => snippetText('js', m),
        anthropic: (m) => snippetText('anthropic', m)
    };

    let snippet = 'curl';
    let models = [AUTO];
    let model = AUTO;
    let modelsFailed = false;
    let modelsSeq = 0;
    let keys = [];
    let account = null;
    let editing = null;
    let loadSeq = 0;
    let saving = false;
    let wiring = false;

    function showSnippet(name) {
        const tabs = tabsFor(model);
        snippet = tabs.includes(name) ? name : 'curl';
        $('apiSnippet').textContent = SNIPPETS[snippet](model);
        $('apiDocsLink').href = docsFor(snippet, model);
        for (const b of document.querySelectorAll('[data-act="api-snippet"]')) {
            const on = b.dataset.snippet === snippet;
            b.hidden = !tabs.includes(b.dataset.snippet);
            b.classList.toggle('is-active', on);
            b.setAttribute('aria-pressed', on ? 'true' : 'false');
        }
    }

    function renderModel(ui) {
        const button = $('apiModel');
        if (ui && ui.renderModelSlot) ui.renderModelSlot(button, pickerEntry(model), { label: t('Model') });
        else button.textContent = model.name || model.id;
        const note = modelsFailed ? t('Other models could not be loaded.') : '';
        $('apiModelHint').textContent = [hintFor(model), note].filter(Boolean).join(' ');
        showSnippet(snippet);
    }

    function setModel(ui, m) {
        model = m || AUTO;
        renderModel(ui);
    }

    async function loadModels(ui) {
        const seq = ++modelsSeq;
        const res = await Client.models();
        if (seq !== modelsSeq) return;
        const rows = res.ok && res.data && Array.isArray(res.data.data) ? res.data.data.filter((m) => m && m.id) : null;
        if (rows && rows.length) {
            models = rows.some((m) => m.id === AUTO.id) ? rows : [AUTO].concat(rows);
            modelsFailed = false;
            const same = models.find((m) => m.id === model.id && kindOf(m) === kindOf(model));
            model = same || AUTO;
        } else {
            models = [AUTO];
            modelsFailed = true;
            model = AUTO;
        }
        renderModel(ui);
    }

    function pickModel(ui) {
        const entries = models.map(pickerEntry);
        const groups = KINDS
            .map((kind) => ({ author: groupWord(kind), keys: entries.filter((e) => e.kind === kind).map((e) => e.key) }))
            .filter((g) => g.keys.length);
        ui.openModels(null, {
            over: true,
            from: $('apiModel'),
            title: t('Pick a model'),
            current: pickerEntry(model).key,
            catalog: { models: entries, groups },
            price: (e) => priceLine(e.source),
            pick: (e) => setModel(ui, e.source)
        });
    }

    function hideNewKey() {
        $('apiNewKeyValue').value = '';
        $('apiNewKey').hidden = true;
    }

    function tierBalance(b) {
        if (b == null) return null;
        if (typeof b === 'number') return { credits: b, sats: null };
        const c = b.credits != null ? b.credits : (b.balance_credits != null ? b.balance_credits : null);
        return { credits: c, sats: b.sats != null ? b.sats : (b.balance_sats != null ? b.balance_sats : null) };
    }

    function balancesOf(acct) {
        const b = acct && (acct.balances || acct);
        if (!b) return null;
        const standard = tierBalance(b.standard);
        const pro = tierBalance(b.pro);
        return standard || pro ? { standard, pro } : null;
    }

    function isFree(ui) {
        const b = balancesOf(account);
        if (b) {
            const empty = (x) => !x || (!(Number(x.credits) > 0) && !(Number(x.sats) > 0));
            return empty(b.standard) && empty(b.pro);
        }
        return !!(ui.freeOnly && ui.freeOnly());
    }

    function renderBalances(ui) {
        const b = balancesOf(account);
        const node = $('apiBalances');
        node.textContent = '';
        if (b) {
            const part = (x) => {
                if (!x) return '0';
                return x.sats != null
                    ? t('{credits} ({sats} sats)', { credits: credits(x.credits), sats: num(x.sats) })
                    : credits(x.credits);
            };
            node.textContent = t('Balances: {standard} Standard, {pro} Pro', { standard: part(b.standard), pro: part(b.pro) });
        }
        $('apiFreeNote').hidden = !isFree(ui);
    }

    function dayOf(ui, v) {
        const at = ms(v);
        return at == null ? '' : ui.dayLabel(at);
    }

    function periodWord(p) {
        switch (p) {
            case 'daily': return t('daily');
            case 'weekly': return t('weekly');
            case 'monthly': return t('monthly');
            default: return '';
        }
    }

    function usageLine(ui, k) {
        const used = num(Number(k.period_used_sats) || 0);
        const parts = [];
        if (k.limit_sats != null) {
            parts.push(t('{used} of {cap} sats', { used, cap: num(k.limit_sats) }));
            if (k.reset_period) {
                const next = dayOf(ui, k.reset_at);
                parts.push(next
                    ? t('resets {period}, next {date}', { period: periodWord(k.reset_period), date: next })
                    : t('resets {period}', { period: periodWord(k.reset_period) }));
            }
        } else {
            parts.push(t('No cap'));
        }
        parts.push(t('{n} sats in total', { n: num(Number(k.total_used_sats) || 0) }));
        return parts.join(' · ');
    }

    function statusLine(ui, k) {
        const parts = [];
        if (k.revoked_at) parts.push(t('Revoked {date}', { date: dayOf(ui, k.revoked_at) }));
        const exp = ms(k.expire_at);
        if (exp != null) {
            parts.push(exp <= Date.now()
                ? t('Expired {date}', { date: ui.dayLabel(exp) })
                : t('Expires {date}', { date: ui.dayLabel(exp) }));
        }
        const used = ms(k.last_used_at);
        parts.push(used != null
            ? t('Last used {when}', { when: `${ui.dayLabel(used)} ${ui.timeLabel(used)}` })
            : t('Never used'));
        return parts.join(' · ');
    }

    function renderKeys(ui) {
        const list = $('apiKeyList');
        list.innerHTML = '';
        if (!keys.length) {
            list.appendChild(el('p', 'hint', t('No keys yet. Make one below; it works with any OpenAI-compatible client.')));
            return;
        }
        for (const k of keys) {
            const row = el('div', 'repo-row api-key-row' + (k.revoked_at ? ' is-revoked' : ''));
            row.dataset.key = k.id;
            const main = el('div', 'repo-main');
            const name = el('span', 'repo-name', k.name || t('Untitled'));
            main.appendChild(name);
            const hint = el('span', 'repo-sub api-key-hint', k.hint || '');
            hint.dataset.i18nSkip = '';
            main.appendChild(hint);
            main.appendChild(el('span', 'repo-sub', usageLine(ui, k)));
            main.appendChild(el('span', 'repo-sub', statusLine(ui, k)));
            row.appendChild(main);
            if (!k.revoked_at) {
                const actions = el('div', 'row-actions');
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.dataset.keyAct = 'edit';
                edit.addEventListener('click', () => editKey(ui, k.id));
                actions.appendChild(edit);
                const revoke = el('button', 'row-btn danger', t('Revoke'));
                revoke.type = 'button';
                revoke.dataset.keyAct = 'revoke';
                revoke.addEventListener('click', () => revokeKey(ui, k.id));
                actions.appendChild(revoke);
                row.appendChild(actions);
            }
            list.appendChild(row);
        }
    }

    function typeWord(type) {
        switch (type) {
            case 'chat': return t('chat');
            case 'responses': return t('responses');
            case 'messages': return t('messages');
            case 'image': return t('image');
            case 'video': return t('video');
            case 'speech': return t('speech');
            case 'transcription': return t('transcription');
            case 'embedding': return t('embedding');
            default: return String(type || '');
        }
    }

    function renderHistory(ui, rows) {
        const list = $('apiHistory');
        list.innerHTML = '';
        if (!rows.length) {
            list.appendChild(el('p', 'hint', t('No API calls yet.')));
            return;
        }
        for (const q of rows) {
            const row = el('div', 'repo-row api-query-row' + (q.status === 'error' ? ' is-error' : ''));
            const main = el('div', 'repo-main');
            const model = el('span', 'repo-name', q.model || '');
            model.dataset.i18nSkip = '';
            main.appendChild(model);
            const at = ms(q.timestamp);
            const key = keys.find((k) => k.id === q.key_id);
            const parts = [
                at != null ? `${ui.dayLabel(at)} ${ui.timeLabel(at)}` : '',
                typeWord(q.type),
                t('{input} in, {output} out', { input: num(Number(q.input_tokens) || 0), output: num(Number(q.output_tokens) || 0) }),
                t('{n} sats', { n: num(Number(q.cost_sats) || 0) }),
                q.balance === 'standard' ? t('Standard') : (q.balance === 'pro' ? t('Pro') : ''),
                key ? key.name : '',
                q.web_search ? t('web search') : '',
                q.status === 'error' ? t('failed') : ''
            ];
            main.appendChild(el('span', 'repo-sub', parts.filter(Boolean).join(' · ')));
            row.appendChild(main);
            list.appendChild(row);
        }
    }

    function renderNwc(ui, res) {
        const section = $('apiNwc');
        if (!res || res.status === 501) {
            section.hidden = true;
            return;
        }
        section.hidden = false;
        const state = $('apiNwcState');
        if (!res.ok) {
            state.textContent = '';
            ui.modalStatus('apiNwcStatus', res.error, 'warn');
            return;
        }
        const d = unwrap(res.data) || {};
        const on = d.connected === true || d.enabled === true;
        const lines = [];
        if (on) {
            lines.push(t('Connected. When the {tier} balance drops below {threshold} sats, it tops up {topup} sats.', {
                tier: d.tier === 'standard' ? t('Standard') : t('Pro'),
                threshold: num(Number(d.threshold_sats) || 0),
                topup: num(Number(d.topup_sats) || 0)
            }));
            const last = ms(d.last_topup_at);
            if (last != null) lines.push(t('Last top-up {when}.', { when: `${ui.dayLabel(last)} ${ui.timeLabel(last)}` }));
            if (d.last_error) lines.push(t('Last error: {error}', { error: String(d.last_error) }));
        } else {
            lines.push(t('Not connected.'));
        }
        state.textContent = lines.join(' ');
        $('apiNwcForm').hidden = on;
        $('apiNwcConnect').hidden = on;
        $('apiNwcDisconnect').hidden = !on;
    }

    async function refresh(ui) {
        const seq = ++loadSeq;
        ui.modalStatus('apiStatus', t('Loading…'));
        const [acct, list, hist, nwc] = await Promise.all([Client.account(), Client.keys(), Client.history(1), Client.nwc()]);
        if (seq !== loadSeq) return;
        const problems = [];
        if (acct.ok) account = unwrap(acct.data) || null;
        else problems.push(acct.error);
        renderBalances(ui);
        if (list.ok) {
            const rows = list.data && Array.isArray(list.data.data) ? list.data.data : (Array.isArray(list.data) ? list.data : []);
            keys = rows;
            renderKeys(ui);
        } else {
            problems.push(list.error);
            if (!keys.length) $('apiKeyList').innerHTML = '';
        }
        if (hist.ok) renderHistory(ui, hist.data && Array.isArray(hist.data.data) ? hist.data.data : []);
        else problems.push(hist.error);
        renderNwc(ui, nwc);
        ui.modalStatus('apiStatus', problems[0] || '', problems.length ? 'warn' : null);
    }

    function localDay(at) {
        const d = new Date(at);
        const pad = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    }

    function resetForm(ui) {
        editing = null;
        $('apiKeyFormTitle').textContent = t('New key');
        $('apiKeySave').textContent = t('Create key');
        $('apiKeyName').value = '';
        $('apiKeyCap').value = '';
        $('apiKeyPeriod').value = '';
        $('apiKeyExpiry').value = '';
        ui.modalStatus('apiKeyStatus', '');
    }

    function editKey(ui, id) {
        const k = keys.find((x) => x.id === id);
        if (!k || k.revoked_at) return;
        editing = id;
        $('apiKeyFormTitle').textContent = t('Edit {name}', { name: k.name || '' });
        $('apiKeySave').textContent = t('Save changes');
        $('apiKeyName').value = k.name || '';
        $('apiKeyCap').value = k.limit_sats != null ? String(k.limit_sats) : '';
        $('apiKeyPeriod').value = PERIODS.includes(k.reset_period) ? k.reset_period : '';
        const exp = ms(k.expire_at);
        $('apiKeyExpiry').value = exp != null ? localDay(exp) : '';
        ui.modalStatus('apiKeyStatus', '');
        $('apiKeyName').focus();
    }

    function readForm(ui) {
        const warn = (text) => { ui.modalStatus('apiKeyStatus', text, 'warn'); return null; };
        const name = $('apiKeyName').value.trim();
        if (!name) return warn(t('Give the key a name.'));
        if (name.length > 40) return warn(t('Keep the name to 40 characters.'));
        const capRaw = $('apiKeyCap').value.trim();
        const cap = capRaw === '' ? null : Number(capRaw);
        if (cap !== null && (!Number.isInteger(cap) || cap < 1)) return warn(t('The cap is a whole number of sats, 1 or more.'));
        const period = PERIODS.includes($('apiKeyPeriod').value) ? $('apiKeyPeriod').value : null;
        if (period && cap === null) return warn(t('A reset period needs a cap.'));
        const day = $('apiKeyExpiry').value;
        let expire = null;
        if (day) {
            const at = new Date(day + 'T23:59:59').getTime();
            if (!Number.isFinite(at)) return warn(t('Pick a valid expiry date.'));
            expire = at;
        }
        return { name, cap, period, day, expire };
    }

    async function save(ui) {
        if (saving) return;
        const f = readForm(ui);
        if (!f) return;
        let fields;
        const current = editing ? keys.find((k) => k.id === editing) : null;
        if (current) {
            fields = {};
            if (f.name !== current.name) fields.name = f.name;
            if (f.cap !== (current.limit_sats != null ? current.limit_sats : null)) fields.limit_sats = f.cap;
            if (f.period !== (current.reset_period || null)) fields.reset_period = f.period;
            const was = ms(current.expire_at);
            if (f.day !== (was != null ? localDay(was) : '')) fields.expire_at = f.expire != null ? new Date(f.expire).toISOString() : null;
            if (!Object.keys(fields).length) {
                ui.modalStatus('apiKeyStatus', t('Nothing changed.'));
                return;
            }
        } else {
            fields = { name: f.name };
            if (f.cap !== null) fields.limit_sats = f.cap;
            if (f.period) fields.reset_period = f.period;
            if (f.expire != null) fields.expire_at = new Date(f.expire).toISOString();
        }
        if (fields.expire_at && Date.parse(fields.expire_at) <= Date.now()) {
            ui.modalStatus('apiKeyStatus', t('Pick an expiry date in the future.'), 'warn');
            return;
        }
        saving = true;
        const button = $('apiKeySave');
        button.disabled = true;
        ui.modalStatus('apiKeyStatus', current ? t('Saving…') : t('Making the key…'));
        try {
            const res = current ? await Client.updateKey(current.id, fields) : await Client.createKey(fields);
            if (!res.ok) {
                ui.modalStatus('apiKeyStatus', res.error, 'warn');
                return;
            }
            if (current) {
                resetForm(ui);
                ui.modalStatus('apiKeyStatus', t('Saved.'), 'ok');
            } else {
                const made = unwrap(res.data) || {};
                resetForm(ui);
                if (made.key) {
                    $('apiNewKeyValue').value = made.key;
                    $('apiNewKey').hidden = false;
                }
                ui.modalStatus('apiKeyStatus', isFree(ui)
                    ? t('Key made. API calls need credits, so buy some before you use it.')
                    : t('Key made.'), 'ok');
            }
            await refresh(ui);
        } finally {
            saving = false;
            button.disabled = false;
        }
    }

    async function revokeKey(ui, id) {
        const k = keys.find((x) => x.id === id);
        if (!k) return;
        const yes = await ui.ask({
            title: t('Revoke {name}?', { name: k.name || '' }),
            body: t('Anything using this key stops working at once. This cannot be undone.'),
            confirm: t('Revoke'),
            danger: true
        });
        if (!yes) return;
        ui.modalStatus('apiStatus', t('Revoking…'));
        const res = await Client.revokeKey(id);
        if (!res.ok) {
            ui.modalStatus('apiStatus', res.error, 'warn');
            return;
        }
        if (editing === id) resetForm(ui);
        await refresh(ui);
        ui.modalStatus('apiStatus', t('Revoked {name}.', { name: k.name || '' }), 'ok');
    }

    async function connect(ui) {
        if (wiring) return;
        const warn = (text) => ui.modalStatus('apiNwcStatus', text, 'warn');
        const url = $('apiNwcUrl').value.trim();
        if (!/^nostr\+walletconnect:\/\/[0-9a-f]{64}\?/i.test(url)) {
            warn(t('Paste the nostr+walletconnect:// connection string from your wallet.'));
            return;
        }
        const threshold = Number($('apiNwcThreshold').value);
        if (!Number.isInteger(threshold) || threshold < NWC_MIN) {
            warn(t('The threshold is at least {n} sats.', { n: num(NWC_MIN) }));
            return;
        }
        const topup = Number($('apiNwcAmount').value);
        if (!Number.isInteger(topup) || topup < NWC_MIN || topup > NWC_MAX) {
            warn(t('Top up by {min} to {max} sats.', { min: num(NWC_MIN), max: num(NWC_MAX) }));
            return;
        }
        const tier = $('apiNwcTier').value === 'standard' ? 'standard' : 'pro';
        wiring = true;
        const button = $('apiNwcConnect');
        button.disabled = true;
        ui.modalStatus('apiNwcStatus', t('Checking the wallet…'));
        try {
            const res = await Client.nwcConnect({ nwc_url: url, threshold_sats: threshold, topup_sats: topup, tier });
            if (!res.ok) {
                if (res.status === 501) renderNwc(ui, res);
                else warn(res.error);
                return;
            }
            $('apiNwcUrl').value = '';
            renderNwc(ui, await Client.nwc());
            ui.modalStatus('apiNwcStatus', t('Wallet connected.'), 'ok');
        } finally {
            wiring = false;
            button.disabled = false;
        }
    }

    async function disconnect(ui) {
        if (wiring) return;
        const yes = await ui.ask({
            title: t('Disconnect the wallet?'),
            body: t('Balances stop topping up on their own. The stored connection is deleted.'),
            confirm: t('Disconnect'),
            danger: true
        });
        if (!yes) return;
        wiring = true;
        ui.modalStatus('apiNwcStatus', t('Disconnecting…'));
        try {
            const res = await Client.nwcDisconnect();
            if (!res.ok) {
                ui.modalStatus('apiNwcStatus', res.error, 'warn');
                return;
            }
            renderNwc(ui, await Client.nwc());
            ui.modalStatus('apiNwcStatus', t('Wallet disconnected.'), 'ok');
        } finally {
            wiring = false;
        }
    }

    function open(ui) {
        $('apiBaseUrl').value = BASE;
        renderModel(ui);
        loadModels(ui);
        hideNewKey();
        resetForm(ui);
        $('apiNwcUrl').value = '';
        ui.modalStatus('apiStatus', '');
        ui.modalStatus('apiNwcStatus', '');
        renderBalances(ui);
        ui.openModal('modalApi');
        return refresh(ui);
    }

    function handlers(ui) {
        return {
            'api-copy-base': () => ui.writeClipboard(BASE),
            'api-snippet': (target) => showSnippet(target.dataset.snippet),
            'api-copy-snippet': () => ui.writeClipboard($('apiSnippet').textContent),
            'api-model-pick': () => pickModel(ui),
            'api-key-save': () => save(ui),
            'api-key-reset': () => resetForm(ui),
            'api-copy-key': () => {
                const value = $('apiNewKeyValue').value;
                if (value) ui.writeClipboard(value);
            },
            'api-new-key-done': () => hideNewKey(),
            'api-nwc-connect': () => connect(ui),
            'api-nwc-disconnect': () => disconnect(ui)
        };
    }

    window.NymbotApiKeys = {
        BASE,
        DOCS,
        SNIPPETS,
        snippetText,
        hintFor,
        models: () => models.slice(),
        authHeader,
        request,
        Client,
        open,
        refresh,
        handlers
    };
})();
