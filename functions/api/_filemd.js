var FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)[^`]*$/;
var HEADING = /^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$/;
var RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
var BULLET = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/;
var QUOTE = /^ {0,3}>[ ]?(.*)$/;
var TABLE_DIVIDER = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;
var PAGE_BREAK = /^\s*(?:\\pagebreak|\\newpage|<!--\s*page-?break\s*-->|<div[^>]*page-break-(?:after|before)\s*:\s*always[^>]*>\s*<\/div>|\f)\s*$/i;

function expandTabs(line) {
  return line.indexOf("\t") === -1 ? line : line.replace(/\t/g, "    ");
}

function indentOf(line) {
  var m = /^ */.exec(line);
  return m ? m[0].length : 0;
}

export function splitTableRow(line) {
  var s = String(line).trim();
  if (s.charAt(0) === "|") s = s.slice(1);
  if (s.charAt(s.length - 1) === "|" && s.charAt(s.length - 2) !== "\\") s = s.slice(0, -1);
  var cells = [];
  var cur = "";
  var inCode = false;
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i);
    if (c === "\\" && s.charAt(i + 1) === "|") { cur += "|"; i++; continue; }
    if (c === "`") inCode = !inCode;
    if (c === "|" && !inCode) { cells.push(cur.trim()); cur = ""; continue; }
    cur += c;
  }
  cells.push(cur.trim());
  return cells;
}

function alignOf(cell) {
  var c = cell.trim();
  var left = c.charAt(0) === ":";
  var right = c.charAt(c.length - 1) === ":";
  return left && right ? "center" : right ? "right" : "left";
}

function isTableStart(lines, i) {
  return i + 1 < lines.length && lines[i].indexOf("|") !== -1 && TABLE_DIVIDER.test(lines[i + 1]) && lines[i + 1].indexOf("-") !== -1;
}

function startsBlock(line, lines, i) {
  return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || BULLET.test(line) || PAGE_BREAK.test(line) || isTableStart(lines, i);
}

export function parseInline(text) {
  var out = [];
  walkInline(String(text || ""), {}, out);
  var merged = [];
  for (var i = 0; i < out.length; i++) {
    var prev = merged[merged.length - 1];
    var cur = out[i];
    if (!cur.text) continue;
    if (prev && prev.b === cur.b && prev.i === cur.i && prev.code === cur.code && prev.s === cur.s && prev.href === cur.href) {
      prev.text += cur.text;
    } else {
      merged.push(cur);
    }
  }
  return merged;
}

function span(text, style) {
  return { text: text, b: !!style.b, i: !!style.i, code: !!style.code, s: !!style.s, href: style.href || "" };
}

