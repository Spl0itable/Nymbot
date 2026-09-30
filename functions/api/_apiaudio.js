import {
  aiRun, botProGenerators, botMediaQuote, botBtcPrice, botSpeechBytes, botMilliForUsd,
  BOT_TTS_MODELS, BOT_MEDIA_COSTS, BOT_TTS_MAX_CHARS, BOT_TRANSCRIBE_MODEL, BOT_MILLI_PER_CREDIT, BOT_MIN_CHARGE_MILLI,
  BOT_UNIFIED_BILLING_FEE, BOT_PRICE_MARGIN, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT
} from "./bot.js";
import { botBase64Encode } from "./_shared.js";
import { audioSeconds, audioMinSeconds } from "./_audiolen.js";
import { transcribeUsd } from "./_mediaprice.js";
import { ApiError, apiBad, apiJson, apiRound } from "./_apihttp.js";
import {
  apiBillOpen, apiBillSettle, apiBillRelease, apiCostObject, apiCostHeaders, apiRecordQuery, apiMilliSats
} from "./_apibill.js";
import { apiListModels } from "./_apimodels.js";
import { apiFindGenerator, apiWrongModel, apiMediaFailed, apiNymbotCost, apiFormFile } from "./_apimedia.js";

export const API_TTS_LIMITS = { aura: 2000, melo: BOT_TTS_MAX_CHARS, other: BOT_TTS_MAX_CHARS };
export const API_TRANSCRIBE_MAX_BYTES = 25 * 1024 * 1024;
export const API_TRANSCRIBE_MAX_SECONDS = 1800;
export const API_TRANSCRIBE_GRACE_SECONDS = 3;
export const API_TRANSCRIBE_MIN_BYTES = 256;

const STANDARD_TTS = BOT_TTS_MODELS.standard;
const WHISPER_NAMES = { whisper: 1, "whisper-1": 1, "whisper-large-v3-turbo": 1 };
const OPENAI_VOICES = ["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"];
const AURA_DEFAULT = "luna";
const AURA_VOICES = {
  amalthea: "female", andromeda: "female", apollo: "male", arcas: "male", aries: "male", asteria: "female", athena: "female",
  atlas: "male", aurora: "female", callista: "female", cora: "female", cordelia: "female", delia: "female", draco: "male",
  electra: "female", harmonia: "female", helena: "female", hera: "female", hermes: "male", hyperion: "male", iris: "female",
  janus: "female", juno: "female", jupiter: "male", luna: "female", mars: "male", minerva: "female", neptune: "male",
  odysseus: "male", ophelia: "female", orion: "male", orpheus: "male", pandora: "female", phoebe: "female", pluto: "male",
  saturn: "male", selene: "female", thalia: "female", theia: "female", vesta: "female", zeus: "male"
};
const MELO_VOICES = { en: "English", es: "Spanish", fr: "French", zh: "Chinese" };
const AURA_FORMATS = {
  mp3: { type: "audio/mpeg", extra: null },
  opus: { type: "audio/ogg", extra: { encoding: "opus", container: "ogg" } },
  aac: { type: "audio/aac", extra: { encoding: "aac" } },
  flac: { type: "audio/flac", extra: { encoding: "flac" } },
  wav: { type: "audio/wav", extra: { encoding: "linear16", container: "wav" } },
  pcm: { type: "audio/pcm", extra: { encoding: "linear16", container: "none" } }
};
const MP3_ONLY = { mp3: { type: "audio/mpeg", extra: null } };
const TRANSCRIBE_FORMATS = ["json", "text", "srt", "vtt", "verbose_json"];
const LANGUAGE_NAMES = {
  en: "english", es: "spanish", fr: "french", de: "german", it: "italian", pt: "portuguese", nl: "dutch", ja: "japanese",
  zh: "chinese", ko: "korean", ru: "russian", ar: "arabic", hi: "hindi", pl: "polish", tr: "turkish", uk: "ukrainian",
  sv: "swedish", da: "danish", fi: "finnish", no: "norwegian", cs: "czech", el: "greek", he: "hebrew", id: "indonesian",
  vi: "vietnamese", th: "thai", fa: "persian", ro: "romanian", hu: "hungarian"
};

