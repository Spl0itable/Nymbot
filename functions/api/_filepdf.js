import { FILE_FONTS } from "./_filefonts.js";
import { ttfParse, ttfSubset } from "./_ttf.js";
import { parseMarkdown, inlineText } from "./_filemd.js";
import { utf8, concatBytes, deflateBytes, base64ToBytes } from "./_filezip.js";

export var PDF_MAX_PAGES = 300;

var PAPER = { letter: [612, 792], a4: [595.28, 841.89] };
var MARGIN = { left: 60, right: 60, top: 60, bottom: 64 };
var BODY_SIZE = 11;
var CODE_SIZE = 9.5;
var LINE = 1.42;
var HEADING_SIZES = [0, 22, 17.5, 14.5, 12.5, 11.5, 11];
var TEXT = [0.13, 0.13, 0.15];
var MUTED = [0.38, 0.38, 0.42];
var LINK = [0.09, 0.32, 0.72];
var RULE = [0.78, 0.78, 0.8];
var CODE_BG = [0.95, 0.95, 0.96];
var HEAD_BG = [0.93, 0.94, 0.96];
var SKEW = 0.2;
var INVISIBLE = /[\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff\ufe00-\ufe0f]/;

var loaded = null;

function faces() {
  if (loaded) return loaded;
  loaded = {};
  Object.keys(FILE_FONTS).forEach(function (key) {
    var font = ttfParse(base64ToBytes(FILE_FONTS[key].data));
    font.key = key;
    font.name = FILE_FONTS[key].name;
    loaded[key] = font;
  });
  return loaded;
}

function newDoc(paper) {
  var size = PAPER[paper] || PAPER.letter;
  return {
    width: size[0],
    height: size[1],
    pages: [],
    page: null,
    y: 0,
    used: {},
    missing: 0,
    missingSample: "",
    truncated: false,
    full: false
  };
}

function addPage(doc) {
  if (doc.pages.length >= PDF_MAX_PAGES) {
    doc.full = true;
    doc.truncated = true;
    return false;
  }
  doc.page = { ops: [], links: [] };
  doc.pages.push(doc.page);
  doc.y = MARGIN.top;
  return true;
}

function bottom(doc) {
  return doc.height - MARGIN.bottom;
}

function ensure(doc, h) {
  if (doc.full) return false;
  if (!doc.page) return addPage(doc);
  if (doc.y + h <= bottom(doc) + 0.01) return true;
  if (doc.y <= MARGIN.top + 0.01) return true;
  return addPage(doc);
}

function glyphOf(doc, faceKey, cp) {
  var all = faces();
  var order = faceKey === "sans" ? ["sans"] : [faceKey, "sans"];
  for (var i = 0; i < order.length; i++) {
    var f = all[order[i]];
    var g = f.cmap.get(cp);
    if (g) return { face: f, gid: g, cp: cp };
  }
  doc.missing++;
  if (doc.missingSample.length < 12) doc.missingSample += String.fromCodePoint(cp);
  var fb = all[faceKey] || all.sans;
  return { face: fb, gid: fb.cmap.get(0x3f) || 0, cp: 0x3f };
}

function markUsed(doc, face, gid, cp) {
  var u = doc.used[face.key] || (doc.used[face.key] = { gids: new Set(), cps: new Map() });
  u.gids.add(gid);
  if (!u.cps.has(gid)) u.cps.set(gid, cp);
}

function styleFace(st) {
  return st.code ? "mono" : st.b ? "bold" : "sans";
}

function runsOf(doc, text, st, size) {
  var runs = [];
  var cur = null;
  var wanted = styleFace(st);
  for (var ch of String(text)) {
    if (INVISIBLE.test(ch)) continue;
    var cp = ch.codePointAt(0);
    if (cp === 0x09) cp = 0x20;
    if (cp < 0x20 || (cp >= 0x7f && cp < 0xa0)) continue;
    if (cp === 0xa0) cp = 0x20;
    var g = glyphOf(doc, wanted, cp);
    var w = g.face.advances[g.gid] / g.face.unitsPerEm * size;
    if (!cur || cur.face !== g.face) {
      cur = { face: g.face, size: size, glyphs: [], width: 0, st: st };
      runs.push(cur);
    }
    cur.glyphs.push({ gid: g.gid, cp: g.cp, w: w });
    cur.width += w;
  }
  return runs;
}

