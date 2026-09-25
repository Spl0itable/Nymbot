const SANDBOX_PATHS = new Set(["/app/sandbox", "/app/sandbox.html", "/app/sandbox-worker.js"]);

export function sandboxPolicy(origin) {
  const o = String(origin || "").replace(/\/+$/, "");
  const scripts = [
    o + "/app/js/sandbox.js",
    o + "/app/js/pdftext.js",
    o + "/app/sandbox-worker.js",
    o + "/app/js/vendor/pdfjs/",
    o + "/pyodide/"
  ].join(" ");
  const reads = [o + "/pyodide/", o + "/app/js/vendor/pdfjs/"].join(" ");
  return [
    "default-src 'none'",
    "script-src " + scripts + " blob: 'wasm-unsafe-eval'",
    "connect-src " + reads,
    "worker-src " + scripts + " blob:",
    "img-src data: blob:",
    "style-src 'none'",
    "font-src 'none'",
    "media-src 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    "child-src 'none'",
    "manifest-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'"
  ].join("; ");
}

export function isSandboxPath(pathname) {
  return SANDBOX_PATHS.has(pathname);
}

const PREVIEW_PATHS = new Set(["/app/preview", "/app/preview.html"]);

export function isPreviewPath(pathname) {
  return PREVIEW_PATHS.has(pathname);
}

export function previewPolicy(origin) {
  const o = String(origin || "").replace(/\/+$/, "");
  const open = "https: data: blob:";
  return [
    "default-src 'none'",
    "script-src " + o + "/app/js/preview.js 'unsafe-inline' 'unsafe-eval' " + open,
    "style-src 'unsafe-inline' " + open,
    "img-src " + open,
    "font-src " + open,
    "media-src " + open,
    "connect-src " + open,
    "worker-src blob: data:",
    "child-src blob:",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri https:",
    "form-action 'none'",
    "frame-ancestors 'self'"
  ].join("; ");
}

export async function onRequest(context) {
  const response = await context.next();
  const url = new URL(context.request.url);
  if (isPreviewPath(url.pathname)) {
    const page = new Response(response.body, response);
    page.headers.set("Content-Security-Policy", previewPolicy(url.origin));
    page.headers.set("Referrer-Policy", "no-referrer");
    page.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), idle-detection=()");
    page.headers.set("X-Robots-Tag", "noindex");
    page.headers.delete("X-Frame-Options");
    return page;
  }
  if (!isSandboxPath(url.pathname)) return response;
  const out = new Response(response.body, response);
  out.headers.set("Content-Security-Policy", sandboxPolicy(url.origin));
  out.headers.set("Referrer-Policy", "no-referrer");
  out.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), idle-detection=()");
  out.headers.set("X-Robots-Tag", "noindex");
  out.headers.delete("X-Frame-Options");
  if (url.pathname === "/app/sandbox-worker.js") out.headers.set("Cross-Origin-Resource-Policy", "cross-origin");
  return out;
}