function safeHref(href) {
  var h = String(href || "").trim().replace(/^<|>$/g, "");
  return /^(https?:\/\/|mailto:)[^\s"<>]+$/i.test(h) ? h : "";
}

var INLINE_RULES = [
  { re: /\\([\\`*_{}\[\]()#+\-.!|~<>])/, run: function (m, style, out) { out.push(span(m[1], style)); } },
  { re: /(`+)([\s\S]*?[^`])\1(?!`)/, run: function (m, style, out) { out.push(span(m[2].replace(/^ (.*) $/, "$1"), Object.assign({}, style, { code: true }))); } },
  { re: /!\[([^\]\n]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)/, run: function (m, style, out) { if (m[1]) walkInline(m[1], style, out); } },
  { re: /\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, run: function (m, style, out) {
    var href = safeHref(m[2]);
    walkInline(m[1], href ? Object.assign({}, style, { href: href }) : style, out);
  } },
  { re: /<((?:https?:\/\/|mailto:)[^\s<>]+)>/, run: function (m, style, out) { out.push(span(m[1], Object.assign({}, style, { href: safeHref(m[1]) }))); } },
  { re: /\*\*\*(?=\S)([\s\S]*?\S)\*\*\*/, run: function (m, style, out) { walkInline(m[1], Object.assign({}, style, { b: true, i: true }), out); } },
  { re: /\*\*(?=\S)([\s\S]*?\S)\*\*/, run: function (m, style, out) { walkInline(m[1], Object.assign({}, style, { b: true }), out); } },
  { re: /(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/, lead: true, run: function (m, style, out) { walkInline(m[2], Object.assign({}, style, { b: true }), out); } },
  { re: /\*(?=[^\s*])([^*]*?[^\s*])\*/, run: function (m, style, out) { walkInline(m[1], Object.assign({}, style, { i: true }), out); } },
  { re: /(^|[^\w])_(?=[^\s_])([^_]*?[^\s_])_(?!\w)/, lead: true, run: function (m, style, out) { walkInline(m[2], Object.assign({}, style, { i: true }), out); } },
  { re: /~~(?=\S)([\s\S]*?\S)~~/, run: function (m, style, out) { walkInline(m[1], Object.assign({}, style, { s: true }), out); } },
  { re: /(https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"])/, run: function (m, style, out) {
    out.push(span(m[1], style.href ? style : Object.assign({}, style, { href: safeHref(m[1]) })));
  } }
];

function walkInline(text, style, out) {
  var rest = text;
  while (rest) {
    var best = null;
    for (var r = 0; r < INLINE_RULES.length; r++) {
      var rule = INLINE_RULES[r];
      var m = rule.re.exec(rest);
      if (!m) continue;
      var at = m.index + (rule.lead ? m[1].length : 0);
      if (!best || at < best.at) best = { at: at, m: m, rule: rule };
      if (at === 0) break;
    }
    if (!best) {
      out.push(span(rest, style));
      return;
    }
    if (best.at > 0) out.push(span(rest.slice(0, best.at), style));
    best.rule.run(best.m, style, out);
    rest = rest.slice(best.m.index + best.m[0].length);
  }
}

export function inlineText(inlines) {
  return (inlines || []).map(function (s) { return s.text; }).join("");
}

function parseList(lines, i) {
  var first = BULLET.exec(lines[i]);
  var base = first[1].length;
  var ordered = /\d/.test(first[2]);
  var start = ordered ? parseInt(first[2], 10) : 1;
  var items = [];
  while (i < lines.length) {
    var m = BULLET.exec(lines[i]);
    if (!m || m[1].length !== base || /\d/.test(m[2]) !== ordered) break;
    var contentIndent = base + m[2].length + 1;
    var body = [m[3]];
    i++;
    while (i < lines.length) {
      var line = lines[i];
      if (!line.trim()) {
        var next = i + 1 < lines.length ? lines[i + 1] : "";
        if (next.trim() && indentOf(next) >= contentIndent) { body.push(""); i++; continue; }
        break;
      }
      var bm = BULLET.exec(line);
      if (bm && bm[1].length <= base) break;
      if (indentOf(line) >= Math.min(contentIndent, base + 2)) {
        body.push(line.slice(Math.min(indentOf(line), contentIndent)));
        i++;
        continue;
      }
      if (startsBlock(line, lines, i)) break;
      body.push(line.trim());
      i++;
    }
    var task = null;
    var tm = /^\[([ xX])\][ \t]+/.exec(body[0]);
    if (tm) {
      task = tm[1] !== " ";
      body[0] = body[0].slice(tm[0].length);
    }
    items.push({ task: task, blocks: parseBlocks(body) });
    while (i < lines.length && !lines[i].trim()) {
      var after = i + 1 < lines.length ? BULLET.exec(lines[i + 1]) : null;
      if (after && after[1].length === base) { i++; continue; }
      break;
    }
  }
  return { block: { type: "list", ordered: ordered, start: start, items: items }, next: i };
}

function parseBlocks(lines) {
  var blocks = [];
  var i = 0;
  while (i < lines.length) {
    var line = lines[i];
    if (!line.trim()) { i++; continue; }
    if (PAGE_BREAK.test(line)) { blocks.push({ type: "pagebreak" }); i++; continue; }
    var fence = FENCE.exec(line);
    if (fence) {
      var mark = fence[1];
      var lang = fence[2] || "";
      var body = [];
      var lead = indentOf(line);
      i++;
      while (i < lines.length) {
        var close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(lines[i]);
        if (close && close[1].charAt(0) === mark.charAt(0) && close[1].length >= mark.length) { i++; break; }
        body.push(lead ? lines[i].replace(new RegExp("^ {0," + lead + "}"), "") : lines[i]);
        i++;
      }
      blocks.push({ type: "code", lang: lang, text: body.join("\n") });
      continue;
    }
    var heading = HEADING.exec(line);
    if (heading) {
      blocks.push({ type: "heading", level: heading[1].length, inlines: parseInline(heading[2]) });
      i++;
      continue;
    }
    if (RULE.test(line)) { blocks.push({ type: "hr" }); i++; continue; }
    if (isTableStart(lines, i)) {
      var head = splitTableRow(lines[i]);
      var align = splitTableRow(lines[i + 1]).map(alignOf);
      var rows = [];
      i += 2;
      while (i < lines.length && lines[i].trim() && lines[i].indexOf("|") !== -1) {
        rows.push(splitTableRow(lines[i]));
        i++;
      }
      var width = head.length;
      rows.forEach(function (r) { if (r.length > width) width = r.length; });
      var pad = function (r) { var c = r.slice(0, width); while (c.length < width) c.push(""); return c.map(parseInline); };
      while (align.length < width) align.push("left");
      blocks.push({ type: "table", head: pad(head), rows: rows.map(pad), align: align.slice(0, width) });
      continue;
    }
    if (QUOTE.test(line)) {
      var quoted = [];
      while (i < lines.length && lines[i].trim()) {
        var q = QUOTE.exec(lines[i]);
        quoted.push(q ? q[1] : lines[i]);
        i++;
      }
      blocks.push({ type: "quote", blocks: parseBlocks(quoted) });
      continue;
    }
    if (BULLET.test(line)) {
      var list = parseList(lines, i);
      blocks.push(list.block);
      i = list.next;
      continue;
    }
    var para = [];
    while (i < lines.length && lines[i].trim() && (!para.length || !startsBlock(lines[i], lines, i))) {
      para.push(lines[i]);
      i++;
    }
    var text = para.map(function (l, k) {
      var hard = / {2,}$/.test(l) || /\\$/.test(l);
      var body = l.replace(/\\$/, "").trim();
      return k < para.length - 1 ? body + (hard ? "\n" : " ") : body;
    }).join("");
    blocks.push({ type: "para", inlines: parseInline(text) });
  }
  return blocks;
}

export function parseMarkdown(source) {
  var lines = String(source || "").replace(/\r\n?/g, "\n").split("\n").map(expandTabs);
  return parseBlocks(lines);
}

var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: "\u00a0", mdash: "\u2014", ndash: "\u2013", hellip: "\u2026", copy: "\u00a9", reg: "\u00ae", trade: "\u2122", rsquo: "\u2019", lsquo: "\u2018", rdquo: "\u201d", ldquo: "\u201c", bull: "\u2022", euro: "\u20ac" };

export function decodeEntities(s) {
  return String(s).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, function (m, e) {
    if (e.charAt(0) === "#") {
      var n = e.charAt(1).toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return n > 0 && n < 0x110000 ? String.fromCodePoint(n) : m;
    }
    var k = e.toLowerCase();
    return Object.prototype.hasOwnProperty.call(ENTITIES, k) ? ENTITIES[k] : m;
  });
}

export function looksLikeHtml(s) {
  var t = String(s || "").trim();
  return /^<!doctype html/i.test(t) || /^<html[\s>]/i.test(t) || (/^<(?:body|div|section|article|h[1-6]|p|table|ul|ol)[\s>]/i.test(t) && /<\/[a-z0-9]+>\s*$/i.test(t));
}

export function htmlToMarkdown(html) {
  var s = String(html || "");
  s = s.replace(/<!--[\s\S]*?-->/g, "");
  s = s.replace(/<(script|style|head|template|noscript|svg)[\s\S]*?<\/\1\s*>/gi, "");
  s = s.replace(/<pre[^>]*>([\s\S]*?)<\/pre>/gi, function (m, body) {
    return "\n\n```\n" + decodeEntities(body.replace(/<[^>]+>/g, "")) + "\n```\n\n";
  });
  s = s.replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi, function (m, n, body) {
    return "\n\n" + "######".slice(0, Number(n)) + " " + body.replace(/\s+/g, " ").trim() + "\n\n";
  });
  s = s.replace(/<tr[^>]*>([\s\S]*?)<\/tr>/gi, function (m, body) {
    var cells = [];
    body.replace(/<t([hd])[^>]*>([\s\S]*?)<\/t\1>/gi, function (c, kind, inner) {
      cells.push(inner.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").replace(/\|/g, "\\|").trim());
      return "";
    });
    return "\n|" + cells.join("|") + "|" + (/<th/i.test(body) ? "\n|" + cells.map(function () { return "---"; }).join("|") + "|" : "");
  });
  s = s.replace(/<\/?(table|thead|tbody|tfoot)[^>]*>/gi, "\n");
  s = s.replace(/<li[^>]*>/gi, "\n- ").replace(/<\/li>/gi, "");
  s = s.replace(/<\/?(ul|ol)[^>]*>/gi, "\n");
  s = s.replace(/<(strong|b)(\s[^>]*)?>([\s\S]*?)<\/\1>/gi, "**$3**");
  s = s.replace(/<(em|i)(\s[^>]*)?>([\s\S]*?)<\/\1>/gi, "*$3*");
  s = s.replace(/<code[^>]*>([\s\S]*?)<\/code>/gi, "`$1`");
  s = s.replace(/<a\s[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, "[$2]($1)");
  s = s.replace(/<br\s*\/?>/gi, "\\\n");
  s = s.replace(/<hr[^>]*>/gi, "\n\n---\n\n");
  s = s.replace(/<blockquote[^>]*>([\s\S]*?)<\/blockquote>/gi, function (m, body) {
    return "\n\n" + body.replace(/<[^>]+>/g, "").trim().split("\n").map(function (l) { return "> " + l.trim(); }).join("\n") + "\n\n";
  });
  s = s.replace(/<\/?(p|div|section|article|header|footer|main|nav|aside|body|html|figure|figcaption)[^>]*>/gi, "\n\n");
  s = s.replace(/<!doctype[^>]*>/gi, "").replace(/<[^>]+>/g, "");
  s = decodeEntities(s);
  return s.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}