function engineOf(modelId) {
  const id = String(modelId || "");
  if (/aura-2/.test(id)) return "aura";
  if (/melotts/.test(id)) return "melo";
  return "other";
}

async function speechModel(env, name) {
  const want = typeof name === "string" && name.trim() ? name.trim() : STANDARD_TTS;
  if (want.toLowerCase() === STANDARD_TTS) {
    return { id: STANDARD_TTS, tier: "standard", model: STANDARD_TTS, gen: null, label: "MeloTTS", engine: "melo" };
  }
  const gens = await botProGenerators(env);
  const hit = apiFindGenerator(gens.speech, want);
  if (!hit) throw await apiWrongModel(env, want, "speech", gens);
  return { id: hit.key, tier: "pro", model: hit.model.model, gen: hit.model, label: hit.model.label, engine: engineOf(hit.model.model) };
}

function langCode(v) {
  if (v == null || v === "") return null;
  return String(v).trim().toLowerCase().split(/[-_]/)[0];
}

function pickVoice(pick, voice, language) {
  const v = typeof voice === "string" ? voice.trim().toLowerCase() : "";
  const lang = langCode(language);
  const mismatch = (have) => new ApiError(422, "invalid_request_error",
    "The voice `" + voice + "` speaks " + have + ", not " + language + ". Pick a voice for that language (GET /api/v1/audio/voices?language=" + lang + ") or leave one out.",
    { code: "voice_language_mismatch", param: "voice" });
  const noLang = () => new ApiError(422, "invalid_request_error", pick.label + " has no voice for `" + language + "`. See GET /api/v1/audio/voices.",
    { code: "unsupported_language", param: "language" });
  const unknown = () => apiBad("Unknown voice `" + voice + "` for " + pick.label + ". See GET /api/v1/audio/voices.", "voice", "invalid_voice");
  const generic = !v || OPENAI_VOICES.includes(v);
  if (pick.engine === "aura") {
    let name = null;
    if (!generic) {
      const m = /^aura-2-([a-z]+)-en$/.exec(v);
      name = m ? m[1] : v;
      if (!AURA_VOICES[name]) throw unknown();
    }
    if (lang && lang !== "en") throw name ? mismatch("en") : noLang();
    return { speaker: name || AURA_DEFAULT };
  }
  if (pick.engine === "melo") {
    let code = null;
    if (!generic) {
      code = langCode(v);
      if (!MELO_VOICES[code]) throw unknown();
    }
    if (lang && !MELO_VOICES[lang]) throw code ? mismatch(code) : noLang();
    if (code && lang && code !== lang) throw mismatch(code);
    return { lang: code || lang || "en" };
  }
  return {};
}

async function speech(api) {
  const env = api.env;
  const b = api.body;
  const t0 = Date.now();
  const input = b.input;
  if (typeof input !== "string" || !input.trim()) throw apiBad("`input` is required: the text to read aloud.", "input", "missing_required_parameter");
  const pick = await speechModel(env, b.model);
  const limit = API_TTS_LIMITS[pick.engine];
  if (input.length > limit) {
    throw apiBad("`input` is " + input.length + " characters; " + pick.label + " reads up to " + limit + " per request.", "input", "input_too_long");
  }
  const formats = pick.engine === "aura" ? AURA_FORMATS : MP3_ONLY;
  const fmt = b.response_format == null || b.response_format === "" ? "mp3" : String(b.response_format);
  if (!formats[fmt]) {
    throw apiBad(pick.label + " returns " + Object.keys(formats).join(", ") + " audio, not `" + fmt + "`.", "response_format", "unsupported_response_format");
  }
  const extra = Object.assign({}, pickVoice(pick, b.voice, b.language), formats[fmt].extra || {});
  const btc = await botBtcPrice();
  const milli = pick.tier === "standard"
    ? BOT_MEDIA_COSTS.speak.standard * BOT_MILLI_PER_CREDIT
    : botMediaQuote("speech", pick.gen, { chars: input.length }, btc).milli;
  const bill = await apiBillOpen(api, { tier: pick.tier, reserveMilli: milli });
  let bytes = null;
  try {
    bytes = await botSpeechBytes(env, pick.model, input, extra);
    if (!bytes || !bytes.length) throw new Error("no audio");
  } catch (e) {
    await apiBillRelease(api, bill);
    api.waitUntil(apiRecordQuery(api, { type: "speech", model: pick.id, milli: 0, tier: pick.tier, status: "error", btcUsd: btc, ms: Date.now() - t0 }));
    throw apiMediaFailed("The speech model failed.", 0);
  }
  const settled = await apiBillSettle(api, bill, milli);
  const cost = await apiCostObject(api, bill, settled, btc);
  api.waitUntil(apiRecordQuery(api, { type: "speech", model: pick.id, milli: settled.chargedMilli, tier: pick.tier, status: "ok", btcUsd: btc, ms: Date.now() - t0 }));
  return new Response(bytes, {
    status: 200,
    headers: Object.assign({ "Content-Type": formats[fmt].type, "Content-Length": String(bytes.length) }, apiCostHeaders(cost))
  });
}

