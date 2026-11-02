// Keeps the app's files on the device so it opens instantly, even with a
// weak signal or none at all. Card data isn't cached here: it comes from
// Firestore and the app's own saved copy.
//
// The CI build replaces __BUILD_ID__ with the commit, so every deploy is a new
// service worker with its own cache. A new version downloads in the
// background and is used from the next launch.

const BUILD = '__BUILD_ID__';
const APP_CACHE = `rewards-app-${BUILD}`;

// The Flutter engine, Firebase SDK and fonts live at versioned URLs whose
// contents never change, so they are kept across deploys.
const CDN_CACHE = 'rewards-cdn-v1';
const CDN_PATHS = [
  'https://www.gstatic.com/flutter-canvaskit/',
  'https://www.gstatic.com/firebasejs/',
  'https://fonts.gstatic.com/',
];

const APP_SHELL = [
  './',
  'flutter_bootstrap.js',
  'main.dart.js',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png',
  'assets/FontManifest.json',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
];

const scope = new URL('./', self.location);

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(APP_CACHE);
      // Bypass the HTTP cache so every file comes from this same deploy.
      await Promise.all(
        APP_SHELL.map(async (path) => {
          try {
            const response = await fetch(path, { cache: 'no-cache' });
            if (response.ok) {
              await cache.put(new URL(path, scope), response);
            }
          } catch (_) {
            // Fetched again on first use instead.
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => name.startsWith('rewards-app-') && name !== APP_CACHE)
          .map((name) => caches.delete(name)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') {
    return;
  }

  const url = new URL(request.url);
  if (request.mode === 'navigate' && url.href.startsWith(scope.href)) {
    // Every page of the app is the same page; ignore ?join= links etc.
    event.respondWith(cacheFirst(APP_CACHE, scope.href, request));
  } else {
    const cacheName = cacheFor(url);
    if (cacheName) {
      event.respondWith(cacheFirst(cacheName, url.href, request));
    }
  }
  // Everything else, including Firestore and sign-in, goes to the network.
});

// On a first visit the page loads before this worker is in control, so it
// sends the URLs it already loaded to be kept for next time.
self.addEventListener('message', (event) => {
  const urls = event.data?.type === 'cache-loaded' ? event.data.urls : [];
  event.waitUntil(
    Promise.all(
      urls.map(async (href) => {
        const cacheName = cacheFor(new URL(href));
        if (!cacheName) {
          return;
        }

        const cache = await caches.open(cacheName);
        if (await cache.match(href)) {
          return;
        }
        try {
          // CORS, so the copy can answer any later request for this URL.
          const response = await fetch(href, { mode: 'cors' });
          if (response.ok) {
            await cache.put(href, response);
          }
        } catch (_) {
          // Kept on a later visit instead.
        }
      }),
    ),
  );
});

function cacheFor(url) {
  if (url.href.startsWith(scope.href)) {
    return url.pathname.endsWith('/sw.js') ? null : APP_CACHE;
  }
  return CDN_PATHS.some((path) => url.href.startsWith(path)) ? CDN_CACHE : null;
}

// A cross-origin <script> loaded without CORS gets an opaque response. That
// can't answer a CORS request (such as a module import) for the same URL, so
// it is kept under its own key and only used for no-CORS requests.
function opaqueKey(href) {
  return `${href}${href.includes('?') ? '&' : '?'}sw-opaque=1`;
}

async function cacheFirst(cacheName, key, request) {
  const cache = await caches.open(cacheName);
  const cached =
    (await cache.match(key)) ??
    (request.mode === 'no-cors' ? await cache.match(opaqueKey(key)) : undefined);
  if (cached) {
    return cached;
  }

  // For pages, fetch the plain app URL: Safari rejects a page served from a
  // cached redirect.
  const response = await fetch(request.mode === 'navigate' ? key : request);
  if (response.ok) {
    cache.put(key, response.clone());
  } else if (response.type === 'opaque') {
    cache.put(opaqueKey(key), response.clone());
  }
  return response;
}
