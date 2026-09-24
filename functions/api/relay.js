import { clientOriginAllowed, socketRateOk } from './_client.js';
import { mcpIpv6Blocked } from './_mcp.js';

export const RELAY_LIMITS = Object.freeze({
  maxUrlLength: 512,
  maxClientFrame: 32 * 1024,
  maxUpstreamFrame: 512 * 1024,
  maxPending: 16,
  maxFilters: 10,
  maxMessages: 64,
  maxLifetimeMs: 120000,
  connectsPerMinute: 120
});

export function isPrivateRelayHost(hostname) {
  let host = (hostname || '').toLowerCase().replace(/\.$/, '');
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  let h6 = host;
  if (h6.startsWith('[') && h6.endsWith(']')) h6 = h6.slice(1, -1);
  if (host.includes(':') || h6.includes(':')) {
    if (h6 === '::1' || h6 === '::' || h6 === '0:0:0:0:0:0:0:1') return true;
    if (mcpIpv6Blocked(h6) === true) return true;
    if (/^f[cd][0-9a-f]{2}:/.test(h6)) return true;
    if (/^fe[89ab][0-9a-f]:/.test(h6)) return true;
    const m = h6.match(/^::(?:ffff:)?(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
    if (m) host = m[1]; else return false;
  }
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m) {
    const a = +m[1], b = +m[2];
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
    if (a >= 224) return true;
  }
  if (/^\d+$/.test(host) || /^0x[0-9a-f]+$/i.test(host)) return true;
  return false;
}

export function relayTargetOk(target) {
  if (typeof target !== 'string' || !target || target.length > RELAY_LIMITS.maxUrlLength) return null;
  let url;
  try { url = new URL(target); } catch { return null; }
  if (url.protocol !== 'wss:') return null;
  if (url.username || url.password) return null;
  if (url.search || url.hash) return null;
  if (url.port && url.port !== '443') return null;
  if (isPrivateRelayHost(url.hostname)) return null;
  return 'wss://' + url.hostname + (url.pathname === '/' ? '' : url.pathname);
}

export function relayClientFrameOk(raw) {
  if (typeof raw !== 'string' || raw.length > RELAY_LIMITS.maxClientFrame) return false;
  let msg;
  try { msg = JSON.parse(raw); } catch { return false; }
  if (!Array.isArray(msg)) return false;
  const sub = msg[1];
  if (typeof sub !== 'string' || !sub || sub.length > 64) return false;
  if (msg[0] === 'CLOSE') return msg.length === 2;
  if (msg[0] !== 'REQ') return false;
  const filters = msg.slice(2);
  if (filters.length < 1 || filters.length > RELAY_LIMITS.maxFilters) return false;
  return filters.every((f) => f && typeof f === 'object' && !Array.isArray(f));
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

  const url = new URL(request.url);
  const targetRelay = url.searchParams.get('relay');

  if (!targetRelay) {
    return new Response('Missing relay parameter', { status: 400 });
  }

  const target = relayTargetOk(targetRelay);
  if (!target) {
    return new Response('Relay not allowed', { status: 403 });
  }

  if (!(await socketRateOk(request, env, 'relay', RELAY_LIMITS.connectsPerMinute, 'RELAY_RATE_LIMITER'))) {
    return new Response('Too many connections', { status: 429 });
  }

  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();

  let upstream;
  try {
    upstream = new WebSocket(target);
  } catch {
    try { server.close(1011, 'Upstream relay error'); } catch { }
    return new Response(null, { status: 101, webSocket: client });
  }

  let upstreamOpen = false;
  let finished = false;
  let messages = 0;
  const pendingMessages = [];

  const finish = (code, reason) => {
    if (finished) return;
    finished = true;
    if (!(code === 1000 || (code >= 3000 && code <= 4999) || code === 1008 || code === 1011)) code = 1000;
    reason = typeof reason === 'string' ? reason.slice(0, 120) : '';
    clearTimeout(lifetime);
    pendingMessages.length = 0;
    try { upstream.close(code, reason); } catch { }
    try { server.close(code, reason); } catch { }
  };

  const lifetime = setTimeout(() => finish(1000, 'lifetime'), RELAY_LIMITS.maxLifetimeMs);

  upstream.addEventListener('open', () => {
    upstreamOpen = true;
    for (const msg of pendingMessages) {
      try { upstream.send(msg); } catch { }
    }
    pendingMessages.length = 0;
  });

  server.addEventListener('message', (event) => {
    if (finished) return;
    if (++messages > RELAY_LIMITS.maxMessages) { finish(1008, 'too many messages'); return; }
    if (!relayClientFrameOk(event.data)) return;
    try {
      if (upstreamOpen && upstream.readyState === 1) {
        upstream.send(event.data);
      } else if (!upstreamOpen) {
        if (pendingMessages.length >= RELAY_LIMITS.maxPending) { finish(1008, 'too many messages'); return; }
        pendingMessages.push(event.data);
      }
    } catch { }
  });

  upstream.addEventListener('message', (event) => {
    if (finished) return;
    const raw = event.data;
    if (typeof raw !== 'string' || raw.length > RELAY_LIMITS.maxUpstreamFrame) return;
    try {
      if (server.readyState === 1) server.send(raw);
    } catch { }
  });

  server.addEventListener('close', (event) => finish(event && event.code, event && event.reason));
  upstream.addEventListener('close', (event) => finish(event && event.code, event && event.reason));
  server.addEventListener('error', () => finish(1011, 'Client error'));
  upstream.addEventListener('error', () => finish(1011, 'Upstream relay error'));

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}
