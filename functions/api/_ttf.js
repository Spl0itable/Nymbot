function u16(b, o) { return (b[o] << 8) | b[o + 1]; }
function i16(b, o) { var v = u16(b, o); return v & 0x8000 ? v - 0x10000 : v; }
function u32(b, o) { return ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3]; }

function put16(b, o, v) { b[o] = (v >> 8) & 255; b[o + 1] = v & 255; }
function put32(b, o, v) { b[o] = (v >>> 24) & 255; b[o + 1] = (v >>> 16) & 255; b[o + 2] = (v >>> 8) & 255; b[o + 3] = v & 255; }

var COMPOSITE_ARGS_WORDS = 0x0001;
var COMPOSITE_HAVE_SCALE = 0x0008;
var COMPOSITE_MORE = 0x0020;
var COMPOSITE_XY_SCALE = 0x0040;
var COMPOSITE_TWO_BY_TWO = 0x0080;
var COMPOSITE_INSTRUCTIONS = 0x0100;

function readCmap(b, base) {
  var map = new Map();
  var count = u16(b, base + 2);
  var best = -1;
  var bestScore = -1;
  for (var i = 0; i < count; i++) {
    var rec = base + 4 + i * 8;
    var platform = u16(b, rec);
    var encoding = u16(b, rec + 2);
    var off = base + u32(b, rec + 4);
    var format = u16(b, off);
    var score = -1;
    if (platform === 3 && encoding === 10 && format === 12) score = 4;
    else if (platform === 0 && format === 12) score = 3;
    else if (platform === 3 && encoding === 1 && format === 4) score = 2;
    else if (platform === 0 && format === 4) score = 1;
    if (score > bestScore) { bestScore = score; best = off; }
  }
  if (best < 0) return map;
  var fmt = u16(b, best);
  if (fmt === 4) {
    var segX2 = u16(b, best + 6);
    var ends = best + 14;
    var starts = ends + segX2 + 2;
    var deltas = starts + segX2;
    var ranges = deltas + segX2;
    for (var s = 0; s < segX2 / 2; s++) {
      var end = u16(b, ends + s * 2);
      var start = u16(b, starts + s * 2);
      var delta = i16(b, deltas + s * 2);
      var rangeOff = u16(b, ranges + s * 2);
      for (var c = start; c <= end && c !== 0xffff; c++) {
        var g;
        if (rangeOff === 0) {
          g = (c + delta) & 0xffff;
        } else {
          var at = ranges + s * 2 + rangeOff + (c - start) * 2;
          g = u16(b, at);
          if (g !== 0) g = (g + delta) & 0xffff;
        }
        if (g) map.set(c, g);
      }
    }
  } else if (fmt === 12) {
    var groups = u32(b, best + 12);
    for (var k = 0; k < groups; k++) {
      var gr = best + 16 + k * 12;
      var sc = u32(b, gr);
      var ec = u32(b, gr + 4);
      var sg = u32(b, gr + 8);
      for (var cc = sc; cc <= ec && cc - sc < 0x10000; cc++) map.set(cc, sg + (cc - sc));
    }
  }
  return map;
}

export function ttfParse(input) {
  var b = input instanceof Uint8Array ? input : new Uint8Array(input);
  var numTables = u16(b, 4);
  var tables = {};
  for (var i = 0; i < numTables; i++) {
    var rec = 12 + i * 16;
    var tag = String.fromCharCode(b[rec], b[rec + 1], b[rec + 2], b[rec + 3]);
    tables[tag] = { offset: u32(b, rec + 8), length: u32(b, rec + 12) };
  }
  ["head", "hhea", "maxp", "hmtx", "loca", "glyf", "cmap"].forEach(function (t) {
    if (!tables[t]) throw new Error("font is missing the " + t + " table");
  });
  var head = tables.head.offset;
  var unitsPerEm = u16(b, head + 18);
  var bbox = [i16(b, head + 36), i16(b, head + 38), i16(b, head + 40), i16(b, head + 42)];
  var longLoca = i16(b, head + 50) === 1;
  var numGlyphs = u16(b, tables.maxp.offset + 4);
  var hhea = tables.hhea.offset;
  var ascent = i16(b, hhea + 4);
  var descent = i16(b, hhea + 6);
  var numberOfHMetrics = u16(b, hhea + 34);
  var advances = new Uint16Array(numGlyphs);
  var lsbs = new Int16Array(numGlyphs);
  var hm = tables.hmtx.offset;
  var last = 0;
  for (var g = 0; g < numGlyphs; g++) {
    if (g < numberOfHMetrics) {
      last = u16(b, hm + g * 4);
      advances[g] = last;
      lsbs[g] = i16(b, hm + g * 4 + 2);
    } else {
      advances[g] = last;
      lsbs[g] = i16(b, hm + numberOfHMetrics * 4 + (g - numberOfHMetrics) * 2);
    }
  }
  var loca = new Uint32Array(numGlyphs + 1);
  for (var l = 0; l <= numGlyphs; l++) {
    loca[l] = longLoca ? u32(b, tables.loca.offset + l * 4) : u16(b, tables.loca.offset + l * 2) * 2;
  }
  var capHeight = Math.round(ascent * 0.72);
  var italicAngle = 0;
  if (tables["OS/2"]) {
    var os2 = tables["OS/2"].offset;
    if (u16(b, os2) >= 2 && tables["OS/2"].length >= 90) capHeight = i16(b, os2 + 88);
  }
  if (tables.post) {
    italicAngle = (i16(b, tables.post.offset + 4) + u16(b, tables.post.offset + 6) / 65536);
  }
  var cmap = readCmap(b, tables.cmap.offset);
  return {
    bytes: b,
    tables: tables,
    unitsPerEm: unitsPerEm,
    bbox: bbox,
    numGlyphs: numGlyphs,
    ascent: ascent,
    descent: descent,
    capHeight: capHeight,
    italicAngle: italicAngle,
    advances: advances,
    lsbs: lsbs,
    loca: loca,
    cmap: cmap,
    glyph: function (gid) {
      if (gid < 0 || gid >= numGlyphs) return new Uint8Array(0);
      var start = tables.glyf.offset + loca[gid];
      var end = tables.glyf.offset + loca[gid + 1];
      return end > start ? b.subarray(start, end) : new Uint8Array(0);
    }
  };
}

