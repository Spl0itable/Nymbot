import {
  botProGenerators, botMediaQuote, botBtcPrice, botProImageGenerate, botStandardImageBytes, botStoreMedia, botBlossomUpload,
  botSniffImageMime, botSniffVideoMime, botVideoPlan, botVideoStart, botVideoCollect, botPollVideoOnce, isPrivateHostUrl,
  BOT_IMAGE_MODELS, BOT_MEDIA_COSTS, BOT_MILLI_PER_CREDIT
} from "./bot.js";
import { getPublicKey, botBase64Encode, botBase64Decode, bytesToHex, randomBytes, sha256, signEvent, utf8ToBytes } from "./_shared.js";
import { hasD1 } from "./_d1.js";
import { mediaTiers, mediaTier, mediaRate } from "./_mediaprice.js";
import { ledgerCall } from "./_ledger.js";
import { ApiError, apiBad, apiJson, apiRandomId, apiRound, apiIso } from "./_apihttp.js";
import {
  apiBillOpen, apiBillSettle, apiBillRelease, apiCostObject, apiCostHeaders, apiRecordQuery, apiMilliSats, apiUsd
} from "./_apibill.js";
import { apiResolveModel } from "./_apimodels.js";
import { apiL402StatusUrl, apiL402VideoToken, apiL402VideoRefund, apiL402GiveBack } from "./_apil402.js";

export const API_IMAGE_MAX_N = 4;
export const API_IMAGE_UPLOAD_MAX_BYTES = 20 * 1024 * 1024;
export const API_IMAGE_SIDE_MAX_BYTES = 1024 * 1024;
export const API_VIDEO_JOB_TTL_MS = 24 * 3600 * 1000;
export const API_VIDEO_RENDER_LIMIT_MS = 3600 * 1000;
export const API_VIDEO_CLAIM_MS = 120 * 1000;
export const API_VIDEO_LIST_MAX = 50;
export const API_VIDEO_LIMITS = { outstanding: 10 };

const STANDARD_IMAGE = BOT_IMAGE_MODELS.standard;
const RATIOS = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9", "5:4", "4:5"];
const RESPONSE_FORMATS = ["url", "b64_json"];

export function apiMediaSigner(env) {
  const sk = env && env.BOT_PRIVKEY;
  if (!sk) return null;
  try { return { sk, pk: getPublicKey(sk) }; } catch (e) { return null; }
}

export function apiNeedSigner(env, why) {
  const s = apiMediaSigner(env);
  if (!s) {
    throw new ApiError(503, "api_error", "Media hosting is not configured on this server" + (why ? ", so " + why : "") + ".",
      { code: "media_hosting_unavailable" });
  }
  return s;
}

export function apiFindGenerator(table, name) {
  const want = String(name || "").trim().toLowerCase();
  if (!want || !table) return null;
  if (Object.prototype.hasOwnProperty.call(table, want)) return { key: want, model: table[want] };
  for (const k of Object.keys(table)) {
    if (String(table[k].model || "").toLowerCase() === want) return { key: k, model: table[k] };
  }
  return null;
}

export async function apiWrongModel(env, name, kind, gens) {
  const label = { image: "an image generator", video: "a video generator", speech: "a speech model", embedding: "an embedding model", transcription: "a transcription model" }[kind];
  const list = { image: "image", video: "video", speech: "audio", embedding: "embedding", transcription: "audio" }[kind];
  let known = false;
  const g = gens || await botProGenerators(env);
  for (const k of ["image", "video", "speech"]) {
    if (k !== kind && apiFindGenerator(g[k], name)) known = true;
  }
  if (!known) {
    try { known = !!(await apiResolveModel(env, name)); } catch (e) { known = false; }
  }
  if (known) {
    return new ApiError(400, "invalid_request_error", "`" + name + "` is not " + label + ". List them with GET /api/v1/models?type=" + list + ".",
      { code: "invalid_model", param: "model" });
  }
  return new ApiError(404, "not_found_error", "The model `" + name + "` does not exist or is not " + label + " on Nymbot. List them with GET /api/v1/models?type=" + list + ".",
    { code: "model_not_found", param: "model" });
}

export function apiMediaFailed(what, chargedSats) {
  const charged = chargedSats > 0;
  return new ApiError(502, "api_error", what + (charged
    ? " The provider bills an attempt once it accepts it, so it was charged."
    : " Nothing was charged. Please try again."), { code: "upstream_error", extra: charged ? { charged_sats: chargedSats } : null });
}

export function apiNymbotCost(cost) {
  const o = Object.assign({}, cost);
  delete o.charged_usd;
  return o;
}

function requireText(v, param) {
  if (typeof v !== "string" || !v.trim()) throw apiBad("`" + param + "` is required.", param, "missing_required_parameter");
  return v;
}

function intIn(v, param, lo, hi, dflt) {
  if (v == null || v === "") return dflt;
  const n = Number(v);
  if (!Number.isInteger(n) || n < lo || n > hi) throw apiBad("`" + param + "` must be a whole number from " + lo + " to " + hi + ".", param, "invalid_value");
  return n;
}

