import { botBtcPriceBind } from "./bot.js";
import {
  ApiError, apiErrorFrom, apiErrorResponse, apiFinish, apiPreflightHeaders, apiCorsHeaders, apiReadBody, apiRequestId, apiIpRateLimit,
  apiRequireContentType, apiAuthFailGate, apiAuthFailed, apiBufferMultipart, API_JSON_MAX_BYTES, API_MULTIPART_MAX_BYTES, API_NOSTR_MAX_BYTES,
  API_EMPTY_BODY_SHA256
} from "./_apihttp.js";
import { bytesToHex, sha256 } from "./_shared.js";
import { apiAuthKey, apiAuthNostr, apiAuthKeyOrNostr, apiNostrEvent, apiNostrFinish } from "./_apiauth.js";
import { apiCheckNesting } from "./_apichat.js";
import { apiAuthPaid, apiAuthKeyOrSigned, apiL402Finish, apiL402Failed, apiL402Limit } from "./_apil402.js";
import { apiHistoryNudge } from "./_apibill.js";

export const API_BASE_PATH = "/api/v1";

const AUTH = { key: apiAuthKey, nostr: apiAuthNostr, "key-or-nostr": apiAuthKeyOrNostr, paid: apiAuthPaid, "key-or-signed": apiAuthKeyOrSigned };

function anonymous(request) {
  const h = request.headers;
  return !String(h.get("Authorization") || "").trim() && !String(h.get("x-api-key") || "").trim() && !String(h.get("api-key") || "").trim();
}

function compile(path) {
  const names = [];
  const src = path.split("/").map((seg) => {
    const m = /^\{([a-z_]+)(\*?)\}$/i.exec(seg);
    if (!m) return seg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    names.push(m[1]);
    return m[2] ? "(.+)" : "([^/]+)";
  }).join("/");
  return { re: new RegExp("^" + src + "$"), names };
}

export class ApiRouter {
  constructor() {
    this.routes = [];
  }

  add(method, path, handler, opts) {
    const o = Object.assign({ auth: "key", format: "openai" }, opts || {});
    if (!o.body) o.body = method === "GET" || method === "DELETE" ? "none" : "json";
    o.spends = o.spends !== false;
    const c = compile(path);
    this.routes.push({ method: method.toUpperCase(), path, re: c.re, names: c.names, handler, opts: o });
    return this;
  }

  match(path) {
    const hits = [];
    for (const r of this.routes) {
      const m = r.re.exec(path);
      if (!m) continue;
      const params = {};
      let malformed = false;
      r.names.forEach((n, i) => {
        try { params[n] = decodeURIComponent(m[i + 1]); } catch (e) { params[n] = m[i + 1]; malformed = true; }
      });
      hits.push({ route: r, params, malformed });
    }
    return hits;
  }

