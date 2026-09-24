export const PYODIDE_VERSION = '0.27.7';

const UPSTREAM = `https://cdn.jsdelivr.net/pyodide/v${PYODIDE_VERSION}/full/`;
const PREFIX = `v${PYODIDE_VERSION}/full/`;
const YEAR = 31536000;

const CORE = [
  'pyodide.js',
  'pyodide.asm.js',
  'pyodide.asm.wasm',
  'python_stdlib.zip',
  'pyodide-lock.json'
];

const PACKAGES = [
  'beautifulsoup4-4.12.3-py3-none-any.whl',
  'contourpy-1.3.0-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'cycler-0.12.1-py3-none-any.whl',
  'decorator-5.1.1-py3-none-any.whl',
  'fonttools-4.51.0-py3-none-any.whl',
  'joblib-1.4.0-py3-none-any.whl',
  'kiwisolver-1.4.5-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'matplotlib-3.8.4-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'matplotlib_pyodide-0.2.3-py3-none-any.whl',
  'mpmath-1.3.0-py3-none-any.whl',
  'networkx-3.4.2-py3-none-any.whl',
  'numpy-2.0.2-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'openblas-0.3.26.zip',
  'packaging-24.2-py3-none-any.whl',
  'pandas-2.2.3-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'patsy-0.5.6-py2.py3-none-any.whl',
  'pillow-10.2.0-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'pyparsing-3.1.2-py3-none-any.whl',
  'python_dateutil-2.9.0.post0-py2.py3-none-any.whl',
  'pytz-2024.1-py2.py3-none-any.whl',
  'pyyaml-6.0.2-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'regex-2024.9.11-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'scikit_learn-1.6.1-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'scipy-1.14.1-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'setuptools-69.5.1-py3-none-any.whl',
  'six-1.16.0-py2.py3-none-any.whl',
  'soupsieve-2.5-py3-none-any.whl',
  'sqlite3-1.0.0-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'statsmodels-0.14.4-cp312-cp312-pyodide_2024_0_wasm32.whl',
  'sympy-1.13.3-py3-none-any.whl',
  'threadpoolctl-3.5.0-py3-none-any.whl',
  'xlrd-2.0.1-py2.py3-none-any.whl'
];

const ALLOWED = new Set(CORE.concat(PACKAGES));

const TYPES = {
  js: 'text/javascript; charset=utf-8',
  wasm: 'application/wasm',
  json: 'application/json; charset=utf-8',
  zip: 'application/zip',
  whl: 'application/zip'
};

export function pyodideFile(pathname) {
  const p = String(pathname || '');
  if (!p.startsWith('/pyodide/')) return null;
  const rest = p.slice('/pyodide/'.length);
  if (!rest.startsWith(PREFIX)) return null;
  const name = rest.slice(PREFIX.length);
  if (!name || name.includes('/') || name.includes('\\') || name.includes('%')) return null;
  return ALLOWED.has(name) ? name : null;
}

function served(status, body, type, extra) {
  const headers = new Headers({
    'Content-Type': type,
    'Access-Control-Allow-Origin': '*',
    'Cross-Origin-Resource-Policy': 'cross-origin',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer'
  });
  for (const [k, v] of Object.entries(extra || {})) headers.set(k, v);
  return new Response(body, { status, headers });
}

function refuse(status, message) {
  return served(status, message, 'text/plain; charset=utf-8', { 'Cache-Control': 'no-store' });
}

export async function onRequest(context) {
  const request = context.request;
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return refuse(405, 'method not allowed');
  }
  const url = new URL(request.url);
  if (url.search) return refuse(404, 'not found');
  const name = pyodideFile(url.pathname);
  if (!name) return refuse(404, 'not found');
  const ext = name.split('.').pop();
  const cache = typeof caches !== 'undefined' && caches.default ? caches.default : null;
  const key = new Request(`${url.origin}/pyodide/${PREFIX}${name}`, { method: 'GET' });
  if (cache) {
    const hit = await cache.match(key);
    if (hit) {
      return served(200, request.method === 'HEAD' ? null : hit.body, TYPES[ext], {
        'Cache-Control': `public, max-age=${YEAR}, immutable`,
        'X-Edge-Cache': 'HIT'
      });
    }
  }
  let upstream;
  try {
    upstream = await fetch(UPSTREAM + name, {
      headers: { 'Accept': '*/*' },
      redirect: 'error',
      cf: { cacheEverything: true, cacheTtl: YEAR }
    });
  } catch (_) {
    return refuse(502, 'upstream unavailable');
  }
  if (!upstream.ok || !upstream.body) return refuse(502, 'upstream unavailable');
  const resp = served(200, upstream.body, TYPES[ext], {
    'Cache-Control': `public, max-age=${YEAR}, immutable`,
    'X-Edge-Cache': 'MISS'
  });
  if (cache) {
    const op = cache.put(key, resp.clone());
    if (context.waitUntil) context.waitUntil(op.catch(() => {}));
  }
  if (request.method === 'HEAD') return served(200, null, TYPES[ext], { 'Cache-Control': `public, max-age=${YEAR}, immutable` });
  return resp;
}