function transcribeMilli(seconds, tier, btc) {
  const usd = transcribeUsd(Math.ceil(Math.max(0, seconds))) * BOT_UNIFIED_BILLING_FEE * BOT_PRICE_MARGIN;
  return Math.max(BOT_MIN_CHARGE_MILLI, botMilliForUsd(usd, btc, tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT));
}

async function openEither(api, seconds, btc) {
  if (api.auth.via === "l402") return apiBillOpen(api, { tier: "standard", reserveMilli: transcribeMilli(seconds, "standard", btc), l402Partial: true });
  try {
    const bill = await apiBillOpen(api, { tier: "standard", reserveMilli: transcribeMilli(seconds, "standard", btc) });
    return bill;
  } catch (e) {
    if (!(e instanceof ApiError) || e.status !== 402) throw e;
    try {
      return await apiBillOpen(api, { tier: "pro", reserveMilli: transcribeMilli(seconds, "pro", btc) });
    } catch (e2) {
      if (!(e2 instanceof ApiError) || e2.status !== 402) throw e2;
      const std = e.extra || {};
      const pro = e2.extra || {};
      throw new ApiError(402, "insufficient_quota",
        "Transcription needs " + std.required_sats + " sats on the standard balance or " + pro.required_sats + " sats on the Pro balance, and neither has that free. " +
        "Top up in the Nymbot app or with POST /api/v1/topup/create/btc-lightning.",
        { code: "insufficient_balance", extra: { balance: "standard", required_sats: std.required_sats, balance_sats: std.balance_sats, pro_required_sats: pro.required_sats, pro_balance_sats: pro.balance_sats } });
    }
  }
}

function stamp(sec, sep) {
  const ms = Math.max(0, Math.round((Number(sec) || 0) * 1000));
  const h = Math.floor(ms / 3600000);
  const m = Math.floor(ms / 60000) % 60;
  const s = Math.floor(ms / 1000) % 60;
  const pad = (n, w) => String(n).padStart(w, "0");
  return pad(h, 2) + ":" + pad(m, 2) + ":" + pad(s, 2) + sep + pad(ms % 1000, 3);
}

function segmentsOf(heard, text, seconds) {
  const list = Array.isArray(heard && heard.segments) ? heard.segments : [];
  const out = list.map((s, i) => ({
    id: i, seek: 0, start: apiRound(Number(s.start) || 0, 3), end: apiRound(Number(s.end) || 0, 3), text: String(s.text || ""),
    tokens: [], temperature: 0, avg_logprob: 0, compression_ratio: 0, no_speech_prob: 0
  }));
  if (!out.length && text) out.push({ id: 0, seek: 0, start: 0, end: apiRound(seconds, 3), text, tokens: [], temperature: 0, avg_logprob: 0, compression_ratio: 0, no_speech_prob: 0 });
  return out;
}

function srtOf(segments) {
  return segments.map((s, i) => (i + 1) + "\n" + stamp(s.start, ",") + " --> " + stamp(s.end, ",") + "\n" + s.text.trim() + "\n").join("\n");
}

function vttOf(heard, segments) {
  if (heard && typeof heard.vtt === "string" && /^WEBVTT/.test(heard.vtt.trim())) return heard.vtt.trim() + "\n";
  return "WEBVTT\n\n" + segments.map((s) => stamp(s.start, ".") + " --> " + stamp(s.end, ".") + "\n" + s.text.trim() + "\n").join("\n");
}

