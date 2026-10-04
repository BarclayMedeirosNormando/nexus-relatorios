/* Nexus Relatórios - service worker próprio.
 *
 * Por que existe: o Flutter atual publica um service worker "vazio" (que se
 * desregistra). Sem service worker o app NÃO abre sem internet. Este arquivo:
 *  - guarda os arquivos do app no aparelho (cache);
 *  - com internet: busca sempre a versão mais nova (rede primeiro);
 *  - sem internet ou sinal ruim (5 s): abre a cópia guardada.
 * Só mexe em GET do mesmo endereço do app. Chamadas ao Apps Script (outro
 * domínio) passam direto, sem cache.
 */
const CACHE = 'nexus-shell-v1';
const CORE = [
  './', 'index.html', 'manifest.json', 'flutter_bootstrap.js', 'flutter.js',
  'main.dart.js', 'favicon.png', 'icons/Icon-192.png', 'icons/Icon-512.png'
];
const NETWORK_TIMEOUT_MS = 5000;

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(CORE.map((u) =>
      cache.add(new Request(u, { cache: 'reload' })).catch(() => {})));
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter((n) => n.startsWith('nexus-shell-') && n !== CACHE)
      .map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

// A página avisa quais arquivos já carregou, para guardarmos todos (CanvasKit,
// fontes, imagens) e o app abrir 100% offline.
self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type !== 'cache-urls' || !Array.isArray(data.urls)) return;
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const u of data.urls) {
      try {
        const url = new URL(u, self.location.href);
        if (url.origin !== self.location.origin) continue;
        if (url.pathname.endsWith('nexus_sw.js')) continue;
        if (await cache.match(url.href)) continue;
        await cache.add(url.href);
      } catch (_) {}
    }
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.endsWith('nexus_sw.js')) return;
  event.respondWith(networkFirst(req));
});

async function networkFirst(req) {
  const cache = await caches.open(CACHE);
  const isNav = req.mode === 'navigate';

  const fromCache = async () =>
    (await cache.match(req.url)) ||
    (isNav ? (await cache.match(req.url, { ignoreSearch: true })) ||
             (await cache.match('./')) || (await cache.match('index.html'))
           : undefined);

  const fromNetwork = (async () => {
    const res = await fetch(req.url, { cache: 'no-cache' });
    if (res && res.status === 200) {
      cache.put(req.url, res.clone()).catch(() => {});
    }
    return res;
  })();

  try {
    return await Promise.race([
      fromNetwork,
      new Promise((resolve, reject) => setTimeout(async () => {
        const hit = await fromCache();
        hit ? resolve(hit) : reject(new Error('timeout'));
      }, NETWORK_TIMEOUT_MS)),
    ]);
  } catch (_) {
    try { return await fromNetwork; } catch (_) {}
    const hit = await fromCache();
    return hit || new Response('Sem conexão e sem cópia guardada.', {
      status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }
}