function tokens(inlines) {
  var out = [];
  (inlines || []).forEach(function (sp) {
    var parts = String(sp.text).split(/(\n| +)/);
    parts.forEach(function (p) {
      if (!p) return;
      if (p === "\n") out.push({ br: true });
      else if (/^ +$/.test(p)) out.push({ space: true, st: sp });
      else out.push({ word: p, st: sp });
    });
  });
  return out;
}

function layoutLines(doc, inlines, o) {
  var size = o.size;
  var maxW = o.width;
  var lines = [];
  var line = { items: [], width: 0 };
  var pendingSpace = null;
  var push = function () {
    lines.push(line);
    line = { items: [], width: 0 };
    pendingSpace = null;
  };
  var place = function (runs, width) {
    if (pendingSpace && line.items.length) {
      line.items.push.apply(line.items, pendingSpace.runs);
      line.width += pendingSpace.width;
    }
    pendingSpace = null;
    line.items.push.apply(line.items, runs);
    line.width += width;
  };
  var toks = tokens(inlines);
  for (var t = 0; t < toks.length; t++) {
    var tok = toks[t];
    if (tok.br) { push(); continue; }
    var st = Object.assign({}, tok.st, o.bold ? { b: true } : {});
    var sz = st.code && !o.mono ? size * 0.92 : size;
    if (tok.space) {
      var sr = runsOf(doc, " ", st, sz);
      pendingSpace = { runs: sr, width: sr.reduce(function (a, r) { return a + r.width; }, 0) };
      continue;
    }
    var runs = runsOf(doc, tok.word, st, sz);
    var width = runs.reduce(function (a, r) { return a + r.width; }, 0);
    var spaceW = pendingSpace && line.items.length ? pendingSpace.width : 0;
    if (line.width + spaceW + width <= maxW || (!line.items.length && width <= maxW)) {
      place(runs, width);
      continue;
    }
    if (line.items.length && width <= maxW) {
      push();
      place(runs, width);
      continue;
    }
    if (line.items.length && line.width + spaceW >= maxW * 0.75) push();
    for (var r = 0; r < runs.length; r++) {
      var run = runs[r];
      var piece = { face: run.face, size: run.size, glyphs: [], width: 0, st: run.st };
      for (var g = 0; g < run.glyphs.length; g++) {
        var gl = run.glyphs[g];
        var lead = pendingSpace && line.items.length ? pendingSpace.width : 0;
        if (line.width + lead + piece.width + gl.w > maxW && (line.items.length || piece.glyphs.length)) {
          if (piece.glyphs.length) place([piece], piece.width);
          push();
          piece = { face: run.face, size: run.size, glyphs: [], width: 0, st: run.st };
        }
        piece.glyphs.push(gl);
        piece.width += gl.w;
      }
      if (piece.glyphs.length) place([piece], piece.width);
    }
  }
  if (line.items.length || !lines.length) push();
  return lines.map(function (ln) {
    var top = 0;
    ln.items.forEach(function (it) { if (it.size > top) top = it.size; });
    ln.size = top || size;
    ln.height = ln.size * (o.line || LINE);
    return ln;
  });
}