const u32be = (b, i) => ((b[i] << 24) >>> 0) + ((b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]);
const u32le = (b, i) => ((b[i + 3] << 24) >>> 0) + ((b[i + 2] << 16) | (b[i + 1] << 8) | b[i]);
const ascii = (b, i, n) => String.fromCharCode(...b.subarray(i, i + n));

function join(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

let crcTable = null;
function crc32(b) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++) c = crcTable[(c ^ b[i]) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function nonce() {
  return utf8ToBytes("nymbot:" + bytesToHex(randomBytes(16)));
}

function pngChunk(type, data) {
  const out = new Uint8Array(12 + data.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  out.set(utf8ToBytes(type), 4);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

function pngClean(b) {
  let i = 8;
  let side = 0;
  let idat = false;
  while (i + 12 <= b.length) {
    const len = u32be(b, i);
    const type = ascii(b, i + 4, 4);
    const end = i + 12 + len;
    if (!/^[A-Za-z]{4}$/.test(type) || end > b.length) return null;
    if (i === 8) {
      if (type !== "IHDR" || len !== 13 || !u32be(b, i + 8) || !u32be(b, i + 12)) return null;
    } else if (type === "IHDR") {
      return null;
    } else if (type === "IDAT") {
      idat = true;
    } else if (type === "IEND") {
      if (!idat) return null;
      return join([b.subarray(0, i), pngChunk("tEXt", join([utf8ToBytes("Comment\0"), nonce()])), pngChunk("IEND", new Uint8Array(0))]);
    } else if (type !== "PLTE") {
      side += len;
      if (side > API_IMAGE_SIDE_MAX_BYTES) return null;
    }
    i = end;
  }
  return null;
}

function jpegClean(b) {
  let i = 2;
  let side = 0;
  let frame = false;
  let scan = false;
  while (i + 2 <= b.length) {
    if (b[i] !== 0xff) return null;
    const m = b[i + 1];
    if (m === 0xff) { i++; continue; }
    if (m === 0xd9) {
      if (!frame || !scan) return null;
      const note = nonce();
      return join([b.subarray(0, 2), new Uint8Array([0xff, 0xfe, (note.length + 2) >> 8, (note.length + 2) & 255]), note, b.subarray(2, i + 2)]);
    }
    if (m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
    if (i + 4 > b.length) return null;
    const len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return null;
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) frame = true;
    if ((m >= 0xe0 && m <= 0xef) || m === 0xfe) {
      side += len;
      if (side > API_IMAGE_SIDE_MAX_BYTES) return null;
    }
    i += 2 + len;
    if (m === 0xda) {
      if (!frame) return null;
      scan = true;
      while (i + 1 < b.length && !(b[i] === 0xff && b[i + 1] !== 0 && (b[i + 1] < 0xd0 || b[i + 1] > 0xd7))) i++;
    }
  }
  return null;
}

function gifBlocks(b, at) {
  while (at < b.length) {
    const n = b[at];
    at += 1 + n;
    if (n === 0) return at <= b.length ? at : -1;
  }
  return -1;
}

function gifClean(b) {
  if (!/^GIF8[79]a$/.test(ascii(b, 0, 6)) || b.length < 14) return null;
  let i = 13;
  let side = 0;
  let image = false;
  if (b[10] & 0x80) i += 3 * (1 << ((b[10] & 7) + 1));
  while (i < b.length) {
    const t = b[i];
    if (t === 0x3b) {
      if (!image) return null;
      const note = nonce();
      return join([b.subarray(0, i), new Uint8Array([0x21, 0xfe, note.length]), note, new Uint8Array([0, 0x3b])]);
    }
    if (t === 0x2c) {
      if (i + 11 > b.length) return null;
      const flags = b[i + 9];
      i += 10;
      if (flags & 0x80) i += 3 * (1 << ((flags & 7) + 1));
      const next = gifBlocks(b, i + 1);
      if (next < 0) return null;
      i = next;
      image = true;
    } else if (t === 0x21) {
      const next = gifBlocks(b, i + 2);
      if (next < 0) return null;
      if (b[i + 1] !== 0xf9) {
        side += next - i;
        if (side > API_IMAGE_SIDE_MAX_BYTES) return null;
      }
      i = next;
    } else {
      return null;
    }
  }
  return null;
}

function webpClean(b) {
  if (ascii(b, 8, 4) !== "WEBP") return null;
  const size = u32le(b, 4);
  const end = 8 + size;
  if (size < 12 || end > b.length) return null;
  let i = 12;
  let side = 0;
  let image = false;
  while (i + 8 <= end) {
    const type = ascii(b, i, 4);
    const len = u32le(b, i + 4);
    if (i + 8 + len > end) return null;
    if (type === "VP8 " || type === "VP8L" || type === "ANMF") image = true;
    else if (type !== "VP8X" && type !== "ALPH" && type !== "ANIM") {
      side += len;
      if (side > API_IMAGE_SIDE_MAX_BYTES) return null;
    }
    i += 8 + len + (len & 1);
  }
  if (!image) return null;
  const body = b.subarray(0, end + (end & 1) <= b.length ? end + (end & 1) : end);
  const note = nonce();
  const chunk = new Uint8Array(8 + note.length + (note.length & 1));
  chunk.set(utf8ToBytes("NYMB"), 0);
  new DataView(chunk.buffer).setUint32(4, note.length, true);
  chunk.set(note, 8);
  const out = join([body, chunk]);
  new DataView(out.buffer).setUint32(4, out.length - 8, true);
  return out;
}

export function apiCleanImage(b) {
  if (!b || b.length < 14) return null;
  let out = null;
  try {
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) out = pngClean(b);
    else if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) out = jpegClean(b);
    else if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) out = gifClean(b);
    else if (ascii(b, 0, 4) === "RIFF") out = webpClean(b);
  } catch (e) {
    out = null;
  }
  return out;
}

