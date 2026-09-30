export const AUDIO_FLOOR_BPS = 8000;
export const AUDIO_CEIL_BPS = 1536000;
export const AUDIO_PCM_CEIL_BPS = 4608000;

function u16be(b, i) { return (b[i] << 8) | b[i + 1]; }
function u32be(b, i) { return ((b[i] << 24) >>> 0) + ((b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]); }
function u32le(b, i) { return ((b[i + 3] << 24) >>> 0) + ((b[i + 2] << 16) | (b[i + 1] << 8) | b[i]); }
function u64be(b, i) { return u32be(b, i) * 4294967296 + u32be(b, i + 4); }
function u64le(b, i) { return u32le(b, i + 4) * 4294967296 + u32le(b, i); }

function opusPacketMs(p, at, end) {
  if (at >= end) return 0;
  var toc = p[at];
  var config = toc >> 3;
  var frame;
  if (config < 12) frame = [10, 20, 40, 60][config & 3];
  else if (config < 16) frame = [10, 20][config & 1];
  else frame = [2.5, 5, 10, 20][config & 3];
  var code = toc & 3;
  var count = code === 0 ? 1 : (code === 3 ? (at + 1 < end ? p[at + 1] & 63 : 0) : 2);
  return frame * count;
}

function ebmlId(b, i) {
  var first = b[i];
  if (first === undefined) return null;
  var len = first & 0x80 ? 1 : first & 0x40 ? 2 : first & 0x20 ? 3 : first & 0x10 ? 4 : 0;
  if (!len || i + len > b.length) return null;
  var id = 0;
  for (var k = 0; k < len; k++) id = id * 256 + b[i + k];
  return { id: id, len: len };
}

function ebmlSize(b, i) {
  var first = b[i];
  if (first === undefined) return null;
  var len = 0;
  for (var bit = 0; bit < 8; bit++) {
    if (first & (0x80 >> bit)) { len = bit + 1; break; }
  }
  if (!len || i + len > b.length) return null;
  var v = first & (0xff >> len);
  var allOnes = v === (0xff >> len);
  for (var k = 1; k < len; k++) {
    v = v * 256 + b[i + k];
    if (b[i + k] !== 0xff) allOnes = false;
  }
  return { size: allOnes ? -1 : v, len: len };
}

function readUint(b, i, n) {
  var v = 0;
  for (var k = 0; k < n; k++) v = v * 256 + b[i + k];
  return v;
}

function readFloat(b, i, n) {
  var dv = new DataView(b.buffer, b.byteOffset + i, n);
  return n === 4 ? dv.getFloat32(0) : (n === 8 ? dv.getFloat64(0) : 0);
}

var WEBM_MASTERS = { 0x18538067: 1, 0x1549a966: 1, 0x1f43b675: 1, 0xa0: 1, 0x1654ae6b: 1, 0xae: 1 };

function webmSeconds(b) {
  var scale = 1000000;
  var declared = 0;
  var cluster = 0;
  var last = 0;
  var opus = false;
  var framesMs = 0;
  var blocks = 0;
  var i = 0;
  var steps = 0;
  while (i < b.length && steps++ < 2000000) {
    var id = ebmlId(b, i);
    if (!id) break;
    var sz = ebmlSize(b, i + id.len);
    if (!sz) break;
    var at = i + id.len + sz.len;
    if (WEBM_MASTERS[id.id]) { i = at; continue; }
    if (sz.size < 0) break;
    var end = Math.min(b.length, at + sz.size);
    if (id.id === 0x2ad7b1 && sz.size <= 8) scale = readUint(b, at, sz.size) || scale;
    else if (id.id === 0x4489 && (sz.size === 4 || sz.size === 8) && end - at === sz.size) declared = readFloat(b, at, sz.size);
    else if (id.id === 0xe7 && sz.size <= 8) {
      cluster = readUint(b, at, sz.size);
      if (cluster > last) last = cluster;
    }
    else if (id.id === 0x86) opus = String.fromCharCode.apply(null, Array.from(b.subarray(at, end))) === "A_OPUS";
    else if ((id.id === 0xa3 || id.id === 0xa1) && end - at >= 4) {
      var track = ebmlSize(b, at);
      if (track) {
        var h = at + track.len;
        if (h + 3 <= end) {
          var rel = (b[h] << 8) | b[h + 1];
          if (rel & 0x8000) rel -= 0x10000;
          var t = cluster + rel;
          if (t > last) last = t;
          var lacing = (b[h + 2] >> 1) & 3;
          blocks++;
          if (lacing === 0) framesMs += opusPacketMs(b, h + 3, end);
          else framesMs += 20 * (b[h + 3] + 1);
        }
      }
    }
    i = at + sz.size;
  }
  var tick = scale / 1e9;
  var byTime = Math.max(declared, last) * tick;
  var byFrames = opus && blocks ? framesMs / 1000 : 0;
  if (!byTime && !byFrames) return null;
  return Math.max(byTime, byFrames);
}