function drawLine(doc, ln, x, align, width, color) {
  var dx = align === "right" ? width - ln.width : align === "center" ? (width - ln.width) / 2 : 0;
  var face = faces().sans;
  var asc = face.ascent / face.unitsPerEm;
  var desc = -face.descent / face.unitsPerEm;
  var base = doc.y + (ln.height - ln.size * (asc + desc)) / 2 + ln.size * asc;
  var cx = x + Math.max(0, dx);
  ln.items.forEach(function (it) {
    var gids = it.glyphs.map(function (g) { markUsed(doc, it.face, g.gid, g.cp); return g.gid; });
    var isSpace = it.glyphs.every(function (g) { return g.cp === 0x20; });
    var col = it.st.href ? LINK : (color || TEXT);
    if (!isSpace) {
      doc.page.ops.push({ t: "text", face: it.face.key, size: it.size, x: cx, y: base, gids: gids, italic: !!it.st.i, color: col });
      if (it.st.href) {
        doc.page.ops.push({ t: "line", x1: cx, y1: base + 1.4, x2: cx + it.width, y2: base + 1.4, w: 0.5, color: LINK });
        doc.page.links.push({ x1: cx, y1: base - it.size * 0.85, x2: cx + it.width, y2: base + it.size * 0.25, href: it.st.href });
      }
      if (it.st.s) doc.page.ops.push({ t: "line", x1: cx, y1: base - it.size * 0.3, x2: cx + it.width, y2: base - it.size * 0.3, w: 0.6, color: col });
    } else if (it.st.href && doc.page.links.length) {
      var lastLink = doc.page.links[doc.page.links.length - 1];
      if (lastLink.href === it.st.href && Math.abs(lastLink.x2 - cx) < 0.5) lastLink.x2 = cx + it.width;
    }
    cx += it.width;
  });
  doc.y += ln.height;
}

function flowText(doc, inlines, o) {
  var lines = layoutLines(doc, inlines, o);
  for (var i = 0; i < lines.length; i++) {
    if (!ensure(doc, lines[i].height)) return;
    if (o.bar) doc.page.ops.push({ t: "rect", x: o.bar.x, y: doc.y, w: 2.5, h: lines[i].height, fill: RULE });
    drawLine(doc, lines[i], o.x, o.align, o.width, o.color);
  }
}

function gap(doc, h) {
  if (doc.page && doc.y > MARGIN.top + 0.01) doc.y += h;
}

function renderCode(doc, text, x, width) {
  var pad = 7;
  var inner = width - pad * 2;
  var rows = String(text).replace(/\t/g, "    ").split("\n");
  var lines = [];
  rows.forEach(function (row) {
    var lead = /^ */.exec(row)[0].length;
    var kept = "\u00a0".repeat(lead) + row.slice(lead);
    var ls = layoutLines(doc, [{ text: kept || "\u00a0", code: true }], { size: CODE_SIZE, width: inner, mono: true, line: 1.35 });
    lines.push.apply(lines, ls);
  });
  var i = 0;
  while (i < lines.length && !doc.full) {
    if (!ensure(doc, lines[i].height + pad * 2)) return;
    var startY = doc.y;
    var page = doc.page;
    var bgIndex = page.ops.length;
    page.ops.push(null);
    doc.y += pad;
    while (i < lines.length && doc.y + lines[i].height + pad <= bottom(doc) + 0.01) {
      drawLine(doc, lines[i], x + pad, "left", inner, TEXT);
      i++;
    }
    doc.y += pad;
    page.ops[bgIndex] = { t: "rect", x: x, y: startY, w: width, h: doc.y - startY, fill: CODE_BG };
    if (i < lines.length && !addPage(doc)) return;
  }
}

function cellWidthNatural(doc, inlines, size) {
  var lines = layoutLines(doc, inlines, { size: size, width: 1e9 });
  var w = 0;
  lines.forEach(function (l) { if (l.width > w) w = l.width; });
  var longest = 0;
  inlineText(inlines).split(/\s+/).forEach(function (word) {
    var ww = runsOf(doc, word, {}, size).reduce(function (a, r) { return a + r.width; }, 0);
    if (ww > longest) longest = ww;
  });
  return { natural: w, min: Math.min(longest, 140) };
}