export function apiImageRef(v, param) {
  if (v == null || v === "") return null;
  if (typeof v !== "string") throw apiBad("`" + param + "` must be a string URL.", param, "invalid_image_url");
  const data = /^data:image\/(?:png|jpe?g|webp|gif);base64,([A-Za-z0-9+/=\s]+)$/i.exec(v);
  if (data) {
    let bytes = null;
    try { bytes = botBase64Decode(data[1].replace(/\s+/g, "")); } catch (e) { bytes = null; }
    const clean = apiCleanImage(bytes);
    if (!clean) throw apiBad("`" + param + "` is not a PNG, JPEG, WebP or GIF picture.", param, "invalid_image");
    return { bytes: clean };
  }
  if (!/^https?:\/\/[^\s]+$/i.test(v)) throw apiBad("`" + param + "` must be an http(s) URL or a base64 data URL of a picture.", param, "invalid_image_url");
  if (isPrivateHostUrl(v)) throw apiBad("`" + param + "` points at a private or local address.", param, "invalid_image_url");
  return { url: v };
}

async function hostRef(env, ref, signer) {
  if (!ref) return null;
  if (ref.url) return ref.url;
  let url;
  try {
    url = await botBlossomUpload(env, ref.bytes, botSniffImageMime(ref.bytes), signer.sk, signer.pk, "");
  } catch (e) {
    throw new ApiError(502, "api_error", "The input picture could not be hosted for the generator. Nothing was charged. Please try again.", { code: "upstream_error" });
  }
  let origin = null;
  try { origin = new URL(url).origin; } catch (e) { origin = null; }
  ref.hosted = origin ? { blob: origin + "/" + bytesToHex(sha256(ref.bytes)), signer } : null;
  return url;
}

export async function apiDropHosted(blob, signer) {
  if (!blob || !signer) return;
  const sha = blob.slice(blob.lastIndexOf("/") + 1);
  const now = Math.floor(Date.now() / 1000);
  const evt = signEvent({
    kind: 24242, pubkey: signer.pk, created_at: now,
    tags: [["t", "delete"], ["x", sha], ["expiration", String(now + 300)]], content: "Nymbot media delete"
  }, signer.sk);
  try {
    const res = await fetch(blob, { method: "DELETE", headers: { Authorization: "Nostr " + botBase64Encode(utf8ToBytes(JSON.stringify(evt))) } });
    try { if (res.body && res.body.cancel) await res.body.cancel(); } catch (e) { }
  } catch (e) { }
}

function dropRef(api, ref) {
  if (ref && ref.hosted) api.waitUntil(apiDropHosted(ref.hosted.blob, ref.hosted.signer));
}

function ratioOf(v, param) {
  if (v == null || v === "") return null;
  const s = String(v).trim().toLowerCase();
  if (s === "auto") return null;
  let m = /^(\d{1,2})\s*:\s*(\d{1,2})$/.exec(s);
  if (m && Number(m[1]) > 0 && Number(m[2]) > 0) return m[1] + ":" + m[2];
  m = /^(\d{2,5})\s*x\s*(\d{2,5})$/.exec(s);
  if (!m || !Number(m[1]) || !Number(m[2])) {
    throw apiBad("`" + param + "` must be an aspect ratio such as \"16:9\" or a size such as \"1024x1024\".", param, "invalid_size");
  }
  const want = Math.log(Number(m[1]) / Number(m[2]));
  let best = RATIOS[0];
  let gap = Infinity;
  for (const r of RATIOS) {
    const [a, b] = r.split(":").map(Number);
    const d = Math.abs(Math.log(a / b) - want);
    if (d < gap) { gap = d; best = r; }
  }
  return best;
}

function imageExtra(gen, o) {
  const extra = {};
  const ratio = ratioOf(o.aspect_ratio != null && o.aspect_ratio !== "" ? o.aspect_ratio : o.size, o.aspect_ratio ? "aspect_ratio" : "size");
  if (ratio) {
    extra.aspect_ratio = ratio;
    if (gen && gen.family === "bfl") {
      const [a, b] = ratio.split(":").map(Number);
      extra.width = Math.round(Math.sqrt(1048576 * a / b) / 16) * 16;
      extra.height = Math.round(Math.sqrt(1048576 * b / a) / 16) * 16;
    }
  }
  for (const k of ["quality", "negative_prompt", "output_format"]) {
    if (typeof o[k] === "string" && o[k].trim()) extra[k] = o[k].trim().slice(0, 2000);
  }
  return extra;
}

