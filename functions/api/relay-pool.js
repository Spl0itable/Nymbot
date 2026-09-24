import { clientOriginAllowed, socketRateOk } from './_client.js';
import { archiveVerifiedPqAnnouncement, PQ_D_TAG } from './_pq.js';

export const POOL_RELAYS = Object.freeze([
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://offchain.pub',
  'wss://nostr21.com',
  'wss://relay.snort.social',
  'wss://relay.nostr.net',
  'wss://nostr-pub.wellorder.net',
  'wss://relay.0xchat.com',
  'wss://nostr.mom'
]);

export const POOL_LIMITS = Object.freeze({
  maxClientFrame: 300 * 1024,
  maxUpstreamFrame: 512 * 1024,
  maxEventBytes: 256 * 1024,
  maxReqBytes: 32 * 1024,
  maxSubs: 20,
  maxFilters: 10,
  maxSubIdLength: 64,
  connectsPerMinute: 30,
  msgBurst: 60,
  msgPerSec: 20,
  eventBurst: 20,
  eventPerSec: 0.5,
  pqArchivesPerSocket: 3,
  strikesBeforeClose: 200
});

const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
const SUB_ID = /^[A-Za-z0-9_.:~-]+$/;
const BOT_D_PREFIX = 'nym-bot-';

function firstTag(tags, name) {
  for (const t of tags) if (Array.isArray(t) && t[0] === name) return t[1];
  return undefined;
}

export function poolEventShapeOk(ev) {
  if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return false;
  if (typeof ev.id !== 'string' || !HEX64.test(ev.id)) return false;
  if (typeof ev.pubkey !== 'string' || !HEX64.test(ev.pubkey)) return false;
  if (typeof ev.sig !== 'string' || !HEX128.test(ev.sig)) return false;
  if (!Number.isSafeInteger(ev.kind) || ev.kind < 0) return false;
  if (!Number.isSafeInteger(ev.created_at) || ev.created_at < 0) return false;
  if (typeof ev.content !== 'string' || !Array.isArray(ev.tags)) return false;
  for (const t of ev.tags) {
    if (!Array.isArray(t) || t.some((v) => typeof v !== 'string')) return false;
  }
  return true;
}

export function poolEventAllowed(ev) {
  if (!poolEventShapeOk(ev)) return false;
  if (ev.kind === 1059 || ev.kind === 1) return true;
  if (ev.kind === 30078) {
    const d = firstTag(ev.tags, 'd');
    if (d === PQ_D_TAG) return true;
    return typeof d === 'string' && d.length > BOT_D_PREFIX.length && d.length <= 80 && d.startsWith(BOT_D_PREFIX);
  }
  return false;
}

export function poolSubIdOk(subId) {
  return typeof subId === 'string' && subId.length > 0 &&
    subId.length <= POOL_LIMITS.maxSubIdLength && SUB_ID.test(subId);
}

export function poolReqFilters(msg) {
  if (!Array.isArray(msg) || msg.length < 3) return null;
  const filters = msg.slice(2);
  if (filters.length > POOL_LIMITS.maxFilters) return null;
  for (const f of filters) {
    if (!f || typeof f !== 'object' || Array.isArray(f)) return null;
  }
  return filters;
}

function tokenBucket(burst, perSec) {
  let tokens = burst;
  let last = Date.now();
  return () => {
    const now = Date.now();
    tokens = Math.min(burst, tokens + ((now - last) / 1000) * perSec);
    last = now;
    if (tokens < 1) return false;
    tokens -= 1;
    return true;
  };
}

function boundedAdd(set, value, cap) {
  set.add(value);
  if (set.size > cap) set.delete(set.values().next().value);
}

function isUnsupportedKind(reason) {
  if (typeof reason !== 'string') return false;
  return /kinds?\s*not\s*supported/i.test(reason)
    || /\bNIP[\s\-_:]*\d+\b/i.test(reason)
    || /\bkinds?[\s\-_:]*\d+\b/i.test(reason);
}

function extractRejectedKind(reason) {
  if (typeof reason !== 'string') return null;
  let m = reason.match(/\bNIP[\s\-_:]*(\d+)\b/i);
  if (m) return parseInt(m[1], 10);
  m = reason.match(/\bkinds?[\s\-_:]*(\d+)\b/i);
  if (m) return parseInt(m[1], 10);
  return null;
}

function stripKinds(filters, blocked) {
  if (!blocked || blocked.size === 0) return filters;
  const out = [];
  for (const f of filters) {
    if (Array.isArray(f.kinds)) {
      const kept = f.kinds.filter((k) => !blocked.has(k));
      if (kept.length === 0) continue;
      out.push(kept.length === f.kinds.length ? f : { ...f, kinds: kept });
    } else {
      out.push(f);
    }
  }
  return out;
}

