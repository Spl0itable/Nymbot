var ENC = new TextEncoder();

export function utf8(s) {
  return ENC.encode(String(s));
}

export function concatBytes(parts) {
  var total = 0;
  for (var i = 0; i < parts.length; i++) total += parts[i].length;
  var out = new Uint8Array(total);
  var at = 0;
  for (var j = 0; j < parts.length; j++) {
    out.set(parts[j], at);
    at += parts[j].length;
  }
  return out;
}

export async function deflateBytes(bytes, raw) {
  var stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream(raw ? "deflate-raw" : "deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

var CRC_TABLE = null;

export function crc32(bytes) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[n] = c >>> 0;
    }
  }
  var crc = 0xffffffff;
  for (var i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function dosTime(date) {
  var d = date instanceof Date && !isNaN(date) ? date : new Date();
  var year = Math.max(1980, d.getUTCFullYear());
  return {
    time: (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | (Math.floor(d.getUTCSeconds() / 2)),
    date: ((year - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate()
  };
}

function le16(v) { return [v & 255, (v >>> 8) & 255]; }
function le32(v) { return [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255]; }

export async function zipFiles(entries, opts) {
  var when = dosTime((opts && opts.date) || new Date());
  var locals = [];
  var central = [];
  var offset = 0;
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    var name = utf8(e.name);
    var data = e.data instanceof Uint8Array ? e.data : utf8(e.data);
    var crc = crc32(data);
    var packed = data.length > 64 && e.store !== true ? await deflateBytes(data, true) : null;
    var method = packed && packed.length < data.length ? 8 : 0;
    var body = method === 8 ? packed : data;
    var common = [].concat(le16(20), le16(0x0800), le16(method), le16(when.time), le16(when.date),
      le32(crc), le32(body.length), le32(data.length), le16(name.length), le16(0));
    var local = concatBytes([new Uint8Array(le32(0x04034b50)), new Uint8Array(common), name, body]);
    locals.push(local);
    central.push(concatBytes([
      new Uint8Array(le32(0x02014b50)), new Uint8Array(le16(20)), new Uint8Array(common),
      new Uint8Array([].concat(le16(0), le16(0), le16(0), le32(0), le32(offset))), name
    ]));
    offset += local.length;
  }
  var dir = concatBytes(central);
  var end = new Uint8Array([].concat(le32(0x06054b50), le16(0), le16(0), le16(entries.length), le16(entries.length),
    le32(dir.length), le32(offset), le16(0)));
  return concatBytes(locals.concat([dir, end]));
}

export function base64ToBytes(b64) {
  var bin = atob(b64);
  var out = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