function mp4Walk(b, start, end, visit, depth) {
  var i = start;
  while (i + 8 <= end) {
    var size = u32be(b, i);
    var type = String.fromCharCode(b[i + 4], b[i + 5], b[i + 6], b[i + 7]);
    var head = 8;
    if (size === 1) {
      if (i + 16 > end) return;
      size = u64be(b, i + 8);
      head = 16;
    } else if (size === 0) size = end - i;
    if (size < head) return;
    var boxEnd = Math.min(end, i + size);
    if (depth < 8 && (type === "moov" || type === "trak" || type === "mdia" || type === "minf" || type === "stbl" || type === "moof" || type === "traf" || type === "mvex")) {
      mp4Walk(b, i + head, boxEnd, visit, depth + 1);
    } else {
      visit(type, i + head, boxEnd);
    }
    i = i + size;
  }
}

function mp4Seconds(b) {
  var mvhd = 0;
  var timescale = 0;
  var samples = 0;
  var sttsTicks = 0;
  var fragTicks = 0;
  var trexDefault = 0;
  mp4Walk(b, 0, b.length, function (type, at, end) {
    if (type === "mvhd" && end - at >= 20) {
      var v = b[at];
      if (v === 1 && end - at >= 32) {
        var ts1 = u32be(b, at + 20);
        if (ts1) mvhd = Math.max(mvhd, u64be(b, at + 24) / ts1);
      } else {
        var ts0 = u32be(b, at + 12);
        if (ts0) mvhd = Math.max(mvhd, u32be(b, at + 16) / ts0);
      }
    } else if (type === "mdhd" && end - at >= 20) {
      timescale = b[at] === 1 && end - at >= 32 ? u32be(b, at + 20) : u32be(b, at + 12);
    } else if (type === "stsz" && end - at >= 12) {
      samples += u32be(b, at + 8);
    } else if (type === "stts" && end - at >= 8) {
      var n = u32be(b, at + 4);
      for (var k = 0; k < n && at + 16 + k * 8 <= end; k++) sttsTicks += u32be(b, at + 8 + k * 8) * u32be(b, at + 12 + k * 8);
    } else if (type === "trex" && end - at >= 24) {
      trexDefault = u32be(b, at + 12);
    } else if (type === "trun" && end - at >= 8) {
      var flags = (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
      var count = u32be(b, at + 4);
      samples += count;
      var p = at + 8;
      if (flags & 1) p += 4;
      if (flags & 4) p += 4;
      var per = ((flags & 0x100) ? 4 : 0) + ((flags & 0x200) ? 4 : 0) + ((flags & 0x400) ? 4 : 0) + ((flags & 0x800) ? 4 : 0);
      for (var s = 0; s < count && p + per <= end; s++) {
        fragTicks += (flags & 0x100) ? u32be(b, p) : trexDefault;
        p += per;
      }
    }
  }, 0);
  var bySamples = samples * 1024 / (timescale ? Math.min(timescale, 96000) : 48000);
  var byTicks = timescale ? (sttsTicks + fragTicks) / timescale : 0;
  var best = Math.max(mvhd, bySamples, byTicks);
  return best > 0 ? best : null;
}

function oggSeconds(b) {
  var i = 0;
  var rate = 0;
  var preSkip = 0;
  var granule = 0;
  var opus = false;
  var framesMs = 0;
  var packet = [];
  var packetIndex = 0;
  var pending = 0;
  var steps = 0;
  while (i + 27 <= b.length && steps++ < 200000) {
    if (b[i] !== 0x4f || b[i + 1] !== 0x67 || b[i + 2] !== 0x67 || b[i + 3] !== 0x53) {
      i++;
      continue;
    }
    var g = u64le(b, i + 6);
    if (g < 0xffffffffffff && g > granule) granule = g;
    var segs = b[i + 26];
    var body = i + 27 + segs;
    if (body > b.length) break;
    var p = body;
    for (var s = 0; s < segs; s++) {
      var len = b[i + 27 + s];
      if (p + len > b.length) break;
      if (pending === 0) packet.push(p);
      pending += len;
      p += len;
      if (len < 255) {
        var start = packet.pop();
        if (packetIndex === 0) {
          if (pending >= 19 && String.fromCharCode.apply(null, Array.from(b.subarray(start, start + 8))) === "OpusHead") {
            opus = true;
            rate = 48000;
            preSkip = b[start + 10] | (b[start + 11] << 8);
          } else if (pending >= 16 && b[start] === 1 && String.fromCharCode.apply(null, Array.from(b.subarray(start + 1, start + 7))) === "vorbis") {
            rate = u32le(b, start + 12);
          }
        } else if (opus && packetIndex >= 2) {
          framesMs += opusPacketMs(b, start, start + pending);
        }
        packetIndex++;
        pending = 0;
        packet = [];
      }
    }
    i = p;
  }
  var byGranule = rate >= 1000 && rate <= 384000 ? Math.max(0, granule - preSkip) / rate : 0;
  var best = Math.max(byGranule, framesMs / 1000);
  return best > 0 ? best : null;
}

var WAV_WIDTHS = { 1: [8, 16, 24, 32, 64], 3: [32, 64], 6: [8], 7: [8], 2: [4], 17: [4], 65534: [8, 16, 24, 32, 64] };

function wavPerSecond(b, at) {
  var tag = b[at] | (b[at + 1] << 8);
  var channels = b[at + 2] | (b[at + 3] << 8);
  var rate = u32le(b, at + 4);
  var bits = b[at + 14] | (b[at + 15] << 8);
  var widths = WAV_WIDTHS[tag];
  if (!widths || widths.indexOf(bits) === -1) return 0;
  if (channels < 1 || channels > 16 || rate < 1000 || rate > 384000) return 0;
  return rate * channels * bits / 8;
}

function wavSeconds(b) {
  var i = 12;
  var perSecond = 0;
  while (i + 8 <= b.length) {
    var id = String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
    var size = u32le(b, i + 4);
    if (id === "fmt " && size >= 16 && i + 24 <= b.length) perSecond = wavPerSecond(b, i + 8);
    if (id === "data") {
      var real = Math.min(size, b.length - i - 8);
      return perSecond ? Math.max(real, 0) / perSecond : null;
    }
    i += 8 + size + (size & 1);
  }
  return null;
}

export function audioFormat(b) {
  if (!b || b.length < 12) return "";
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return "webm";
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) return "mp4";
  if (b[0] === 0x4f && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53) return "ogg";
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x41 && b[10] === 0x56 && b[11] === 0x45) return "wav";
  return "";
}

export function audioSeconds(bytes) {
  var b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
  var format = audioFormat(b);
  var measured = null;
  try {
    if (format === "webm") measured = webmSeconds(b);
    else if (format === "mp4") measured = mp4Seconds(b);
    else if (format === "ogg") measured = oggSeconds(b);
    else if (format === "wav") measured = wavSeconds(b);
  } catch (e) {
    measured = null;
  }
  var floor = b.length * 8 / AUDIO_FLOOR_BPS;
  if (measured != null && Number.isFinite(measured) && measured > 0) {
    return { seconds: measured, format: format, measured: true };
  }
  return { seconds: floor, format: format, measured: false };
}

export function audioMinSeconds(bytes) {
  var b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
  return b.length * 8 / (audioFormat(b) === "wav" ? AUDIO_PCM_CEIL_BPS : AUDIO_CEIL_BPS);
}