function compositeWalk(data, visit) {
  var p = 10;
  for (;;) {
    var flags = u16(data, p);
    visit(p, flags);
    p += 4;
    p += flags & COMPOSITE_ARGS_WORDS ? 4 : 2;
    if (flags & COMPOSITE_HAVE_SCALE) p += 2;
    else if (flags & COMPOSITE_XY_SCALE) p += 4;
    else if (flags & COMPOSITE_TWO_BY_TWO) p += 8;
    if (!(flags & COMPOSITE_MORE)) return p;
  }
}

function compositeParts(data) {
  var parts = [];
  if (data.length < 10 || i16(data, 0) >= 0) return parts;
  compositeWalk(data, function (at) { parts.push(u16(data, at + 2)); });
  return parts;
}

function stripSimple(data) {
  var contours = i16(data, 0);
  var lenAt = 10 + contours * 2;
  var insLen = u16(data, lenAt);
  if (!insLen) return data;
  var out = new Uint8Array(data.length - insLen);
  out.set(data.subarray(0, lenAt), 0);
  put16(out, lenAt, 0);
  out.set(data.subarray(lenAt + 2 + insLen), lenAt + 2);
  return out;
}

function rewriteComposite(data, remap) {
  var out = new Uint8Array(data);
  var end = compositeWalk(out, function (at, flags) {
    put16(out, at, flags & ~COMPOSITE_INSTRUCTIONS);
    put16(out, at + 2, remap.get(u16(out, at + 2)) || 0);
  });
  return out.subarray(0, end);
}

function checksum(b) {
  var sum = 0;
  var padded = b.length % 4 ? b.length + 4 - (b.length % 4) : b.length;
  for (var i = 0; i < padded; i += 4) {
    var v = ((b[i] || 0) << 24 >>> 0) + ((b[i + 1] || 0) << 16) + ((b[i + 2] || 0) << 8) + (b[i + 3] || 0);
    sum = (sum + v) >>> 0;
  }
  return sum;
}

function buildCmap4(pairs) {
  var list = pairs.filter(function (p) { return p[0] <= 0xfffe; }).sort(function (a, b) { return a[0] - b[0]; });
  var segs = [];
  for (var i = 0; i < list.length; i++) {
    var code = list[i][0];
    var gid = list[i][1];
    var cur = segs[segs.length - 1];
    if (cur && code === cur.end + 1 && gid === cur.lastGid + 1) {
      cur.end = code;
      cur.lastGid = gid;
    } else {
      segs.push({ start: code, end: code, delta: (gid - code) & 0xffff, lastGid: gid });
    }
  }
  segs.push({ start: 0xffff, end: 0xffff, delta: 1, lastGid: 0 });
  var n = segs.length;
  var len = 16 + n * 8;
  var t = new Uint8Array(len);
  put16(t, 0, 4);
  put16(t, 2, len);
  put16(t, 4, 0);
  put16(t, 6, n * 2);
  var pow = 1;
  var log = 0;
  while (pow * 2 <= n) { pow *= 2; log++; }
  put16(t, 8, pow * 2);
  put16(t, 10, log);
  put16(t, 12, n * 2 - pow * 2);
  for (var s = 0; s < n; s++) {
    put16(t, 14 + s * 2, segs[s].end);
    put16(t, 16 + n * 2 + s * 2, segs[s].start);
    put16(t, 16 + n * 4 + s * 2, segs[s].delta);
    put16(t, 16 + n * 6 + s * 2, 0);
  }
  var out = new Uint8Array(12 + len);
  put16(out, 0, 0);
  put16(out, 2, 1);
  put16(out, 4, 3);
  put16(out, 6, 1);
  put32(out, 8, 12);
  out.set(t, 12);
  return out;
}

