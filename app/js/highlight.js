(function () {
    'use strict';

    const KEYWORDS = {
        common: 'if else for while return break continue function class const let var new this null true false undefined import export from as default try catch finally throw switch case do in of typeof instanceof await async yield delete void extends super static get set',
        js: 'if else for while return break continue function class const let var new this null true false undefined import export from as default try catch finally throw switch case do in of typeof instanceof await async yield delete void extends super static get set',
        ts: 'if else for while return break continue function class const let var new this null true false undefined import export from as default try catch finally throw switch case do in of typeof instanceof await async yield delete void extends super static get set interface type enum implements public private protected readonly namespace declare abstract satisfies keyof infer',
        dart: 'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for get if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield',
        py: 'def class return if elif else for while import from as pass break continue with try except finally raise lambda yield global nonlocal assert del in is not and or None True False async await match case',
        go: 'func package import var const type struct interface map chan go defer if else for range return switch case default break continue fallthrough select nil true false make new len cap append',
        rust: 'fn let mut const static struct enum impl trait pub use mod crate self super match if else loop while for in return break continue where as dyn ref move unsafe async await Some None Ok Err true false',
        java: 'public private protected class interface extends implements static final void int long double float boolean char String new return if else for while do switch case break continue try catch finally throw throws import package this super null true false abstract synchronized volatile enum record',
        c: 'int char float double void long short signed unsigned struct union enum typedef static const extern return if else for while do switch case break continue sizeof goto NULL include define ifdef ifndef endif pragma',
        sh: 'if then else elif fi for while do done case esac function return export local readonly set unset echo printf cd exit source shift trap eval exec test',
        sql: 'select from where insert update delete into values set join left right inner outer on group by order having limit offset create table alter drop index primary key foreign references null not and or as distinct union all case when then else end',
        css: 'important media supports keyframes import charset font-face root var calc',
        yaml: 'true false null yes no on off',
        json: 'true false null'
    };

    const ALIASES = {
        javascript: 'js', jsx: 'js', mjs: 'js', node: 'js',
        typescript: 'ts', tsx: 'ts',
        python: 'py', py3: 'py',
        golang: 'go',
        rs: 'rust',
        shell: 'sh', bash: 'sh', zsh: 'sh', console: 'sh',
        'c++': 'c', cpp: 'c', h: 'c', objc: 'c', cs: 'java', csharp: 'java', kotlin: 'java', kt: 'java', swift: 'java', scala: 'java',
        postgres: 'sql', postgresql: 'sql', mysql: 'sql', sqlite: 'sql',
        yml: 'yaml',
        html: 'markup', xml: 'markup', svg: 'markup', vue: 'markup',
        scss: 'css', less: 'css',
        diff: 'diff', patch: 'diff'
    };

    function esc(s) {
        return String(s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function normalise(lang) {
        const l = String(lang || '').toLowerCase();
        return ALIASES[l] || l;
    }

    function keywordSet(lang) {
        return new Set((KEYWORDS[lang] || KEYWORDS.common).split(/\s+/));
    }

    function highlightDiff(code) {
        return code.split('\n').map((line) => {
            if (/^\+\+\+|^---/.test(line)) return `<span class="tok-meta">${esc(line)}</span>`;
            if (/^@@/.test(line)) return `<span class="tok-meta">${esc(line)}</span>`;
            if (/^\+/.test(line)) return `<span class="tok-ins">${esc(line)}</span>`;
            if (/^-/.test(line)) return `<span class="tok-del">${esc(line)}</span>`;
            return esc(line);
        }).join('\n');
    }

    function highlightMarkup(code) {
        let out = '';
        let i = 0;
        const src = String(code);
        while (i < src.length) {
            const open = src.indexOf('<', i);
            if (open === -1) { out += esc(src.slice(i)); break; }
            out += esc(src.slice(i, open));
            const close = src.indexOf('>', open);
            if (close === -1) { out += esc(src.slice(open)); break; }
            const tag = src.slice(open, close + 1);
            if (/^<!--/.test(tag)) {
                out += `<span class="tok-comment">${esc(tag)}</span>`;
            } else {
                const inner = tag.replace(/^<\/?|\/?>$/g, '');
                const name = (inner.match(/^[\w:-]+/) || [''])[0];
                let rendered = esc(tag.slice(0, tag.indexOf(name) + name.length))
                    .replace(esc(name), `<span class="tok-tag">${esc(name)}</span>`);
                const rest = tag.slice(tag.indexOf(name) + name.length);
                rendered += esc(rest)
                    .replace(/([\w:-]+)=/g, '<span class="tok-attr">$1</span>=')
                    .replace(/(&quot;[^&]*?&quot;|&#39;[^&]*?&#39;)/g, '<span class="tok-str">$1</span>');
                out += rendered;
            }
            i = close + 1;
        }
        return out;
    }

    function highlightGeneric(code, lang) {
        const words = keywordSet(lang);
        const src = String(code);
        const pattern = new RegExp([
            '(\\/\\*[\\s\\S]*?\\*\\/)',
            '((?:^|[^:])\\/\\/[^\\n]*)',
            '(#[^\\n]*)',
            '(--[^\\n]*)',
            '("(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\])*\'|`(?:\\\\.|[^`\\\\])*`)',
            '(\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b|\\b0[xX][0-9a-fA-F]+\\b)',
            '([A-Za-z_$][\\w$]*)(?=\\s*\\()',
            '([A-Za-z_$][\\w$]*)'
        ].join('|'), 'g');

        const allowsHash = lang === 'py' || lang === 'sh' || lang === 'yaml' || lang === 'rust' || lang === 'c';
        const allowsDash = lang === 'sql';
        const allowsSlash = lang !== 'py' && lang !== 'sh' && lang !== 'yaml';

        let out = '';
        let at = 0;
        let m;
        while ((m = pattern.exec(src)) !== null) {
            out += esc(src.slice(at, m.index));
            at = m.index + m[0].length;
            if (m[1]) out += `<span class="tok-comment">${esc(m[1])}</span>`;
            else if (m[2]) {
                const cut = m[2].indexOf('//');
                const lead = m[2].slice(0, cut);
                const body = m[2].slice(cut);
                out += esc(lead) + (allowsSlash
                    ? `<span class="tok-comment">${esc(body)}</span>`
                    : esc(body));
            }
            else if (m[3] && allowsHash) out += `<span class="tok-comment">${esc(m[3])}</span>`;
            else if (m[3]) out += esc(m[3]);
            else if (m[4] && allowsDash) out += `<span class="tok-comment">${esc(m[4])}</span>`;
            else if (m[4]) out += esc(m[4]);
            else if (m[5]) out += `<span class="tok-str">${esc(m[5])}</span>`;
            else if (m[6]) out += `<span class="tok-num">${esc(m[6])}</span>`;
            else if (m[7]) {
                out += words.has(m[7])
                    ? `<span class="tok-key">${esc(m[7])}</span>`
                    : `<span class="tok-fn">${esc(m[7])}</span>`;
            } else if (m[8]) {
                if (words.has(m[8])) out += `<span class="tok-key">${esc(m[8])}</span>`;
                else if (/^[A-Z]/.test(m[8])) out += `<span class="tok-type">${esc(m[8])}</span>`;
                else out += esc(m[8]);
            } else out += esc(m[0]);
        }
        out += esc(src.slice(at));
        return out;
    }

    function highlight(code, lang) {
        const l = normalise(lang);
        try {
            if (l === 'diff') return highlightDiff(code);
            if (l === 'markup') return highlightMarkup(code);
            if (!l || l === 'text' || l === 'plain' || l === 'txt') return esc(code);
            return highlightGeneric(code, l);
        } catch (_) {
            return esc(code);
        }
    }

    function displayName(lang) {
        const raw = String(lang || '').trim();
        if (!raw) return 'text';
        return raw.toLowerCase();
    }

    function previewable(lang) {
        const l = String(lang || '').toLowerCase();
        return l === 'html' || l === 'svg' || l === 'xml';
    }

    window.NymbotHighlight = { highlight, escape: esc, displayName, previewable, normalise };
})();