function renderTable(doc, block, x, width) {
  var size = 9.5;
  var pad = 5;
  var cols = block.head.length;
  if (!cols) return;
  var nat = new Array(cols).fill(0);
  var min = new Array(cols).fill(0);
  [block.head].concat(block.rows).forEach(function (row, ri) {
    row.forEach(function (cell, c) {
      var m = cellWidthNatural(doc, ri === 0 ? cell.map(function (s) { return Object.assign({}, s, { b: true }); }) : cell, size);
      nat[c] = Math.max(nat[c], m.natural + pad * 2);
      min[c] = Math.max(min[c], m.min + pad * 2, 24);
    });
  });
  var totalNat = nat.reduce(function (a, b) { return a + b; }, 0);
  var widths;
  if (totalNat <= width) {
    widths = nat.slice();
  } else {
    var totalMin = min.reduce(function (a, b) { return a + b; }, 0);
    if (totalMin >= width) {
      widths = min.map(function (m) { return m / totalMin * width; });
    } else {
      var spare = width - totalMin;
      var extra = nat.map(function (n, i) { return Math.max(0, n - min[i]); });
      var extraSum = extra.reduce(function (a, b) { return a + b; }, 0) || 1;
      widths = min.map(function (m, i) { return m + extra[i] / extraSum * spare; });
    }
  }
  var tableW = widths.reduce(function (a, b) { return a + b; }, 0);
  var layoutRow = function (row, head) {
    var cells = row.map(function (cell, c) {
      var inl = head ? cell.map(function (s) { return Object.assign({}, s, { b: true }); }) : cell;
      return layoutLines(doc, inl, { size: size, width: Math.max(4, widths[c] - pad * 2), line: 1.3 });
    });
    var h = 0;
    cells.forEach(function (ls) {
      var ch = ls.reduce(function (a, l) { return a + l.height; }, 0);
      if (ch > h) h = ch;
    });
    return { cells: cells, height: h + pad * 2 };
  };
  var drawRow = function (laid, head) {
    var maxH = bottom(doc) - MARGIN.top;
    if (laid.height > maxH) {
      laid.cells = laid.cells.map(function (ls) {
        var keep = [];
        var used = pad * 2;
        for (var k = 0; k < ls.length && used + ls[k].height <= maxH; k++) { keep.push(ls[k]); used += ls[k].height; }
        return keep;
      });
      laid.height = maxH;
      doc.truncated = true;
    }
    var top = doc.y;
    if (head) doc.page.ops.push({ t: "rect", x: x, y: top, w: tableW, h: laid.height, fill: HEAD_BG });
    var cx = x;
    laid.cells.forEach(function (ls, c) {
      doc.y = top + pad;
      ls.forEach(function (l) { drawLine(doc, l, cx + pad, block.align[c], widths[c] - pad * 2, TEXT); });
      cx += widths[c];
    });
    doc.y = top + laid.height;
    doc.page.ops.push({ t: "line", x1: x, y1: doc.y, x2: x + tableW, y2: doc.y, w: 0.5, color: RULE });
    var vx = x;
    for (var c2 = 0; c2 <= cols; c2++) {
      doc.page.ops.push({ t: "line", x1: vx, y1: top, x2: vx, y2: doc.y, w: 0.5, color: RULE });
      if (c2 < cols) vx += widths[c2];
    }
    if (head) doc.page.ops.push({ t: "line", x1: x, y1: top, x2: x + tableW, y2: top, w: 0.5, color: RULE });
  };
  var head = layoutRow(block.head, true);
  if (!ensure(doc, head.height + 20)) return;
  drawRow(head, true);
  for (var r = 0; r < block.rows.length && !doc.full; r++) {
    var laid = layoutRow(block.rows[r], false);
    if (doc.y + laid.height > bottom(doc) + 0.01) {
      if (!addPage(doc)) return;
      drawRow(layoutRow(block.head, true), true);
    }
    drawRow(laid, false);
  }
}

