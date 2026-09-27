// Nymbot is a US company's product, so every string a reader sees is American
// English. The two app string sets are the whole translatable UI, and the
// pages are the marketing site and the knowledge base; a British spelling in
// any of them ships to 132 languages as the English original.
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { appSources, flutterSources } from '../surfaces.mjs';

let pass = 0, fail = 0;
const ok = (name, cond, extra) => {
  if (cond) { pass++; console.log('  ok ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? '\n       ' + extra : '')); }
};

// British spelling on the left, what it ships as on the right. Only forms
// whose American spelling differs, and only whole words: "axe" and "grey" are
// both current in American usage, and "toward(s)" is a style choice, so they
// are deliberately absent.
const BRITISH = {
  apologise: 'apologize', apologised: 'apologized', apologising: 'apologizing',
  organise: 'organize', organised: 'organized', organising: 'organizing',
  organisation: 'organization', organisations: 'organizations',
  recognise: 'recognize', recognised: 'recognized', recognising: 'recognizing',
  customise: 'customize', customised: 'customized',
  personalise: 'personalize', personalised: 'personalized',
  authorise: 'authorize', authorised: 'authorized', authorisation: 'authorization',
  summarise: 'summarize', summarised: 'summarized', summarising: 'summarizing',
  minimise: 'minimize', maximise: 'maximize',
  initialise: 'initialize', initialised: 'initialized', initialisation: 'initialization',
  normalise: 'normalize', normalised: 'normalized',
  prioritise: 'prioritize', synchronise: 'synchronize', synchronised: 'synchronized',
  serialise: 'serialize', serialised: 'serialized',
  analyse: 'analyze', analysed: 'analyzed', analysing: 'analyzing',
  capitalise: 'capitalize', capitalised: 'capitalized',
  finalise: 'finalize', utilise: 'utilize', realise: 'realize', emphasise: 'emphasize',
  colour: 'color', colours: 'colors', coloured: 'colored', colouring: 'coloring',
  favourite: 'favorite', favourites: 'favorites', favour: 'favor', favourable: 'favorable',
  behaviour: 'behavior', behaviours: 'behaviors', behavioural: 'behavioral',
  honour: 'honor', honours: 'honors', honoured: 'honored',
  labour: 'labor', neighbour: 'neighbor', neighbours: 'neighbors',
  rumour: 'rumor', flavour: 'flavor', humour: 'humor', armour: 'armor',
  centre: 'center', centres: 'centers', centred: 'centered',
  metre: 'meter', metres: 'meters', litre: 'liter', litres: 'liters',
  theatre: 'theater', fibre: 'fiber',
  travelled: 'traveled', travelling: 'traveling', traveller: 'traveler',
  cancelled: 'canceled', cancelling: 'canceling', cancellation: 'cancellation',
  labelled: 'labeled', labelling: 'labeling', modelled: 'modeled', modelling: 'modeling',
  signalled: 'signaled', levelled: 'leveled', fuelled: 'fueled',
  totalled: 'totaled', dialled: 'dialed', dialling: 'dialing',
  defence: 'defense', offence: 'offense', licence: 'license', pretence: 'pretense',
  practise: 'practice', practised: 'practiced',
  programme: 'program', programmes: 'programs',
  cheque: 'check', storey: 'story', kerb: 'curb', tyre: 'tire',
  sceptical: 'skeptical', scepticism: 'skepticism',
  manoeuvre: 'maneuver', aeroplane: 'airplane', aluminium: 'aluminum',
  whilst: 'while', amongst: 'among',
  learnt: 'learned', spelt: 'spelled', burnt: 'burned', dreamt: 'dreamed',
  judgement: 'judgment', judgements: 'judgments',
  acknowledgement: 'acknowledgment', acknowledgements: 'acknowledgments',
  maths: 'math', ageing: 'aging',
};
// cancellation is spelled the same either side of the Atlantic.
delete BRITISH.cancellation;

const RE = new RegExp('\\b(' + Object.keys(BRITISH).join('|') + ')\\b', 'gi');

const offenders = (text) => {
  const seen = new Map();
  for (const m of text.matchAll(RE)) {
    const word = m[1].toLowerCase();
    if (!seen.has(word)) seen.set(word, m[0]);
  }
  return seen;
};

const report = (label, hits) => {
  ok(`${label}`, hits.length === 0,
    hits.slice(0, 12).map((h) => `${h.where}: "${h.found}" → "${h.want}"`).join('\n       ')
    + (hits.length > 12 ? `\n       …and ${hits.length - 12} more` : ''));
};

// --- the two app string sets ------------------------------------------------
for (const surface of [await appSources(), await flutterSources()]) {
  const hits = [];
  for (const s of surface.sources) {
    for (const [word, found] of offenders(s)) {
      hits.push({ where: JSON.stringify(s.slice(0, 60)), found, want: BRITISH[word] });
    }
  }
  report(`every ${surface.label} string reads as American English`, hits);
}

// --- the marketing site and the knowledge base -------------------------------
const root = new URL('../../', import.meta.url).pathname;
async function htmlFiles(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...await htmlFiles(full));
    else if (e.name.endsWith('.html')) out.push(full);
  }
  return out;
}
{
  const files = [path.join(root, 'index.html'), ...await htmlFiles(path.join(root, 'pages'))];
  const hits = [];
  for (const file of files) {
    // Only what a reader sees: tags, attributes and comments are not prose.
    const text = (await readFile(file, 'utf8'))
      .replace(/<!--[\s\S]*?-->/g, ' ')
      .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
      .replace(/<[^>]*>/g, ' ');
    for (const [word, found] of offenders(text)) {
      hits.push({ where: path.relative(root, file), found, want: BRITISH[word] });
    }
  }
  report(`so does every page of the site and the knowledge base, all ${files.length} of them`, hits);
}

console.log(fail ? `\n${fail} failed, ${pass} passed` : `\nall ${pass} assertions passed`);
process.exit(fail ? 1 : 0);
