export function catalogHash(strings) {
  const list = [...new Set(strings.map(String))].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(list.join('\n'))) {
    h = (h ^ b) >>> 0;
    h = (h * 0x193 + (h & 0xff) * 0x1000000) % 0x100000000;
  }
  return h.toString(16).padStart(8, '0');
}

export function cacheKey(hash, build) {
  return 'c' + hash + (build == null ? '' : '.b' + build);
}
