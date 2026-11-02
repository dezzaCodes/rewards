// Keeps the app's files on the device so it opens quickly, even with a weak
// signal or none at all. Card data isn't cached here: it comes from
// Firestore and the app's own saved copy.
//
// The CI build replaces __BUILD_ID__ with the commit and writes the same id
// to build_id.txt, so every deploy is a new service worker with its own
// cache. Each launch checks build_id.txt first: if a newer version is out,
// that launch loads it from the network; otherwise it opens from the cache.

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

// How long a launch waits to find out whether there's a newer version.
const UPDATE_CHECK_TIMEOUT_MS = 1500;

// Until this time, app files come from the network because this launch is
// loading a newer version than the one cached.
let loadFromNetworkUntil = 0;

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
    event.respondWith(openApp(request));
  } else if (Date.now() < loadFromNetworkUntil && cacheFor(url) === APP_CACHE) {
    event.respondWith(networkFirst(APP_CACHE, url.href, request));
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

async function openApp(request) {
  if ((await latestBuild()) !== BUILD) {
    // A newer version is out (or this one was never cached): load it all
    // from the network this time. Its own service worker installs meanwhile
    // and serves it from the cache on later launches.
    loadFromNetworkUntil = Date.now() + 30000;
    return networkFirst(APP_CACHE, scope.href, request);
  }

  // Every page of the app is the same page; ignore ?join= links etc.
  return cacheFirst(APP_CACHE, scope.href, request);
}

// The deployed version, or this one when it can't be checked in time (for
// example with no signal), so the cached app opens.
async function latestBuild() {
  try {
    const response = await fetch(new URL('build_id.txt', scope), {
      cache: 'no-store',
      signal: AbortSignal.timeout(UPDATE_CHECK_TIMEOUT_MS),
    });
    return response.ok ? (await response.text()).trim() : BUILD;
  } catch (_) {
    return BUILD;
  }
}

async function networkFirst(cacheName, key, request) {
  try {
    // Skip the HTTP cache so every file comes from the same deploy.
    return await fetch(request.mode === 'navigate' ? key : request.url, {
      cache: 'no-cache',
    });
  } catch (_) {
    return cacheFirst(cacheName, key, request);
  }
}

function cacheFor(url) {
  if (url.href.startsWith(scope.href)) {
    const file = url.pathname.split('/').pop();
    return file === 'sw.js' || file === 'build_id.txt' ? null : APP_CACHE;
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