export async function onRequest(context) {
  const { request, env } = context;

  const upgradeHeader = request.headers.get('Upgrade');
  if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
    return new Response('Expected WebSocket upgrade', { status: 426 });
  }

  if (!clientOriginAllowed(request, env)) {
    return new Response('Forbidden', { status: 403 });
  }

  if (!(await socketRateOk(request, env, 'relay-pool', POOL_LIMITS.connectsPerMinute, 'RELAY_POOL_RATE_LIMITER'))) {
    return new Response('Too many connections', { status: 429 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  const upstreams = new Map();
  const subs = new Map();
  const subRelays = new Map();
  const seenEvents = new Set();
  const acceptedOKs = new Set();
  const published = new Set();
  const seenEOSE = new Set();
  const kindBlacklist = new Map();
  const closedKindRetries = new Map();
  const reconnectAttempts = new Map();
  const reconnectTimers = new Map();
  const connectQueue = [];
  const queued = new Set();
  let inFlightConnects = 0;
  let serverOpen = true;
  let started = false;
  let strikes = 0;
  let pqArchives = 0;
  let statusTimer = null;

  const MAX_CONCURRENT_CONNECTS = 6;
  const SEEN_EVENTS_MAX = 20000;
  const OK_MAX = 1000;
  const CLOSED_RETRY_MAX = 3;

  const takeMessage = tokenBucket(POOL_LIMITS.msgBurst, POOL_LIMITS.msgPerSec);
  const takeEvent = tokenBucket(POOL_LIMITS.eventBurst, POOL_LIMITS.eventPerSec);

  const channelsDb = env && env.DB_CHANNELS && typeof env.DB_CHANNELS.prepare === 'function'
    ? env.DB_CHANNELS : null;

  function runBackground(work) {
    try {
      if (context && typeof context.waitUntil === 'function') context.waitUntil(work);
      else if (work && work.catch) work.catch(() => { });
    } catch { }
  }

  function sendToClient(data) {
    try {
      if (serverOpen && server.readyState === 1) {
        server.send(typeof data === 'string' ? data : JSON.stringify(data));
      }
    } catch { }
  }

  function strike() {
    if (++strikes < POOL_LIMITS.strikesBeforeClose) return;
    try { server.close(1008, 'rate limited'); } catch { }
    cleanupAll();
  }

  let keepaliveTimer = setInterval(() => {
    if (serverOpen && server.readyState === 1) {
      sendToClient(['POOL:PING', Date.now()]);
    } else {
      clearInterval(keepaliveTimer);
      keepaliveTimer = null;
    }
  }, 30000);

  function sendPoolStatus() {
    const connected = [];
    upstreams.forEach((info, url) => { if (info.status === 'connected') connected.push(url); });
    sendToClient(['POOL:STATUS', { connected, count: connected.length }]);
  }

  function schedulePoolStatus() {
    if (statusTimer) return;
    statusTimer = setTimeout(() => {
      statusTimer = null;
      sendPoolStatus();
    }, 300);
  }

  function isOpen(info) {
    return info && info.status === 'connected' && info.ws && info.ws.readyState === 1;
  }

  function reqPayload(subId, relayUrl) {
    const filters = subs.get(subId);
    if (!filters) return null;
    const kept = stripKinds(filters, kindBlacklist.get(relayUrl));
    if (kept.length === 0) return null;
    return JSON.stringify(['REQ', subId, ...kept]);
  }

  function sendSubscription(relayUrl, info, subId) {
    const payload = reqPayload(subId, relayUrl);
    if (!payload) return false;
    try { info.ws.send(payload); } catch { return false; }
    let targets = subRelays.get(subId);
    if (!targets) { targets = new Set(); subRelays.set(subId, targets); }
    targets.add(relayUrl);
    return true;
  }

  function start() {
    if (started) return;
    started = true;
    for (const url of POOL_RELAYS) queueConnection(url);
  }

  function queueConnection(relayUrl) {
    if (!serverOpen || upstreams.has(relayUrl) || queued.has(relayUrl)) return;
    queued.add(relayUrl);
    connectQueue.push(relayUrl);
    pumpConnectQueue();
  }

  function pumpConnectQueue() {
    while (serverOpen && inFlightConnects < MAX_CONCURRENT_CONNECTS && connectQueue.length > 0) {
      const relayUrl = connectQueue.shift();
      queued.delete(relayUrl);
      if (upstreams.has(relayUrl)) continue;
      inFlightConnects++;
      connectUpstream(relayUrl);
    }
  }

  function scheduleReconnect(relayUrl) {
    if (!serverOpen || reconnectTimers.has(relayUrl)) return;
    const attempts = reconnectAttempts.get(relayUrl) || 0;
    reconnectAttempts.set(relayUrl, attempts + 1);
    const delay = 3000 * Math.pow(1.5, Math.min(attempts, 8)) + Math.random() * 2000;
    reconnectTimers.set(relayUrl, setTimeout(() => {
      reconnectTimers.delete(relayUrl);
      queueConnection(relayUrl);
    }, delay));
  }

  function forgetRelay(relayUrl) {
    upstreams.delete(relayUrl);
    for (const targets of subRelays.values()) targets.delete(relayUrl);
    for (const k of closedKindRetries.keys()) {
      if (k.startsWith(relayUrl + '\n')) closedKindRetries.delete(k);
    }
  }

  function handleUpstreamFrame(relayUrl, info, raw) {
    if (typeof raw !== 'string' || raw.length < 4 || raw.length > POOL_LIMITS.maxUpstreamFrame) return;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!Array.isArray(msg) || typeof msg[0] !== 'string') return;
    const type = msg[0];

    if (type === 'EVENT') {
      if (msg.length !== 3) return;
      const subId = msg[1];
      const ev = msg[2];
      if (!poolSubIdOk(subId) || !subs.has(subId)) return;
      if (!poolEventShapeOk(ev)) return;
      if (seenEvents.has(ev.id)) return;
      boundedAdd(seenEvents, ev.id, SEEN_EVENTS_MAX);
      sendToClient(['EVENT', subId, {
        id: ev.id,
        pubkey: ev.pubkey,
        created_at: ev.created_at,
        kind: ev.kind,
        tags: ev.tags,
        content: ev.content,
        sig: ev.sig
      }, relayUrl]);
      return;
    }

    if (type === 'OK') {
      const id = msg[1];
      if (typeof id !== 'string' || !published.has(id) || typeof msg[2] !== 'boolean') return;
      const reason = typeof msg[3] === 'string' ? msg[3].slice(0, 512) : '';
      if (msg[2]) {
        if (acceptedOKs.has(id)) return;
        boundedAdd(acceptedOKs, id, OK_MAX);
      }
      sendToClient(['OK', id, msg[2], reason, relayUrl]);
      return;
    }

    if (type === 'EOSE') {
      const subId = msg[1];
      if (!poolSubIdOk(subId) || !subs.has(subId) || seenEOSE.has(subId)) return;
      seenEOSE.add(subId);
      sendToClient(['EOSE', subId]);
      return;
    }

    if (type === 'CLOSED') {
      const subId = msg[1];
      const reason = typeof msg[2] === 'string' ? msg[2] : '';
      if (!poolSubIdOk(subId) || !subs.has(subId)) return;
      const targets = subRelays.get(subId);
      if (targets) targets.delete(relayUrl);
      if (!isUnsupportedKind(reason)) return;
      const kind = extractRejectedKind(reason);
      if (kind === null) return;
      let blocked = kindBlacklist.get(relayUrl);
      if (!blocked) { blocked = new Set(); kindBlacklist.set(relayUrl, blocked); }
      if (blocked.size < 64) blocked.add(kind);
      const retryKey = relayUrl + '\n' + subId;
      const retries = closedKindRetries.get(retryKey) || 0;
      if (retries >= CLOSED_RETRY_MAX || !isOpen(info)) return;
      if (closedKindRetries.size > 1000) closedKindRetries.clear();
      closedKindRetries.set(retryKey, retries + 1);
      sendSubscription(relayUrl, info, subId);
    }
  }

  function connectUpstream(relayUrl) {
    let slotReleased = false;
    const releaseSlot = () => {
      if (slotReleased) return;
      slotReleased = true;
      inFlightConnects--;
      pumpConnectQueue();
    };

    const info = { ws: null, status: 'connecting', handled: false };
    upstreams.set(relayUrl, info);

    const fail = () => {
      releaseSlot();
      if (info.handled) return;
      info.handled = true;
      info.status = 'closed';
      forgetRelay(relayUrl);
      schedulePoolStatus();
      scheduleReconnect(relayUrl);
    };

    let ws;
    try {
      ws = new WebSocket(relayUrl);
    } catch {
      fail();
      return;
    }
    info.ws = ws;

    const timeout = setTimeout(() => {
      if (info.status !== 'connecting') return;
      try { ws.close(); } catch { }
      fail();
    }, 8000);

    ws.addEventListener('open', () => {
      clearTimeout(timeout);
      releaseSlot();
      if (info.handled || !serverOpen) {
        try { ws.close(); } catch { }
        return;
      }
      info.status = 'connected';
      reconnectAttempts.delete(relayUrl);
      for (const subId of subs.keys()) sendSubscription(relayUrl, info, subId);
      schedulePoolStatus();
    });

    ws.addEventListener('message', (event) => {
      if (info.handled) return;
      handleUpstreamFrame(relayUrl, info, event.data);
    });

    ws.addEventListener('close', () => { clearTimeout(timeout); fail(); });
    ws.addEventListener('error', () => {
      clearTimeout(timeout);
      try { ws.close(); } catch { }
      fail();
    });
  }

  function publishEvent(ev) {
    const payload = JSON.stringify(['EVENT', ev]);
    if (payload.length > POOL_LIMITS.maxEventBytes) {
      sendToClient(['OK', ev.id, false, 'invalid: event too large']);
      return;
    }
    if (!takeEvent()) {
      strike();
      sendToClient(['OK', ev.id, false, 'rate-limited: slow down']);
      return;
    }
    boundedAdd(published, ev.id, OK_MAX);
    acceptedOKs.delete(ev.id);
    upstreams.forEach((info, url) => {
      if (!isOpen(info)) return;
      const blocked = kindBlacklist.get(url);
      if (blocked && blocked.has(ev.kind)) return;
      try { info.ws.send(payload); } catch { }
    });
    if (channelsDb && ev.kind === 30078 && firstTag(ev.tags, 'd') === PQ_D_TAG &&
      pqArchives < POOL_LIMITS.pqArchivesPerSocket) {
      pqArchives++;
      runBackground(archiveVerifiedPqAnnouncement(channelsDb, ev));
    }
  }

  function openSubscription(msg, rawLength) {
    const subId = msg[1];
    if (!poolSubIdOk(subId)) { strike(); return; }
    const filters = poolReqFilters(msg);
    if (!filters || rawLength > POOL_LIMITS.maxReqBytes) {
      sendToClient(['CLOSED', subId, 'invalid: filters']);
      return;
    }
    if (!subs.has(subId) && subs.size >= POOL_LIMITS.maxSubs) {
      sendToClient(['CLOSED', subId, 'error: too many subscriptions']);
      return;
    }
    subs.set(subId, filters);
    seenEOSE.delete(subId);
    subRelays.set(subId, new Set());
    upstreams.forEach((info, url) => { if (isOpen(info)) sendSubscription(url, info, subId); });
  }

  function closeSubscription(subId) {
    if (!poolSubIdOk(subId) || !subs.has(subId)) return;
    const targets = subRelays.get(subId);
    if (targets && targets.size > 0) {
      const payload = JSON.stringify(['CLOSE', subId]);
      for (const url of targets) {
        const info = upstreams.get(url);
        if (isOpen(info)) { try { info.ws.send(payload); } catch { } }
      }
    }
    subs.delete(subId);
    subRelays.delete(subId);
    seenEOSE.delete(subId);
    for (const k of closedKindRetries.keys()) {
      if (k.endsWith('\n' + subId)) closedKindRetries.delete(k);
    }
  }

  server.addEventListener('message', (event) => {
    if (!serverOpen) return;
    const data = event.data;
    if (typeof data !== 'string' || data.length > POOL_LIMITS.maxClientFrame) { strike(); return; }
    if (!takeMessage()) { strike(); return; }
    let msg;
    try { msg = JSON.parse(data); } catch { strike(); return; }
    if (!Array.isArray(msg)) return;
    const type = msg[0];

    if (type === 'RELAYS') {
      start();
    } else if (type === 'EVENT') {
      const ev = msg[1];
      if (msg.length !== 2 || !poolEventAllowed(ev)) {
        strike();
        if (ev && typeof ev.id === 'string' && HEX64.test(ev.id)) {
          sendToClient(['OK', ev.id, false, 'blocked: kind not accepted by this proxy']);
        }
        return;
      }
      start();
      publishEvent(ev);
    } else if (type === 'REQ') {
      start();
      openSubscription(msg, data.length);
    } else if (type === 'CLOSE') {
      closeSubscription(msg[1]);
    }
  });

  function cleanupAll() {
    if (!serverOpen) return;
    serverOpen = false;
    connectQueue.length = 0;
    queued.clear();
    for (const timerId of reconnectTimers.values()) clearTimeout(timerId);
    reconnectTimers.clear();
    if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    upstreams.forEach((info) => {
      info.handled = true;
      try { if (info.ws) info.ws.close(); } catch { }
    });
    upstreams.clear();
    subs.clear();
    subRelays.clear();
    seenEvents.clear();
    acceptedOKs.clear();
    published.clear();
    seenEOSE.clear();
    kindBlacklist.clear();
    closedKindRetries.clear();
  }

  server.addEventListener('close', cleanupAll);
  server.addEventListener('error', cleanupAll);

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
