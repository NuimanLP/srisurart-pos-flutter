// Service Worker for Srisurart Autopart POS
// Offline-first PWA shell precache and lifecycle management
// Invariant: NEVER call self.skipWaiting() automatically on install.
// Cache updates must be confirmed by the cashier to prevent reloads mid-sale.

const CACHE_NAME = 'srisurart-pos-v1';

const PRECACHE_ASSETS = [
  './',
  'index.html',
  'manifest.json',
  'favicon.png',
  'sqlite3.wasm',
  'drift_worker.js',
  'flutter_bootstrap.js',
  'main.dart.js',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'assets/fonts/Sarabun-Regular.ttf',
  'assets/fonts/Sarabun-Medium.ttf',
  'assets/fonts/Sarabun-SemiBold.ttf',
  'assets/fonts/Sarabun-Bold.ttf',
  'assets/fonts/BarlowCondensed-Bold.ttf',
  'assets/FontManifest.json',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.json',
];

// Install: precache shell assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      // Precache assets individually so non-existent optional/build assets do not break SW install
      await Promise.allSettled(
        PRECACHE_ASSETS.map(async (url) => {
          try {
            await cache.add(url);
          } catch (err) {
            console.warn('[SW] Optional precache skipped or failed for:', url, err);
          }
        })
      );
      console.log('[SW] Precache completed for', CACHE_NAME);
    })
  );

  // 🔴 STRICT INVARIANT (08 §4 item 6):
  // Do NOT call self.skipWaiting() here!
  // Mid-sale cashiers must never have the tab reloaded out from under them.
});

// Activate: clean up old versioned caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames
          .filter((name) => name.startsWith('srisurart-pos-') && name !== CACHE_NAME)
          .map((name) => {
            console.log('[SW] Deleting obsolete cache:', name);
            return caches.delete(name);
          })
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch: cache-first for shell assets, strictly bypass API requests
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') {
    return;
  }

  const url = new URL(event.request.url);

  // Strictly do NOT intercept or cache API endpoints
  if (url.pathname.startsWith('/api/') || !url.protocol.startsWith('http')) {
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      if (cachedResponse) {
        return cachedResponse;
      }

      return fetch(event.request)
        .then((networkResponse) => {
          // Only cache valid basic same-origin 200 responses
          if (
            networkResponse &&
            networkResponse.status === 200 &&
            (networkResponse.type === 'basic' || networkResponse.type === 'cors')
          ) {
            const responseToCache = networkResponse.clone();
            caches.open(CACHE_NAME).then((cache) => {
              cache.put(event.request, responseToCache);
            });
          }
          return networkResponse;
        })
        .catch(() => {
          // If offline and navigating to a page, serve the shell index.html
          if (event.request.mode === 'navigate') {
            return caches.match('./') || caches.match('index.html');
          }
        });
    })
  );
});

// Explicit update confirmation from client
self.addEventListener('message', (event) => {
  if (!event.data) return;

  const isSkipWaiting =
    event.data === 'SKIP_WAITING' ||
    event.data.action === 'skipWaiting' ||
    event.data.type === 'SKIP_WAITING';

  if (isSkipWaiting) {
    console.log('[SW] Received explicit skipWaiting confirmation from cashier.');
    self.skipWaiting();
  }
});