  async handle(context) {
    const request = context.request;
    const env = context.env || {};
    const requestId = apiRequestId();
    botBtcPriceBind(env);
    const url = new URL(request.url);
    const method = request.method.toUpperCase();
    const waitUntil = (p) => {
      try { if (typeof context.waitUntil === "function") context.waitUntil(Promise.resolve(p).catch(() => { })); } catch (e) { }
    };
    let path = url.pathname.startsWith(API_BASE_PATH + "/") ? url.pathname.slice(API_BASE_PATH.length) : "";
    if (path.length > 1) path = path.replace(/\/+$/, "");
    const hits = path ? this.match(path) : [];
    const account = hits.some((h) => h.route.opts.auth === "nostr");
    if (method === "OPTIONS") {
      const pre = apiPreflightHeaders(request, account);
      return apiFinish(new Response(null, { status: 204 }), requestId, pre);
    }
    const signed = /^\s*Nostr\s/i.test(request.headers.get("Authorization") || "") && hits.some((h) => h.route.opts.auth === "key-or-nostr");
    const cors = apiCorsHeaders(request, account || signed);
    const pick = hits.find((h) => h.route.method === method) || (method === "HEAD" ? hits.find((h) => h.route.method === "GET") : null);
    let format = pick ? pick.route.opts.format : (hits[0] ? hits[0].route.opts.format : "openai");
    let api = null;
    try {
      if (!hits.length) {
        throw new ApiError(404, "not_found_error", "Unknown endpoint: " + method + " " + url.pathname + ". See https://nymbot.ai/docs/api/.", { code: "unknown_endpoint" });
      }
      if (!pick) {
        const allow = [...new Set(hits.map((h) => h.route.method))].concat(["OPTIONS"]).join(", ");
        throw new ApiError(405, "invalid_request_error", "Method " + method + " is not allowed on " + url.pathname + ". Allowed: " + allow + ".",
          { code: "method_not_allowed", headers: { Allow: allow } });
      }
      if (pick.malformed) {
        throw new ApiError(400, "invalid_request_error", "The request path holds a malformed percent-encoded escape.", { code: "invalid_request" });
      }
      const route = pick.route;
      api = { request, env, context, url, params: pick.params, requestId, route, waitUntil, auth: null, bodyHex: API_EMPTY_BODY_SHA256, raw: "", body: null };
      const kind = route.opts.auth;
      const anon = anonymous(request);
      if (kind === "none" || (kind === "paid" && anon)) {
        await apiIpRateLimit(api, "unauthIp", "requests from this address");
      }
      if (kind === "paid" && anon) await apiL402Limit(api);
      if (route.opts.body === "json" || route.opts.body === "multipart") apiRequireContentType(request, route.opts.body);
      if (route.opts.body === "multipart") {
        const declared = Number(request.headers.get("Content-Length"));
        const max = route.opts.maxBytes || API_MULTIPART_MAX_BYTES;
        if (Number.isFinite(declared) && declared > max) {
          throw new ApiError(413, "invalid_request_error", "The request body is larger than the " + Math.round(max / 1024 / 1024) + " MB this endpoint accepts.", { code: "payload_too_large" });
        }
      }
      const nostr = kind === "nostr" || (kind === "key-or-nostr" && /^\s*Nostr\s/i.test(request.headers.get("Authorization") || ""));
      const guard = async (step) => {
        try { return await step(); } catch (e) {
          if (e instanceof ApiError && e.status === 401 && !anon) {
            const limited = await apiAuthFailed(api);
            if (limited) throw limited;
          }
          throw e;
        }
      };
      if (kind !== "none" && !anon) await apiAuthFailGate(api);
      let event = null;
      if (nostr) event = await guard(() => apiNostrEvent(api));
      else if (AUTH[kind]) await guard(() => AUTH[kind](api));
      if (route.opts.body === "json") {
        const bytes = await apiReadBody(request, route.opts.maxBytes || (nostr ? API_NOSTR_MAX_BYTES : API_JSON_MAX_BYTES));
        if (nostr || (api.auth && api.auth.via === "l402")) api.bodyHex = bytesToHex(sha256(bytes));
        api.raw = new TextDecoder().decode(bytes);
      } else if (route.opts.body === "multipart" && api.request === request) {
        await apiBufferMultipart(api, route.opts.maxBytes || API_MULTIPART_MAX_BYTES, nostr);
      }
      if (event) await guard(() => apiNostrFinish(api, event));
      if (route.opts.body === "json") {
        if (!api.raw.trim()) api.body = {};
        else {
          try { api.body = JSON.parse(api.raw); } catch (e) {
            throw new ApiError(400, "invalid_request_error", "The request body is not valid JSON.", { code: "invalid_json" });
          }
          if (!api.body || typeof api.body !== "object" || Array.isArray(api.body)) {
            throw new ApiError(400, "invalid_request_error", "The request body must be a JSON object.", { code: "invalid_json" });
          }
          apiCheckNesting(api.body);
        }
      }
      api.sweep = apiHistoryNudge(api);
      let res = await route.handler(api);
      if (api.l402) res = await apiL402Finish(api, res);
      return apiFinish(res, requestId, cors);
    } catch (e) {
      let err = apiErrorFrom(e);
      if (api && api.l402) err = await apiL402Failed(api, err);
      return apiFinish(apiErrorResponse(err, format), requestId, cors);
    }
  }
}