async function imageGenerator(env, name, ref) {
  const want = String(name || "").trim();
  if (want === STANDARD_IMAGE || want.toLowerCase() === STANDARD_IMAGE) {
    if (ref) {
      throw apiBad("The standard generator cannot start from a picture. Use a Pro generator with edit: true in GET /api/v1/models?type=image.", "model", "edit_unsupported");
    }
    return { id: STANDARD_IMAGE, tier: "standard", gen: null };
  }
  const gens = await botProGenerators(env);
  const hit = apiFindGenerator(gens.image, want);
  if (!hit) throw await apiWrongModel(env, want, "image", gens);
  if (ref && !hit.model.edit) {
    throw apiBad(hit.model.label + " cannot edit a picture. Pick a generator with edit: true in GET /api/v1/models?type=image.", "model", "edit_unsupported");
  }
  if (!ref && hit.model.needsImage) {
    throw apiBad(hit.model.label + " edits a picture rather than drawing from nothing. Send image_url (or use /images/edits).", "image_url", "image_required");
  }
  return { id: hit.key, tier: "pro", gen: hit.model };
}

async function imageOne(env, pick, prompt, refs, extra, format, signer) {
  if (pick.tier === "standard") {
    const bytes = await botStandardImageBytes(env, prompt, STANDARD_IMAGE);
    if (!bytes || !bytes.length) throw new Error("The image model returned no image.");
    const type = botSniffImageMime(bytes);
    if (format === "b64_json") return { b64_json: botBase64Encode(bytes), content_type: type };
    return { url: await botBlossomUpload(env, bytes, type, signer.sk, signer.pk, ""), content_type: type };
  }
  const made = await botProImageGenerate(env, pick.gen, prompt, refs, extra);
  if (made.linkOnly) return { url: made.sourceUrl, content_type: null };
  if (!made.bytes || !made.bytes.length) {
    const e = new Error(pick.gen.label + " accepted the request but returned no image.");
    e.billed = true;
    throw e;
  }
  const type = botSniffImageMime(made.bytes);
  if (format === "b64_json") return { b64_json: botBase64Encode(made.bytes), content_type: type };
  return { url: await botStoreMedia(env, made.bytes, type, signer.sk, signer.pk, made.sourceUrl, "The picture"), content_type: type };
}

async function imagesRun(api, o) {
  const env = api.env;
  const t0 = Date.now();
  const pick = await imageGenerator(env, o.model, o.ref);
  const btc = await botBtcPrice();
  const perMilli = pick.tier === "standard"
    ? BOT_MEDIA_COSTS.image.standard * BOT_MILLI_PER_CREDIT
    : botMediaQuote("image", pick.gen, { refs: o.ref ? 1 : 0 }, btc).milli;
  const signer = o.format === "url" || (o.ref && o.ref.bytes) ? apiNeedSigner(env, "use response_format b64_json with a URL image") : null;
  const extra = pick.gen ? imageExtra(pick.gen, o.params) : null;
  const bill = await apiBillOpen(api, { tier: pick.tier, reserveMilli: perMilli * o.n, l402Partial: true });
  const record = (milli, status) => api.waitUntil(apiRecordQuery(api, {
    type: "image", model: pick.id, usage: null, milli, tier: pick.tier, status, btcUsd: btc, ms: Date.now() - t0, calls: o.n
  }));
  let refs = [];
  try {
    const hosted = await hostRef(env, o.ref, signer);
    if (hosted) refs = [hosted];
  } catch (e) {
    await apiBillRelease(api, bill);
    record(0, "error");
    throw e;
  }
  const runs = [];
  for (let i = 0; i < o.n; i++) {
    runs.push(imageOne(env, pick, o.prompt, refs, extra, o.format, signer).then((item) => ({ item }), (err) => ({ err })));
  }
  const done = await Promise.all(runs);
  const items = done.filter((d) => d.item).map((d) => d.item);
  const billed = done.filter((d) => d.err && d.err.billed).length;
  const milli = perMilli * (items.length + billed);
  const settled = milli > 0 ? await apiBillSettle(api, bill, milli) : await apiBillRelease(api, bill);
  if (milli <= 0) dropRef(api, o.ref);
  if (!items.length) {
    record(settled.chargedMilli, "error");
    throw apiMediaFailed("The image generator failed.", apiMilliSats(settled.chargedMilli, pick.tier));
  }
  const cost = await apiCostObject(api, bill, settled, btc);
  record(settled.chargedMilli, "ok");
  const out = { created: Math.floor(Date.now() / 1000), model: pick.id, cost: cost.charged_usd, data: items, nymbot: apiNymbotCost(cost) };
  if (items.length < o.n) out.nymbot.failed = o.n - items.length;
  return apiJson(out, 200, apiCostHeaders(cost));
}

