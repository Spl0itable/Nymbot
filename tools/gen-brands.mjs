import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const SOURCE = path.join(ROOT, 'app/js/icons.js');

function slice(src, from, to) {
  const a = src.indexOf(from);
  if (a < 0) throw new Error('could not find ' + from);
  const b = src.indexOf(to, a);
  if (b < 0) throw new Error('could not find the end of ' + from);
  return src.slice(a, b);
}

function parseBrands(src) {
  const body = slice(src, 'const BRANDS = {', '\n    const BRAND_ALIASES');
  const out = {};
  const re = /^ {8}'?([a-z0-9-]+)'?: \{\s*\n\s*fill: '([^']+)',\s*\n\s*box: \[([^\]]+)\],\s*\n\s*paths: \[([\s\S]*?)\n\s*\]\s*\n\s*\},?/gm;
  let m;
  while ((m = re.exec(body)) !== null) {
    out[m[1]] = {
      fill: m[2],
      box: m[3].split(',').map((n) => Number(n.trim())),
      paths: [...m[4].matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((p) => p[1])
    };
  }
  // A brand the regex fails to read would silently vanish from three surfaces at
  // once, so count the declarations and refuse to emit a short table.
  const declared = [...body.matchAll(/^ {8}'?([a-z0-9-]+)'?: \{/gm)].map((m) => m[1]);
  const missing = declared.filter((n) => !out[n]);
  if (missing.length) {
    throw new Error('could not read ' + missing.length + ' of ' + declared.length
      + ' brands (' + missing.join(', ') + ') — the table shape changed');
  }
  return out;
}

function parseAliases(src) {
  const body = slice(src, 'const BRAND_ALIASES = {', '\n    const BRAND_TINTS');
  const out = {};
  for (const m of body.matchAll(/'([a-z0-9-]+)':\s*'([a-z0-9-]+)'/g)) out[m[1]] = m[2];
  return out;
}

function parseTints(src) {
  const body = slice(src, 'const BRAND_TINTS = [', '];');
  return [...body.matchAll(/'(#[0-9A-Fa-f]{6})'/g)].map((m) => m[1]);
}

const src = await readFile(SOURCE, 'utf8');
const brands = parseBrands(src);
const aliases = parseAliases(src);
const tints = parseTints(src);
const names = Object.keys(brands).sort();
if (!names.length) throw new Error('no brands parsed — the table shape changed');

const site = `(function () {
    'use strict';
    var NS = 'http://www.w3.org/2000/svg';
    var PAD = 4.4;
    var BRANDS = ${JSON.stringify(brands, null, 4).replace(/\n/g, '\n    ')};
    var ALIASES = ${JSON.stringify(aliases, null, 4).replace(/\n/g, '\n    ')};
    var TINTS = ${JSON.stringify(tints)};

    var round = function (n) { return Math.round(n * 1000) / 1000; };

    var tint = function (key) {
        var h = 0;
        for (var i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) % 100003;
        return TINTS[h % TINTS.length];
    };

    var initials = function (key) {
        var words = key.split(/[^a-z0-9]+/).filter(Boolean);
        if (words.length > 1) return (words[0][0] + words[1][0]).toUpperCase();
        var one = (words[0] || '').replace(/[^a-z0-9]/g, '');
        return one.slice(0, 2).toUpperCase() || '?';
    };

    var mark = function (slug, size) {
        var raw = String(slug || '').toLowerCase();
        var key = ALIASES[raw] || raw;
        var hit = BRANDS[key];
        var px = size || 18;
        var svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('width', String(px));
        svg.setAttribute('height', String(px));
        svg.setAttribute('class', 'brand-tile');
        svg.setAttribute('aria-hidden', 'true');
        svg.setAttribute('focusable', 'false');
        var inner;
        if (hit) {
            var inset = 24 - PAD * 2;
            var scale = inset / Math.max(hit.box[2], hit.box[3]);
            var tx = PAD + (inset - hit.box[2] * scale) / 2 - hit.box[0] * scale;
            var ty = PAD + (inset - hit.box[3] * scale) / 2 - hit.box[1] * scale;
            inner = '<g fill="#fff" fill-rule="evenodd" clip-rule="evenodd" transform="translate('
                + round(tx) + ' ' + round(ty) + ') scale(' + round(scale) + ')">'
                + hit.paths.map(function (d) { return '<path d="' + d + '"></path>'; }).join('')
                + '</g>';
        } else {
            var text = initials(key);
            inner = '<text x="12" y="12" fill="#fff" font-size="' + (text.length > 1 ? 9 : 11) + '"'
                + ' font-weight="700" font-family="system-ui, sans-serif"'
                + ' text-anchor="middle" dominant-baseline="central">' + text + '</text>';
        }
        svg.innerHTML = '<rect x="0" y="0" width="24" height="24" rx="6" fill="'
            + (hit ? hit.fill : tint(key)) + '"></rect>' + inner;
        return svg;
    };

    var markup = function (slug, size) {
        var raw = String(slug || '').toLowerCase();
        var key = ALIASES[raw] || raw;
        var hit = BRANDS[key];
        var px = size || 18;
        var inner;
        if (hit) {
            var inset = 24 - PAD * 2;
            var scale = inset / Math.max(hit.box[2], hit.box[3]);
            var tx = PAD + (inset - hit.box[2] * scale) / 2 - hit.box[0] * scale;
            var ty = PAD + (inset - hit.box[3] * scale) / 2 - hit.box[1] * scale;
            inner = '<g fill="#fff" fill-rule="evenodd" clip-rule="evenodd" transform="translate('
                + round(tx) + ' ' + round(ty) + ') scale(' + round(scale) + ')">'
                + hit.paths.map(function (d) { return '<path d="' + d + '"></path>'; }).join('')
                + '</g>';
        } else {
            var text = initials(key);
            inner = '<text x="12" y="12" fill="#fff" font-size="' + (text.length > 1 ? 9 : 11) + '"'
                + ' font-weight="700" font-family="system-ui, sans-serif"'
                + ' text-anchor="middle" dominant-baseline="central">' + text + '</text>';
        }
        return '<svg class="brand-tile" viewBox="0 0 24 24" width="' + px + '" height="' + px
            + '" aria-hidden="true" focusable="false">'
            + '<rect x="0" y="0" width="24" height="24" rx="6" fill="'
            + (hit ? hit.fill : tint(key)) + '"></rect>' + inner + '</svg>';
    };

    window.NymbotBrands = { mark: mark, markup: markup, names: Object.keys(BRANDS) };
})();
`;

const dartRect = (b) => 'Rect.fromLTWH(' + b.map((n) => (Number.isInteger(n) ? n : n)).join(', ') + ')';
const dartString = (s) => "'" + s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$') + "'";

const dart = `import 'dart:ui' show Rect;

class BrandMark {
  const BrandMark(this.color, this.box, this.paths);

  final int color;
  final Rect box;
  final List<String> paths;
}

class BrandMarkTable {
  const BrandMarkTable._();

  static const Map<String, BrandMark> marks = {
${names.map((n) => `    '${n}': BrandMark(
      0xFF${brands[n].fill.replace('#', '').toUpperCase()},
      ${dartRect(brands[n].box)},
      [
${brands[n].paths.map((d) => '        ' + dartString(d) + ',').join('\n')}
      ],
    ),`).join('\n')}
  };

  static const Map<String, String> aliases = {
${Object.entries(aliases).map(([k, v]) => `    '${k}': '${v}',`).join('\n')}
  };

  static const List<int> tints = [
${tints.map((t) => '    0xFF' + t.replace('#', '').toUpperCase() + ',').join('\n')}
  ];

  static String canonical(String slug) {
    final key = slug.toLowerCase();
    return aliases[key] ?? key;
  }

  static BrandMark? of(String slug) => marks[canonical(slug)];

  static int tintFor(String slug) {
    final key = canonical(slug);
    var h = 0;
    for (var i = 0; i < key.length; i++) {
      h = (h * 31 + key.codeUnitAt(i)) % 100003;
    }
    return tints[h % tints.length];
  }

  static String initials(String slug) {
    final words = canonical(slug).split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty).toList();
    if (words.length > 1) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    final one = words.isEmpty ? '' : words[0].replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (one.isEmpty) return '?';
    return one.substring(0, one.length >= 2 ? 2 : 1).toUpperCase();
  }
}
`;

const flutter = process.argv[2] || process.env.NYMBOT_FLUTTER
  || path.resolve(ROOT, '../nymbot-flutter');
const nymchatWeb = process.env.NYMCHAT_WEB || path.resolve(ROOT, '../nym-staging');

await writeFile(path.join(ROOT, 'brand-marks.js'), site);
const nymchatSite = path.join(nymchatWeb, 'js/brand-marks.js');
try { await writeFile(nymchatSite, site); } catch (e) {
  console.log('  skipped ' + nymchatSite + ' (' + e.code + ')');
}
const nymchat = process.env.NYMCHAT_FLUTTER
  || path.resolve(ROOT, '../spl0itable/flutter-app');
const dartTargets = [
  path.join(ROOT, 'flutter/lib/features/brand_marks.dart'),
  path.join(flutter, 'lib/features/brand_marks.dart'),
  path.join(nymchat, 'lib/features/nymbot/brand_marks.dart')
];
for (const target of dartTargets) {
  try { await writeFile(target, dart); } catch (e) {
    console.log('  skipped ' + target + ' (' + e.code + ')');
  }
}

console.log('brand-marks.js and brand_marks.dart generated from app/js/icons.js');
console.log('  ' + names.length + ' marks, ' + Object.keys(aliases).length
  + ' aliases, ' + tints.length + ' fallback tints');
console.log('  ' + names.join(' '));