async function transcribe(api, task) {
  const env = api.env;
  const t0 = Date.now();
  let form;
  try {
    form = await api.request.formData();
  } catch (e) {
    throw apiBad("This endpoint takes multipart/form-data with a `file` and a `model`.", null, "invalid_multipart");
  }
  const text = (n) => { const v = form.get(n); return typeof v === "string" ? v : null; };
  const bytes = await apiFormFile(form, ["file"], API_TRANSCRIBE_MAX_BYTES, "The audio file");
  if (!bytes) throw apiBad("`file` is required: send the audio as a file.", "file", "missing_required_parameter");
  const name = (text("model") || "whisper").trim();
  if (!WHISPER_NAMES[name.toLowerCase()] && name !== BOT_TRANSCRIBE_MODEL) throw await apiWrongModel(env, name, "transcription");
  const fmt = text("response_format") || "json";
  if (!TRANSCRIBE_FORMATS.includes(fmt)) throw apiBad("`response_format` must be one of " + TRANSCRIBE_FORMATS.join(", ") + ".", "response_format", "invalid_value");
  if (bytes.length < API_TRANSCRIBE_MIN_BYTES) throw apiBad("The file holds no usable audio.", "file", "invalid_audio");
  const len = audioSeconds(bytes);
  const least = audioMinSeconds(bytes);
  const tooLong = (secs) => new ApiError(413, "invalid_request_error", "The audio is " + Math.ceil(secs) + " seconds long; the limit is " + API_TRANSCRIBE_MAX_SECONDS + " seconds (30 minutes) per request.",
    { code: "audio_too_long", param: "file" });
  const limit = API_TRANSCRIBE_MAX_SECONDS + API_TRANSCRIBE_GRACE_SECONDS;
  if (len.measured && len.seconds > limit) throw tooLong(len.seconds);
  const reserveSecs = Math.min(len.measured ? Math.max(len.seconds, least) : len.seconds, API_TRANSCRIBE_MAX_SECONDS);
  const language = task === "transcribe" ? langCode(text("language")) : null;
  const prompt = text("prompt");
  const btc = await botBtcPrice();
  const bill = await openEither(api, reserveSecs, btc);
  const input = { audio: botBase64Encode(bytes), task };
  if (language) input.language = language;
  if (prompt && prompt.trim()) input.initial_prompt = prompt.slice(0, 1000);
  let heard;
  try {
    heard = await aiRun(env.AI, BOT_TRANSCRIBE_MODEL, input);
    if (!heard || typeof heard !== "object") throw new Error("empty");
  } catch (e) {
    await apiBillRelease(api, bill);
    api.waitUntil(apiRecordQuery(api, { type: "transcription", model: "whisper", milli: 0, tier: bill.tier, status: "error", btcUsd: btc, ms: Date.now() - t0 }));
    throw apiMediaFailed("Transcription failed: the speech service could not process that audio.", 0);
  }
  const said = String(heard.text || heard.transcription || (heard.result && heard.result.text) || "").trim();
  const info = heard.transcription_info || {};
  const reported = Number(info.duration);
  const heardSecs = Number.isFinite(reported) && reported > 0 ? reported : 0;
  if (heardSecs > limit) {
    await apiBillRelease(api, bill);
    api.waitUntil(apiRecordQuery(api, { type: "transcription", model: "whisper", milli: 0, tier: bill.tier, status: "error", btcUsd: btc, ms: Date.now() - t0 }));
    throw tooLong(heardSecs);
  }
  const seconds = len.measured ? Math.max(len.seconds, heardSecs, least) : (heardSecs ? Math.max(heardSecs, least) : reserveSecs);
  const settled = await apiBillSettle(api, bill, transcribeMilli(seconds, bill.tier, btc));
  const cost = await apiCostObject(api, bill, settled, btc);
  api.waitUntil(apiRecordQuery(api, { type: "transcription", model: "whisper", milli: settled.chargedMilli, tier: bill.tier, status: "ok", btcUsd: btc, ms: Date.now() - t0 }));
  const headers = apiCostHeaders(cost);
  const duration = apiRound(len.measured ? Math.max(len.seconds, heardSecs) : (heardSecs || len.seconds), 2);
  const usage = { type: "duration", seconds: Math.ceil(seconds) };
  if (fmt === "text") return new Response(said, { status: 200, headers: Object.assign({ "Content-Type": "text/plain; charset=utf-8" }, headers) });
  const segments = segmentsOf(heard, said, duration);
  if (fmt === "srt") return new Response(srtOf(segments), { status: 200, headers: Object.assign({ "Content-Type": "application/x-subrip; charset=utf-8" }, headers) });
  if (fmt === "vtt") return new Response(vttOf(heard, segments), { status: 200, headers: Object.assign({ "Content-Type": "text/vtt; charset=utf-8" }, headers) });
  if (fmt === "verbose_json") {
    const code = langCode(info.language) || language || null;
    return apiJson({
      task, language: task === "translate" ? "english" : (code ? (LANGUAGE_NAMES[code] || code) : null), duration, text: said, segments, usage,
      nymbot: apiNymbotCost(cost)
    }, 200, headers);
  }
  return apiJson({ text: said, usage, nymbot: apiNymbotCost(cost) }, 200, headers);
}