function responseFormat(v, dflt) {
  if (v == null || v === "") return dflt;
  if (!RESPONSE_FORMATS.includes(v)) throw apiBad("`response_format` must be \"url\" or \"b64_json\".", "response_format", "invalid_value");
  return v;
}

async function generations(api) {
  const b = api.body;
  requireText(b.model, "model");
  const prompt = requireText(b.prompt, "prompt");
  const n = intIn(b.n != null ? b.n : b.num_images, b.n != null ? "n" : "num_images", 1, API_IMAGE_MAX_N, 1);
  const format = responseFormat(b.response_format, "url");
  const ref = apiImageRef(b.image_url, "image_url");
  return imagesRun(api, { model: b.model, prompt, n, format, ref, params: b });
}

async function readForm(api, what) {
  try {
    return await api.request.formData();
  } catch (e) {
    throw apiBad("This endpoint takes multipart/form-data with " + what + ".", null, "invalid_multipart");
  }
}

function formText(form, name) {
  const v = form.get(name);
  return typeof v === "string" ? v : null;
}

export async function apiFormFile(form, names, max, label) {
  let f = null;
  for (const n of names) {
    const v = n.endsWith("[]") ? form.getAll(n)[0] : form.get(n);
    if (v && typeof v === "object" && typeof v.arrayBuffer === "function") { f = v; break; }
  }
  if (!f) return null;
  if (f.size > max) {
    throw new ApiError(413, "invalid_request_error", label + " is larger than the " + Math.round(max / 1024 / 1024) + " MB this endpoint accepts.", { code: "file_too_large", param: names[0] });
  }
  return new Uint8Array(await f.arrayBuffer());
}

async function edits(api) {
  const form = await readForm(api, "an `image` file, a `prompt` and a `model`");
  const bytes = await apiFormFile(form, ["image", "image[]"], API_IMAGE_UPLOAD_MAX_BYTES, "The picture");
  if (!bytes) throw apiBad("`image` is required: send the picture to edit as a file.", "image", "missing_required_parameter");
  const clean = apiCleanImage(bytes);
  if (!clean) throw apiBad("`image` is not a PNG, JPEG, WebP or GIF picture.", "image", "invalid_image");
  const model = requireText(formText(form, "model"), "model");
  const prompt = requireText(formText(form, "prompt"), "prompt");
  const n = intIn(formText(form, "n"), "n", 1, API_IMAGE_MAX_N, 1);
  const format = responseFormat(formText(form, "response_format"), "b64_json");
  const params = {};
  for (const k of ["size", "aspect_ratio", "quality", "negative_prompt", "output_format"]) {
    const v = formText(form, k);
    if (v != null) params[k] = v;
  }
  return imagesRun(api, { model, prompt, n, format, ref: { bytes: clean }, params });
}

const VIDEO_DDL = [
  "CREATE TABLE IF NOT EXISTS api_video_jobs (id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, key_id TEXT, model TEXT NOT NULL, " +
  "status TEXT NOT NULL, job_url TEXT, hold_id TEXT NOT NULL, hold_credits INTEGER NOT NULL, key_limited INTEGER NOT NULL DEFAULT 0, " +
  "milli INTEGER NOT NULL, seconds INTEGER, resolution TEXT, url TEXT, content_type TEXT, error TEXT, " +
  "charged_milli INTEGER NOT NULL DEFAULT 0, cost_usd REAL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, " +
  "completed_at INTEGER, expires_at INTEGER NOT NULL)",
  "CREATE INDEX IF NOT EXISTS api_video_jobs_pubkey ON api_video_jobs (pubkey, created_at)",
  "CREATE INDEX IF NOT EXISTS api_video_jobs_expires ON api_video_jobs (expires_at)",
  "ALTER TABLE api_video_jobs ADD COLUMN refunded_milli INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE api_video_jobs ADD COLUMN input_blob TEXT"
];
const videoReady = new WeakSet();

async function videoDb(env) {
  const db = env && env.DB_BOT;
  if (!hasD1(db)) {
    throw new ApiError(503, "api_error", "Video jobs cannot be stored right now. Try again shortly.", { code: "service_unavailable", headers: { "Retry-After": "30" } });
  }
  if (!videoReady.has(db)) {
    for (const ddl of VIDEO_DDL) { try { await db.prepare(ddl).run(); } catch (e) { } }
    videoReady.add(db);
  }
  return db;
}

const paidRow = (row) => /^l402:/.test(String(row.pubkey || ""));

