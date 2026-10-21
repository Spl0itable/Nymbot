import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const ROOT = new URL('../../', import.meta.url);
const at = (rel) => new URL(rel, ROOT).href;

const cacheDir = await mkdtemp(path.join(tmpdir(), 'i18n-guard-'));
process.env.NYM_I18N_CACHE_DIR = cacheDir;
process.env.NYM_TRANSLATE_PROXY = 'http://translate.invalid/api/proxy';
process.env.NYM_I18N_THROTTLE_MS = '1';

const guard = await import(at('i18n/guard.mjs'));
const { audit, dropFailing } = await import(at('i18n/validate.mjs'));
const translate = await import(at('i18n/translate.mjs'));
const strings = await import(at('i18n/strings.mjs')).catch(() => null);
const surfaces = strings ? null : await import(at('i18n/surfaces.mjs'));
const server = await import(at('functions/api/_translate.js'));
const proxy = await import(at('functions/api/proxy.js'));

let passed = 0;
const test = async (name, fn) => {
  await fn();
  passed++;
  console.log(`  ok ${name}`);
};

const EXPECTED_DART = ["Can't unlock?", "Couldn't load", 'Say "hi"', 'raw \\n stays', 'Line\nbreak', 'Join together', "Enter the relay's address", 'Price: $5'];

await test('Dart literals parse whole, with apostrophes, escapes, raw and adjacent strings', () => {
  if (strings) {
    const src = [
      'const List<String> kAppStringsCatalog = <String>[',
      '  "Can\'t unlock?",',
      "  'Couldn\\'t load',",
      '  "Say \\"hi\\"",',
      "  // a comment with a 'quote",
      "  r'raw \\n stays',",
      "  'Line\\nbreak',",
      "  'Join ' 'together',",
      '  "Enter the relay\'s address",',
      "  'Price: \\$5',",
      '];',
    ].join('\n');
    assert.deepEqual(strings.parseDartCatalog(src), EXPECTED_DART);
  } else {
    const src = [
      "final a = t(\"Can't unlock?\");",
      "final b = t('Couldn\\'t load');",
      'final c = t("Say \\"hi\\"");',
      "// t('in a comment')",
      "final e = t('Line\\nbreak');",
      "final f = t('Join ' 'together');",
      'final g = t("Enter the relay\'s address");',
      "final h = t('Price: \\$5');",
      "final i = t('No\\u00a0break');",
    ].join('\n');
    assert.deepEqual([...surfaces.dartStrings(src)], ["Can't unlock?", "Couldn't load", 'Say "hi"', 'Line\nbreak', 'Join together', "Enter the relay's address", 'Price: $5', 'No break']);
  }
});

await test('JS template strings are read whole and interpolation is flagged', () => {
  const lits = guard.scanLiterals("x(`Plain ${'{'}text`); y(`Hi ${name}!`); z('it\\'s'); w(\"a 'b' c\")", 'js');
  assert.deepEqual(lits.map((l) => [l.value, l.interpolated]), [['Plain \u0000text', true], ['Hi \u0000!', true], ["it's", false], ["a 'b' c", false]]);
});

await test('live sources contain no fragments and no protected-only strings', async () => {
  const live = strings ? (await strings.loadSources()).sources : (await surfaces.allSurfaces()).union;
  assert.ok(live.length > 100);
  assert.deepEqual(live.filter(guard.isFragment), []);
  assert.deepEqual(live.filter((s) => !guard.hasWords(s)), []);
  if (strings) assert.ok(live.includes("Can't unlock?"));
});