function ttsFacts(entry) {
  const std = entry.id === STANDARD_TTS;
  const engine = std ? "melo" : engineOf(entry.upstream_id || entry.id);
  return Object.assign({}, entry, {
    max_input_chars: API_TTS_LIMITS[engine],
    response_formats: Object.keys(engine === "aura" ? AURA_FORMATS : MP3_ONLY),
    languages: engine === "aura" ? ["en"] : (engine === "melo" ? Object.keys(MELO_VOICES) : []),
    default_voice: engine === "aura" ? AURA_DEFAULT : (engine === "melo" ? "en" : null)
  });
}

async function audioModels(api) {
  const gens = await botProGenerators(api.env);
  const all = await apiListModels(api.env, ["audio"]);
  const tts = [];
  const stt = [];
  for (const m of all) {
    if (m.audio_type === "transcription") {
      stt.push(Object.assign({}, m, {
        aliases: ["whisper-1", BOT_TRANSCRIBE_MODEL], max_file_bytes: API_TRANSCRIBE_MAX_BYTES, max_seconds: API_TRANSCRIBE_MAX_SECONDS,
        response_formats: TRANSCRIBE_FORMATS, languages: ["multi"], translations: true
      }));
    } else {
      const g = apiFindGenerator(gens.speech, m.id);
      const facts = ttsFacts(Object.assign({}, m, g ? { upstream_id: g.model.model } : {}));
      delete facts.upstream_id;
      delete facts.nymbot_key;
      tts.push(facts);
    }
  }
  return apiJson({ object: "list", data: { tts, stt } }, 200, { "Cache-Control": "public, max-age=300" });
}

function voiceList() {
  const out = [];
  for (const name of Object.keys(AURA_VOICES)) {
    out.push({ id: name, name: name[0].toUpperCase() + name.slice(1), provider: "deepgram", model_id: "aura-2", models: ["aura-2"],
      language: "en", description: "Aura 2 English voice", gender: AURA_VOICES[name], preview_url: null });
  }
  for (const code of Object.keys(MELO_VOICES)) {
    out.push({ id: code, name: "MeloTTS " + MELO_VOICES[code], provider: "myshell", model_id: STANDARD_TTS, models: [STANDARD_TTS, "melotts"],
      language: code, description: MELO_VOICES[code] + " (MeloTTS)", gender: null, preview_url: null });
  }
  return out;
}

async function audioVoices(api) {
  const lang = langCode(api.url.searchParams.get("language"));
  const model = api.url.searchParams.get("model");
  let list = voiceList();
  if (lang) list = list.filter((v) => v.language === lang);
  if (model) list = list.filter((v) => v.models.includes(model) || (model === "@cf/deepgram/aura-2-en" && v.model_id === "aura-2"));
  return apiJson({ object: "list", data: list }, 200, { "Cache-Control": "public, max-age=300" });
}

export function registerAudio(r) {
  r.add("POST", "/audio/speech", speech, { auth: "paid" });
  r.add("POST", "/audio/transcriptions", (api) => transcribe(api, "transcribe"), { auth: "paid", body: "multipart" });
  r.add("POST", "/audio/translations", (api) => transcribe(api, "translate"), { auth: "paid", body: "multipart" });
  r.add("GET", "/audio/models", audioModels, { auth: "none", spends: false });
  r.add("GET", "/audio/voices", audioVoices, { auth: "none", spends: false });
}