function renderBlocks(doc, blocks, x, width, ctx) {
  for (var b = 0; b < blocks.length && !doc.full; b++) {
    var block = blocks[b];
    var tight = ctx && ctx.tight;
    var color = ctx && ctx.color;
    if (block.type === "heading") {
      var hs = HEADING_SIZES[block.level] || BODY_SIZE;
      gap(doc, hs * 0.9);
      if (!ensure(doc, hs * LINE + BODY_SIZE * LINE * 2)) return;
      flowText(doc, block.inlines, { x: x, width: width, size: hs, bold: true, line: 1.25, color: color });
      if (block.level <= 2) {
        doc.page.ops.push({ t: "line", x1: x, y1: doc.y + 2, x2: x + width, y2: doc.y + 2, w: block.level === 1 ? 0.9 : 0.5, color: RULE });
        doc.y += 4;
      }
      gap(doc, hs * 0.35);
    } else if (block.type === "para") {
      flowText(doc, block.inlines, { x: x, width: width, size: BODY_SIZE, color: color, bar: ctx && ctx.bar });
      if (!tight) gap(doc, BODY_SIZE * 0.6);
    } else if (block.type === "list") {
      var n = block.start;
      for (var it = 0; it < block.items.length && !doc.full; it++) {
        var item = block.items[it];
        var marker = item.task !== null ? (item.task ? "\u2611" : "\u2610") : block.ordered ? (n++) + "." : ((ctx && ctx.depth) % 2 ? "\u25e6" : "\u2022");
        var mw = block.ordered ? 20 : 14;
        if (!ensure(doc, BODY_SIZE * LINE)) return;
        var markLines = layoutLines(doc, [{ text: marker }], { size: BODY_SIZE, width: mw });
        var keepY = doc.y;
        drawLine(doc, markLines[0], x + 2, block.ordered ? "right" : "left", mw - 6, color);
        doc.y = keepY;
        renderBlocks(doc, item.blocks, x + mw + 4, width - mw - 4, Object.assign({}, ctx, { tight: true, depth: ((ctx && ctx.depth) || 0) + 1 }));
        gap(doc, 2);
      }
      if (!tight) gap(doc, BODY_SIZE * 0.5);
    } else if (block.type === "code") {
      gap(doc, 2);
      renderCode(doc, block.text, x, width);
      gap(doc, BODY_SIZE * 0.7);
    } else if (block.type === "quote") {
      renderBlocks(doc, block.blocks, x + 14, width - 14, Object.assign({}, ctx, { color: MUTED, bar: { x: x + 2 } }));
      gap(doc, BODY_SIZE * 0.3);
    } else if (block.type === "table") {
      gap(doc, 2);
      renderTable(doc, block, x, width);
      gap(doc, BODY_SIZE * 0.8);
    } else if (block.type === "hr") {
      if (!ensure(doc, 14)) return;
      doc.y += 6;
      doc.page.ops.push({ t: "line", x1: x, y1: doc.y, x2: x + width, y2: doc.y, w: 0.7, color: RULE });
      doc.y += 8;
    } else if (block.type === "pagebreak") {
      if (doc.page && doc.y > MARGIN.top + 0.01) addPage(doc);
    }
  }
}

function num(v) {
  var r = Math.round(v * 100) / 100;
  return String(r === 0 ? 0 : r);
}

function hex4(n) {
  return ("0000" + n.toString(16)).slice(-4).toUpperCase();
}

function pdfString(s) {
  var out = "FEFF";
  for (var i = 0; i < s.length; i++) out += hex4(s.charCodeAt(i));
  return "<" + out + ">";
}

function asciiLiteral(s) {
  return "(" + String(s).replace(/[\\()]/g, function (c) { return "\\" + c; }) + ")";
}

function utf16Hex(cp) {
  if (cp < 0x10000) return hex4(cp);
  var v = cp - 0x10000;
  return hex4(0xd800 + (v >> 10)) + hex4(0xdc00 + (v & 0x3ff));
}

function color(c, stroke) {
  return num(c[0]) + " " + num(c[1]) + " " + num(c[2]) + (stroke ? " RG" : " rg");
}

function contentStream(doc, page, fontIds, remaps) {
  var out = [];
  var H = doc.height;
  page.ops.forEach(function (op) {
    if (!op) return;
    if (op.t === "rect") {
      out.push("q " + color(op.fill) + " " + num(op.x) + " " + num(H - op.y - op.h) + " " + num(op.w) + " " + num(op.h) + " re f Q");
    } else if (op.t === "line") {
      out.push("q " + color(op.color, true) + " " + num(op.w) + " w " + num(op.x1) + " " + num(H - op.y1) + " m " + num(op.x2) + " " + num(H - op.y2) + " l S Q");
    } else if (op.t === "text") {
      var map = remaps[op.face];
      var hex = op.gids.map(function (g) { return hex4(map.get(g) || 0); }).join("");
      out.push("BT " + color(op.color) + " /" + fontIds[op.face] + " " + num(op.size) + " Tf 1 0 " + (op.italic ? num(SKEW) : "0") + " 1 " + num(op.x) + " " + num(H - op.y) + " Tm <" + hex + "> Tj ET");
    }
  });
  return out.join("\n");
}