function videoObject(row, btc, env) {
  const status = row.status === "delivering" ? "in_progress" : row.status;
  const out = {
    id: row.id, object: "video", model: row.model, status, created: Math.floor(row.created_at / 1000),
    seconds: row.seconds, resolution: row.resolution,
    estimated_cost: apiUsd(apiMilliSats(row.milli, "pro"), btc),
    expires_at: Math.floor(row.expires_at / 1000)
  };
  if (status === "completed") {
    out.completed_at = row.completed_at ? Math.floor(row.completed_at / 1000) : null;
    out.data = { url: row.url, content_type: row.content_type || "video/mp4" };
  }
  if (status === "failed") out.error = { code: "generation_failed", message: row.error || "The video could not be made." };
  const refunded = Number(row.refunded_milli) || 0;
  out.cost = refunded > 0 ? 0 : (row.cost_usd != null ? row.cost_usd : 0);
  out.nymbot = { balance: "pro", charged_credits: apiRound(row.charged_milli / 1000), charged_sats: apiMilliSats(row.charged_milli, "pro") };
  if (refunded > 0) {
    out.nymbot.refunded_credits = apiRound(refunded / 1000);
    out.nymbot.refunded_sats = apiMilliSats(refunded, "pro");
  }
  if (paidRow(row)) {
    out.nymbot = { payment: "l402", tier: "pro", paid_sats: apiMilliSats(row.charged_milli, "pro") };
    if (refunded > 0) {
      out.nymbot.refund_sats = apiMilliSats(refunded, "pro");
      out.nymbot.refund_token = env ? apiL402VideoToken(env, row.id) : null;
    }
  }
  return out;
}

async function refundId(jobId) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("api-video-refund/" + jobId));
  return bytesToHex(new Uint8Array(digest));
}

async function refundJob(env, row) {
  const milli = Math.max(0, Math.floor(Number(row.charged_milli) || 0));
  if (!milli) return 0;
  if (paidRow(row)) {
    let minted = null;
    try { minted = await apiL402VideoRefund(env, row.id, apiMilliSats(milli, "pro")); } catch (e) { minted = null; }
    return minted ? milli : null;
  }
  let got;
  try {
    got = await ledgerCall(env, { op: "credit-refund", id: await refundId(row.id), pubkey: row.pubkey, tier: "pro", milli });
  } catch (e) {
    return null;
  }
  if (!got || got._noLedger) return null;
  if (got.ok) return milli;
  if (got.unknown) return 0;
  return null;
}

async function refundHistory(env, row) {
  const db = env && env.DB_BOT;
  if (!hasD1(db)) return;
  try {
    await db.prepare("UPDATE api_queries SET cost_msat = 0, cost_usd = 0, status = 'error' WHERE pubkey = ? AND type = 'video' AND at = ? AND model = ?")
      .bind(row.pubkey, row.created_at, row.model).run();
  } catch (e) { }
}

async function deliverClip(env, got, gen, signer) {
  const clip = await botVideoCollect(got);
  if (clip.linkOnly) return { url: clip.sourceUrl, type: "video/mp4" };
  if (!clip.bytes || !clip.bytes.length) {
    const e = new Error(gen.label + " accepted the clip but returned no video.");
    e.billed = true;
    throw e;
  }
  const type = botSniffVideoMime(clip.bytes);
  return { url: await botStoreMedia(env, clip.bytes, type, signer.sk, signer.pk, clip.sourceUrl, "The clip"), type };
}

async function finishJob(api, db, row, outcome) {
  const now = Date.now();
  let refunded = 0;
  if (outcome.refund) {
    refunded = await refundJob(api.env, row);
    if (refunded == null) {
      throw new ApiError(503, "api_error", "Billing is temporarily unavailable. Try again shortly.", { code: "service_unavailable", headers: { "Retry-After": "30" } });
    }
  }
  await db.prepare("UPDATE api_video_jobs SET status = ?, url = ?, content_type = ?, error = ?, refunded_milli = ?, " +
    "updated_at = ?, completed_at = ?, job_url = NULL WHERE id = ?").bind(
    outcome.status, outcome.url || null, outcome.type || null, outcome.error ? String(outcome.error).slice(0, 300) : null,
    refunded, now, now, row.id).run();
  if (outcome.refund && row.input_blob) api.waitUntil(apiDropHosted(row.input_blob, apiMediaSigner(api.env)));
  if (refunded > 0) api.waitUntil(refundHistory(api.env, row));
  return Object.assign({}, row, {
    status: outcome.status, url: outcome.url || null, content_type: outcome.type || null, error: outcome.error || null,
    refunded_milli: refunded, updated_at: now, completed_at: now, job_url: null
  });
}

async function outstandingCap(api, db) {
  const pubkey = api.auth && api.auth.pubkey;
  if (!pubkey) return;
  const now = Date.now();
  const row = await db.prepare("SELECT COUNT(*) AS n FROM api_video_jobs WHERE pubkey = ? AND status IN ('in_progress', 'delivering') AND created_at > ? AND expires_at > ?")
    .bind(pubkey, now - API_VIDEO_RENDER_LIMIT_MS, now).first();
  const n = Number(row && row.n) || 0;
  if (n >= API_VIDEO_LIMITS.outstanding) {
    throw new ApiError(429, "rate_limit_error", "This account already has " + n + " videos rendering, the most at once. Poll them, and submit more when one finishes.",
      { code: "video_jobs_limit", headers: { "Retry-After": "30" } });
  }
}