await test('protect and restore keep placeholders, brands, hashtags, geohashes, URLs, shortcodes and code', () => {
  const src = '@{nym} joined #nymchat and #u4pr on Nostr via https://nymchat.app/x :smile: `/join` (%d, {n})';
  const { masked, tokens } = guard.protect(src);
  assert.deepEqual(tokens, ['@{nym}', '#nymchat', '#u4pr', 'Nostr', 'https://nymchat.app/x', ':smile:', '`/join`', '%d', '{n}']);
  assert.equal(/[@#{}%:`]|Nostr|https/.test(masked), false);
  const back = guard.restore(masked.replace('joined', 'a rejoint'), tokens);
  assert.equal(back, src.replace('joined', 'a rejoint'));
  assert.equal(guard.restore(masked.replace('⟦0⟧', ''), tokens), null);
  assert.equal(guard.restore(`${masked} ⟦0⟧`, tokens), null);
  assert.equal(guard.restore(masked.replace('⟦1⟧', '⟦ 1 ⟧'), tokens), src);
});

await test('validator rejects the reported failures and keeps good entries', () => {
  const v = guard.validateEntry;
  assert.ok(v('@{nym} was unbanned. They can be re-invited.', 'There was no invitation, we can re-invite them.').includes('placeholder'));
  assert.ok(v('#nymchat', 'par Nymchat').includes('protected'));
  assert.ok(v('#{channel} hidden', 'Chanson cachée').includes('placeholder'));
  assert.ok(v('#{channel} hidden', 'Chanson cachée').includes('protected'));
  assert.ok(v(',\n  "Couldn', 'Impossible').includes('fragment'));
  assert.ok(v('%d new messages', 'nouveaux messages').includes('placeholder'));
  assert.ok(v('Save', 'Enregistrer les modifications de ce paramètre maintenant et pour toujours sur cet appareil').includes('length'));
  assert.ok(v('Open Settings to change how often your messages are synced across devices.', 'Ouvrir').includes('length'));
  assert.ok(v('Join {group}', 'Rejoindre ⟦0⟧').length > 0);
  assert.deepEqual(v('@{nym} was unbanned. They can be re-invited.', '@{nym} a été débanni. Il peut être réinvité.'), []);
  assert.deepEqual(v('%d new messages', '%d nouveaux messages'), []);
  assert.deepEqual(v('Welcome to Nymchat', 'Nymchatへようこそ'), []);
  assert.deepEqual(v('A payment that settled but did not credit is usually a claim interrupted between the two sides.', '決済したがクレジットしなかった支払いは、通常、両者の間で中断された請求である。'), []);
});

await test('audit counts and dropFailing keeps only passing entries', () => {
  const map = { Save: 'Enregistrer', '#nymchat': 'par Nymchat', 'Hi {nym}': 'Salut', Block: 'Bloquer' };
  const r = audit(map);
  assert.equal(r.total, 4);
  assert.deepEqual(r.failing.map(([k]) => k), ['#nymchat', 'Hi {nym}']);
  assert.deepEqual(dropFailing(map), { Save: 'Enregistrer', Block: 'Bloquer' });
});

await test('context names the file and UI role', () => {
  const ctx = guard.buildContexts([
    { file: 'lib/a.dart', text: "TextButton(onPressed: go, child: Text(tr('Block')));\nshowSnackBar(tr('#{channel} hidden'));\nfinal x = AppBar(title: Text(tr('Settings')));" },
    { file: 'index.html', text: '<button>Send</button><h2>Relays</h2><input placeholder="Search nyms">' },
  ]);
  assert.equal(guard.contextFor(ctx, 'Block'), 'lib/a.dart, button');
  assert.equal(guard.contextFor(ctx, '#{channel} hidden'), 'lib/a.dart, toast');
  assert.equal(guard.contextFor(ctx, 'Settings'), 'lib/a.dart, title');
  assert.equal(guard.contextFor(ctx, 'Send'), 'index.html, button');
  assert.equal(guard.contextFor(ctx, 'Relays'), 'index.html, title');
  assert.equal(guard.contextFor(ctx, 'Search nyms'), 'index.html, input placeholder');
  assert.equal(guard.contextFor(ctx, 'Unknown words here.'), 'app interface, sentence');
});

await test('translate step sends masked text, context and glossary in one request, restores and validates', async () => {
  const bodies = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    bodies.push(body);
    const translations = body.texts.map((t) => (t.startsWith('Mangle') ? 'Il n\'y avait pas' : t.replace('joined', 'a rejoint').replace('Save', 'Enregistrer')));
    return new Response(JSON.stringify({ translations }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const contexts = guard.buildContexts([{ file: 'lib/b.dart', text: "ElevatedButton(child: Text(tr('Save')))" }]);
    let error = null;
    try {
      await translate.translateMissing('fr', ['Save', '@{nym} joined #nymchat', 'Mangle {n} things'], { contexts });
    } catch (err) {
      error = err;
    }
    assert.ok(error && /1\/3 strings failed/.test(error.message), String(error && error.message));
    assert.equal(bodies.length, 1);
    const [body] = bodies;
    assert.deepEqual(body.texts, ['Save', '⟦0⟧ joined ⟦1⟧', 'Mangle ⟦0⟧ things']);
    assert.equal(body.contexts.length, 3);
    assert.equal(body.contexts[0], 'lib/b.dart, button');
    assert.match(body.contexts[1], /keep tokens exactly: ⟦0⟧ = @\{nym\}, ⟦1⟧ = #nymchat/);
    for (const term of ['nym', 'PM', 'zap', 'geohash', 'relay', 'flair']) assert.match(body.glossary, new RegExp(`(^|; )${term}: `));
    const saved = JSON.parse(await readFile(path.join(cacheDir, 'fr.json'), 'utf8'));
    assert.deepEqual(saved, { '@{nym} joined #nymchat': '@{nym} a rejoint #nymchat', Save: 'Enregistrer' });
  } finally {
    globalThis.fetch = realFetch;
  }
});

await test('server: a batch with contexts goes to the instruct model with context and glossary', async () => {
  const calls = [];
  const ai = {
    run: async (model, input) => {
      calls.push({ model, input });
      if (input.messages) return { response: '⟦0⟧ a rejoint' };
      return { translated_text: 'MT' };
    },
  };
  const messages = server.uiPrompt({ text: '⟦0⟧ joined', target: 'fr', context: 'lib/a.dart, toast', glossary: 'nym: a user name' });
  assert.match(messages[0].content, /⟦0⟧/);
  assert.match(messages[0].content, /Glossary of fixed terms: nym: a user name/);
  assert.equal(messages[1].content, 'Context: lib/a.dart, toast\nText: ⟦0⟧ joined');
  const post = (body) => {
    const request = new Request('https://x.test/api/proxy?action=translate', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-Nym-Build': 'tok' },
      body: JSON.stringify(body),
    });
    const ctx = { env: { AI: ai, NYM_BUILD_TOKEN: 'tok' }, waitUntil() {} };
    return proxy.handleTranslate ? proxy.handleTranslate(request, ctx) : proxy.onRequest({ ...ctx, request });
  };
  const res = await post({ texts: ['⟦0⟧ joined'], source: 'en', target: 'fr', contexts: ['lib/a.dart, toast'], glossary: 'nym: a user name' });
  assert.deepEqual((await res.json()).translations, ['⟦0⟧ a rejoint']);
  assert.equal(calls.at(-1).model, server.LLM_MODEL);
  assert.match(calls.at(-1).input.messages[1].content, /^Context: lib\/a\.dart, toast/);
  await post({ texts: ['Hello'], source: 'en', target: 'fr' });
  assert.notEqual(calls.at(-1).model, server.LLM_MODEL);
});

await rm(cacheDir, { recursive: true, force: true });
console.log(`${passed} i18n validation tests passed`);