function toUnicode(cps, remap) {
  var pairs = [];
  cps.forEach(function (cp, gid) { if (remap.has(gid)) pairs.push([remap.get(gid), cp]); });
  pairs.sort(function (a, b) { return a[0] - b[0]; });
  var lines = ["/CIDInit /ProcSet findresource begin", "12 dict begin", "begincmap",
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def",
    "/CMapName /Adobe-Identity-UCS def", "/CMapType 2 def",
    "1 begincodespacerange", "<0000> <FFFF>", "endcodespacerange"];
  for (var i = 0; i < pairs.length; i += 100) {
    var chunk = pairs.slice(i, i + 100);
    lines.push(chunk.length + " beginbfchar");
    chunk.forEach(function (p) { lines.push("<" + hex4(p[0]) + "> <" + utf16Hex(p[1]) + ">"); });
    lines.push("endbfchar");
  }
  lines.push("endcmap", "CMapName currentdict /CMap defineresource pop", "end", "end");
  return lines.join("\n");
}

function pdfDate(d) {
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return "D:" + d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z";
}

async function writePdf(doc, title) {
  var objects = [];
  var reserve = function () { objects.push(null); return objects.length; };
  var set = function (id, body) { objects[id - 1] = body; };
  var catalogId = reserve();
  var pagesId = reserve();
  var infoId = reserve();
  var fontIds = {};
  var remaps = {};
  var fontRefs = [];
  var keys = Object.keys(doc.used).sort();
  for (var k = 0; k < keys.length; k++) {
    var key = keys[k];
    var font = faces()[key];
    var used = doc.used[key];
    var sub = ttfSubset(font, used.gids, null);
    remaps[key] = sub.remap;
    fontIds[key] = "F" + (k + 1);
    var scale = 1000 / font.unitsPerEm;
    var widths = new Array(sub.remap.size).fill(0);
    sub.remap.forEach(function (ng, og) { widths[ng] = Math.round(font.advances[og] * scale); });
    var fname = "NYMBOT+" + font.name;
    var fileId = reserve();
    var packed = await deflateBytes(sub.bytes, false);
    set(fileId, { dict: "<< /Length " + packed.length + " /Length1 " + sub.bytes.length + " /Filter /FlateDecode >>", data: packed });
    var descId = reserve();
    set(descId, "<< /Type /FontDescriptor /FontName /" + fname + " /Flags " + (key === "mono" ? 33 : 32) +
      " /FontBBox [" + font.bbox.map(function (v) { return Math.round(v * scale); }).join(" ") + "] /ItalicAngle 0 /Ascent " +
      Math.round(font.ascent * scale) + " /Descent " + Math.round(font.descent * scale) + " /CapHeight " + Math.round(font.capHeight * scale) +
      " /StemV " + (key === "bold" ? 120 : 80) + " /FontFile2 " + fileId + " 0 R >>");
    var cidId = reserve();
    set(cidId, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /" + fname +
      " /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor " + descId +
      " 0 R /DW 1000 /W [0 [" + widths.join(" ") + "]] /CIDToGIDMap /Identity >>");
    var cmapId = reserve();
    var cmapBytes = await deflateBytes(utf8(toUnicode(used.cps, sub.remap)), false);
    set(cmapId, { dict: "<< /Length " + cmapBytes.length + " /Filter /FlateDecode >>", data: cmapBytes });
    var fontId = reserve();
    set(fontId, "<< /Type /Font /Subtype /Type0 /BaseFont /" + fname + " /Encoding /Identity-H /DescendantFonts [" + cidId + " 0 R] /ToUnicode " + cmapId + " 0 R >>");
    fontRefs.push("/" + fontIds[key] + " " + fontId + " 0 R");
  }
  var kids = [];
  var total = doc.pages.length;
  for (var q = 0; q < total; q++) {
    var pg = doc.pages[q];
    var stream = await deflateBytes(utf8(contentStream(doc, pg, fontIds, remaps)), false);
    var contentId = reserve();
    set(contentId, { dict: "<< /Length " + stream.length + " /Filter /FlateDecode >>", data: stream });
    var annots = pg.links.map(function (l) {
      return "<< /Type /Annot /Subtype /Link /Border [0 0 0] /Rect [" + [l.x1, doc.height - l.y2, l.x2, doc.height - l.y1].map(num).join(" ") +
        "] /A << /S /URI /URI " + asciiLiteral(l.href.replace(/[^\x21-\x7e]/g, function (c) { return encodeURIComponent(c); })) + " >> >>";
    });
    var pageId = reserve();
    set(pageId, "<< /Type /Page /Parent " + pagesId + " 0 R /MediaBox [0 0 " + num(doc.width) + " " + num(doc.height) + "] /Resources << /Font << " +
      fontRefs.join(" ") + " >> >> /Contents " + contentId + " 0 R" + (annots.length ? " /Annots [" + annots.join(" ") + "]" : "") + " >>");
    kids.push(pageId + " 0 R");
  }
  set(pagesId, "<< /Type /Pages /Kids [" + kids.join(" ") + "] /Count " + kids.length + " >>");
  set(catalogId, "<< /Type /Catalog /Pages " + pagesId + " 0 R" + (title ? " /ViewerPreferences << /DisplayDocTitle true >>" : "") + " >>");
  set(infoId, "<< /Producer (Nymbot) /Creator (Nymbot) /CreationDate (" + pdfDate(new Date()) + ")" + (title ? " /Title " + pdfString(title) : "") + " >>");
  var parts = [utf8("%PDF-1.7\n"), new Uint8Array([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a])];
  var offset = parts[0].length + parts[1].length;
  var offsets = [];
  objects.forEach(function (obj, i) {
    offsets.push(offset);
    var chunk;
    if (typeof obj === "string") {
      chunk = utf8((i + 1) + " 0 obj\n" + obj + "\nendobj\n");
    } else {
      chunk = concatBytes([utf8((i + 1) + " 0 obj\n" + obj.dict + "\nstream\n"), obj.data, utf8("\nendstream\nendobj\n")]);
    }
    parts.push(chunk);
    offset += chunk.length;
  });
  var xref = ["xref", "0 " + (objects.length + 1), "0000000000 65535 f "];
  offsets.forEach(function (o) { xref.push(("0000000000" + o).slice(-10) + " 00000 n "); });
  parts.push(utf8(xref.join("\n") + "\ntrailer\n<< /Size " + (objects.length + 1) + " /Root " + catalogId + " 0 R /Info " + infoId + " 0 R >>\nstartxref\n" + offset + "\n%%EOF\n"));
  return concatBytes(parts);
}

export async function renderPdf(markdown, opts) {
  var o = opts || {};
  var doc = newDoc(o.paper);
  addPage(doc);
  var blocks = Array.isArray(markdown) ? markdown : parseMarkdown(markdown);
  renderBlocks(doc, blocks, MARGIN.left, doc.width - MARGIN.left - MARGIN.right, { depth: 0 });
  var total = doc.pages.length;
  for (var p = 0; p < total; p++) {
    doc.page = doc.pages[p];
    doc.y = doc.height - MARGIN.bottom + 26;
    drawLine(doc, layoutLines(doc, [{ text: (p + 1) + " / " + total }], { size: 8.5, width: 200 })[0], doc.width / 2 - 100, "center", 200, MUTED);
  }
  var bytes = await writePdf(doc, o.title ? String(o.title).slice(0, 200) : "");
  return {
    bytes: bytes,
    pages: doc.pages.length,
    missing: doc.missing,
    missingSample: doc.missingSample,
    truncated: doc.truncated
  };
}