async function videoSubmit(api) {
  const env = api.env;
  const b = api.body;
  const name = requireText(b.model, "model");
  const prompt = requireText(b.prompt, "prompt");
  const gens = await botProGenerators(env);
  const hit = apiFindGenerator(gens.video, name);
  if (!hit) throw await apiWrongModel(env, name, "video", gens);
  const gen = hit.model;
  const res = b.resolution != null && b.resolution !== "" ? b.resolution : b.quality;
  const resParam = b.resolution != null && b.resolution !== "" ? "resolution" : "quality";
  if (res != null && res !== "" && mediaTiers(gen).length && !mediaTier(gen, res)) {
    throw apiBad(gen.label + " does not offer " + res + ". It offers " + mediaTiers(gen).map((t) => t.res).join(", ") + ".", resParam, "unsupported_resolution");
  }
  const ref = apiImageRef(b.image_url, "image_url");
  if (gen.needsImage && !ref) throw apiBad(gen.label + " animates a picture. Send image_url.", "image_url", "image_required");
  const extra = {};
  if (b.duration != null && b.duration !== "") {
    const d = typeof b.duration === "string" ? parseFloat(b.duration) : Number(b.duration);
    if (!Number.isFinite(d) || d <= 0 || d > 60) throw apiBad("`duration` must be a number of seconds.", "duration", "invalid_value");
    extra.duration = typeof b.duration === "string" && /s$/i.test(b.duration.trim()) ? b.duration.trim() : Math.ceil(d);
  }
  if (b.aspect_ratio != null && b.aspect_ratio !== "") extra.aspect_ratio = ratioOf(b.aspect_ratio, "aspect_ratio");
  const signer = apiNeedSigner(env, "video cannot be delivered");
  const db = await videoDb(env);
  await outstandingCap(api, db);
  const btc = await botBtcPrice();
  let plan;
  try {
    plan = await botVideoPlan(env, prompt, gen, ref && ref.url ? ref.url : "", res || "", extra);
  } catch (e) {
    throw new ApiError(503, "api_error", "Video generation is not available on this server right now.", { code: "service_unavailable" });
  }
  const milli = botMediaQuote("video", gen, { body: plan.body, seconds: plan.seconds }, btc).milli;
  const tierRes = mediaRate("video", gen, { body: plan.body }).res || null;
  const t0 = Date.now();
  const bill = await apiBillOpen(api, { tier: "pro", reserveMilli: milli });
  const fail = async (e) => {
    const settled = e && e.billed ? await apiBillSettle(api, bill, milli) : await apiBillRelease(api, bill);
    if (!(e && e.billed)) dropRef(api, ref);
    api.waitUntil(apiRecordQuery(api, { type: "video", model: hit.key, usage: null, milli: settled.chargedMilli, tier: "pro", status: "error", btcUsd: btc, ms: Date.now() - t0 }));
    if (e instanceof ApiError) throw e;
    throw apiMediaFailed("The video generator failed.", apiMilliSats(settled.chargedMilli, "pro"));
  };
  let got;
  try {
    if (ref && ref.bytes) plan = await botVideoPlan(env, prompt, gen, await hostRef(env, ref, signer), res || "", extra);
    got = await botVideoStart(env, plan, gen);
  } catch (e) {
    return fail(e);
  }
  let done = null;
  if (!got.job) {
    try { done = await deliverClip(env, got, gen, signer); } catch (e) { return fail(e); }
  }
  const settled = await apiBillSettle(api, bill, milli);
  const cost = await apiCostObject(api, bill, settled, btc);
  const now = Date.now();
  const row = {
    id: apiRandomId("vid_", 24), pubkey: bill.pubkey || "l402:" + bytesToHex(randomBytes(16)), key_id: bill.keyId, model: hit.key, status: done ? "completed" : "in_progress",
    job_url: got.job ? got.job.url : null, hold_id: bill.id, hold_credits: bill.holdCredits, key_limited: bill.keyLimited ? 1 : 0,
    milli, seconds: plan.seconds || null, resolution: tierRes, url: done ? done.url : null, content_type: done ? done.type : null,
    error: null, charged_milli: settled.chargedMilli, cost_usd: cost.charged_usd, refunded_milli: 0, input_blob: ref && ref.hosted ? ref.hosted.blob : null,
    created_at: now, updated_at: now, completed_at: done ? now : null, expires_at: now + API_VIDEO_JOB_TTL_MS
  };
  const cols = Object.keys(row);
  try {
    await db.prepare("INSERT INTO api_video_jobs (" + cols.join(", ") + ") VALUES (" + cols.map(() => "?").join(", ") + ")")
      .bind(...cols.map((c) => row[c])).run();
  } catch (e) {
    if (bill.l402) await apiL402GiveBack(api, bill, bill.l402.paidSats);
    else await refundJob(env, row);
    dropRef(api, ref);
    throw new ApiError(503, "api_error", "Video jobs cannot be stored right now. The charge was refunded. Try again shortly.",
      { code: "service_unavailable", headers: { "Retry-After": "30" } });
  }
  api.waitUntil(apiRecordQuery(api, {
    type: "video", model: hit.key, usage: null, milli: settled.chargedMilli, tier: "pro", status: "ok", btcUsd: btc, ms: now - t0, at: now
  }));
  const out = videoObject(row, btc, env);
  out.cost = cost.charged_usd;
  out.nymbot = apiNymbotCost(cost);
  if (bill.l402) out.status_url = apiL402StatusUrl(api, row.id, row.expires_at);
  if (Math.random() < 0.02) api.waitUntil(db.prepare("DELETE FROM api_video_jobs WHERE expires_at < ?").bind(Date.now()).run());
  return apiJson(out, 202, apiCostHeaders(cost));
}