function assemble(tables) {
  var tags = Object.keys(tables).sort();
  var n = tags.length;
  var offset = 12 + n * 16;
  var total = offset;
  tags.forEach(function (tag) { total += Math.ceil(tables[tag].length / 4) * 4; });
  var out = new Uint8Array(total);
  put32(out, 0, 0x00010000);
  put16(out, 4, n);
  var pow = 1;
  var log = 0;
  while (pow * 2 <= n) { pow *= 2; log++; }
  put16(out, 6, pow * 16);
  put16(out, 8, log);
  put16(out, 10, n * 16 - pow * 16);
  var headAt = -1;
  tags.forEach(function (tag, i) {
    var data = tables[tag];
    var rec = 12 + i * 16;
    for (var c = 0; c < 4; c++) out[rec + c] = tag.charCodeAt(c);
    put32(out, rec + 4, checksum(data));
    put32(out, rec + 8, offset);
    put32(out, rec + 12, data.length);
    out.set(data, offset);
    if (tag === "head") headAt = offset;
    offset += Math.ceil(data.length / 4) * 4;
  });
  if (headAt >= 0) put32(out, headAt + 8, (0xB1B0AFBA - checksum(out)) >>> 0);
  return out;
}

export function ttfSubset(font, wanted, codes) {
  var keep = new Set([0]);
  var stack = [];
  wanted.forEach(function (g) {
    if (g > 0 && g < font.numGlyphs && !keep.has(g)) { keep.add(g); stack.push(g); }
  });
  while (stack.length) {
    var parts = compositeParts(font.glyph(stack.pop()));
    for (var p = 0; p < parts.length; p++) {
      var cg = parts[p];
      if (cg < font.numGlyphs && !keep.has(cg)) { keep.add(cg); stack.push(cg); }
    }
  }
  var order = Array.from(keep).sort(function (a, b) { return a - b; });
  var remap = new Map();
  order.forEach(function (g, i) { remap.set(g, i); });
  var glyphs = order.map(function (g) {
    var data = font.glyph(g);
    if (!data.length) return data;
    return i16(data, 0) >= 0 ? stripSimple(data) : rewriteComposite(data, remap);
  });
  var glyfLen = 0;
  glyphs.forEach(function (d) { glyfLen += Math.ceil(d.length / 4) * 4; });
  var glyf = new Uint8Array(glyfLen);
  var loca = new Uint8Array((order.length + 1) * 4);
  var at = 0;
  glyphs.forEach(function (d, i) {
    put32(loca, i * 4, at);
    glyf.set(d, at);
    at += Math.ceil(d.length / 4) * 4;
  });
  put32(loca, order.length * 4, at);
  var hmtx = new Uint8Array(order.length * 4);
  order.forEach(function (g, i) {
    put16(hmtx, i * 4, font.advances[g]);
    put16(hmtx, i * 4 + 2, font.lsbs[g] & 0xffff);
  });
  var b = font.bytes;
  var t = font.tables;
  var head = new Uint8Array(b.subarray(t.head.offset, t.head.offset + 54));
  put32(head, 8, 0);
  put16(head, 50, 1);
  var hhea = new Uint8Array(b.subarray(t.hhea.offset, t.hhea.offset + 36));
  put16(hhea, 34, order.length);
  var maxp = new Uint8Array(b.subarray(t.maxp.offset, t.maxp.offset + Math.min(32, t.maxp.length)));
  put16(maxp, 4, order.length);
  if (maxp.length >= 32) {
    put16(maxp, 18, 1);
    put16(maxp, 22, 0);
    put16(maxp, 24, 0);
    put16(maxp, 26, 0);
  }
  var post = new Uint8Array(32);
  if (t.post) post.set(b.subarray(t.post.offset, t.post.offset + 32));
  put32(post, 0, 0x00030000);
  var pairs = [];
  (codes || new Map()).forEach(function (g, code) {
    if (remap.has(g)) pairs.push([code, remap.get(g)]);
  });
  var tables = { head: head, hhea: hhea, maxp: maxp, hmtx: hmtx, loca: loca, glyf: glyf, post: post, cmap: buildCmap4(pairs) };
  if (t["OS/2"]) tables["OS/2"] = new Uint8Array(b.subarray(t["OS/2"].offset, t["OS/2"].offset + t["OS/2"].length));
  return { bytes: assemble(tables), remap: remap };
}

export function ttfCodesFor(font, ranges) {
  var codes = new Map();
  font.cmap.forEach(function (g, code) {
    for (var i = 0; i < ranges.length; i++) {
      if (code >= ranges[i][0] && code <= ranges[i][1]) { codes.set(code, g); return; }
    }
  });
  return codes;
}