async function loadJob(api, db) {
  const signed = api.auth.via === "signed";
  const row = signed
    ? await db.prepare("SELECT * FROM api_video_jobs WHERE id = ? AND expires_at > ?").bind(String(api.params.id), Date.now()).first()
    : await db.prepare("SELECT * FROM api_video_jobs WHERE id = ? AND pubkey = ? AND expires_at > ?")
      .bind(String(api.params.id), api.auth.pubkey, Date.now()).first();
  if (!row) {
    throw new ApiError(404, "not_found_error", "No video job `" + api.params.id + "` for this account. Jobs expire 24 hours after they are submitted.",
      { code: "video_not_found", param: "id" });
  }
  return row;
}

async function claim(db, row) {
  const now = Date.now();
  const r = await db.prepare("UPDATE api_video_jobs SET status = 'delivering', updated_at = ? WHERE id = ? AND " +
    "(status = 'in_progress' OR (status = 'delivering' AND updated_at < ?))").bind(now, row.id, now - API_VIDEO_CLAIM_MS).run();
  return !!(r && r.meta && r.meta.changes === 1);
}

async function videoGet(api) {
  const env = api.env;
  const db = await videoDb(env);
  let row = await loadJob(api, db);
  let btc = null;
  try { btc = await botBtcPrice(); } catch (e) { btc = null; }
  if (row.status === "completed" || row.status === "failed" || !row.job_url) {
    return apiJson(videoObject(row, btc, env), row.status === "completed" || row.status === "failed" ? 200 : 202);
  }
  if (row.status === "delivering" && row.updated_at >= Date.now() - API_VIDEO_CLAIM_MS) return apiJson(videoObject(row, btc, env), 202);
  const polled = await botPollVideoOnce(row.job_url);
  const late = Date.now() - row.created_at > API_VIDEO_RENDER_LIMIT_MS;
  if (polled.pending && !late) return apiJson(videoObject(row, btc, env), 202);
  if (!(await claim(db, row))) return apiJson(videoObject(row, btc, env), 202);
  const gens = await botProGenerators(env);
  const hit = apiFindGenerator(gens.video, row.model);
  const gen = hit ? hit.model : { label: row.model };
  let outcome;
  if (polled.found) {
    try {
      const signer = apiNeedSigner(env, "the video cannot be delivered");
      const done = await deliverClip(env, { found: polled.found }, gen, signer);
      outcome = { status: "completed", url: done.url, type: done.type };
    } catch (e) {
      const billed = !!(e && e.billed);
      outcome = { status: "failed", refund: !billed, error: "The video was made, but it could not be stored for delivery." +
        (billed ? " The provider billed the render, so the charge stays." : " The charge was refunded.") };
    }
  } else if (polled.failed) {
    outcome = { status: "failed", refund: true, error: "The video model reported the render failed. The charge was refunded." };
  } else {
    outcome = { status: "failed", error: "The video was still rendering after " + Math.round(API_VIDEO_RENDER_LIMIT_MS / 60000) +
      " minutes, so Nymbot stopped waiting. The provider bills a render once it accepts it, so the charge stays." };
  }
  row = await finishJob(api, db, row, outcome);
  return apiJson(videoObject(row, btc, env), 200);
}

async function videoList(api) {
  const db = await videoDb(api.env);
  const where = api.auth.keyId ? "key_id = ?" : "pubkey = ?";
  const rs = await db.prepare("SELECT * FROM api_video_jobs WHERE " + where + " AND pubkey = ? AND expires_at > ? ORDER BY created_at DESC LIMIT ?")
    .bind(api.auth.keyId || api.auth.pubkey, api.auth.pubkey, Date.now(), API_VIDEO_LIST_MAX).all();
  let btc = null;
  try { btc = await botBtcPrice(); } catch (e) { btc = null; }
  return apiJson({ object: "list", data: ((rs && rs.results) || []).map((r) => videoObject(r, btc, api.env)) });
}

export function registerMedia(r) {
  r.add("POST", "/images/generations", generations, { auth: "paid" });
  r.add("POST", "/images/edits", edits, { auth: "paid", body: "multipart" });
  r.add("POST", "/videos", videoSubmit, { auth: "paid" });
  r.add("GET", "/videos", videoList, { auth: "key", spends: false });
  r.add("GET", "/videos/{id}", videoGet, { auth: "key-or-signed", spends: false });
}
