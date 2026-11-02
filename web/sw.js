// Keeps the app's files on the device so it opens instantly, even with no
// signal. The app never updates by itself: the refresh button sends
// 'update-app', and only then is a newer deployed version downloaded and
// switched to. Card data isn't cached here: it comes from Firestore and the
// app's own saved copy.
//
// The CI build writes the deployed commit to build_id.txt. It also stamps it
// below, which only makes each deploy's worker byte-different so phones get
// this file's latest code; that doesn't change which app files are served.

const BUILD = '__BUILD_ID__';
const META_CACHE = 'rewards-meta';

// The Flutter engine, Firebase SDK and fonts live at versioned URLs whose
// contents never change, so they are kept across versions.
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
      // Only the very first install downloads the app; later installs are
      // just newer code for this worker and keep serving the same version.
      if (!(await currentVersion())) {
        await downloadLatest().catch(() => {});
      }
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      await deleteOtherAppCaches();
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
    event.respondWith(serveApp(scope.href, request));
  } else if (isAppFile(url)) {
    event.respondWith(serveApp(url.href, request));
  } else if (isCdnFile(url)) {
    event.respondWith(cacheFirst(CDN_CACHE, url.href, request));
  }
  // Everything else, including Firestore and sign-in, goes to the network.
});

self.addEventListener('message', (event) => {
  if (event.data?.type === 'update-app') {
    // From the refresh button: replies whether a newer version was installed.
    const reply = event.ports[0];
    event.waitUntil(
      downloadLatest().then(
        (updated) => reply?.postMessage({ updated }),
        (error) => reply?.postMessage({ updated: false, error: String(error) }),
      ),
    );
  } else if (event.data?.type === 'cache-loaded') {
    // On a first visit the page loads before this worker is in control, so
    // it sends the URLs it already loaded to be kept for next time.
    event.waitUntil(keepLoaded(event.data.urls));
  }
});

// The app version being served: {build, cache}, or null before the first
// download. Saved in its own cache so it survives the worker restarting.
let current;

async function currentVersion() {
  if (current === undefined) {
    const saved = await (await caches.open(META_CACHE)).match('current');
    current = saved ? await saved.json() : null;
  }
  return current;
}

async function currentCache() {
  return (await currentVersion())?.cache ?? 'rewards-app-unversioned';
}

// Downloads the deployed version, if it isn't the one being served, and
// switches to it. Returns whether it switched.
async function downloadLatest() {
  const latest = await deployedBuild();
  const serving = await currentVersion();
  if (serving && serving.build === latest) {
    return false;
  }

  const cacheName = `rewards-app-${latest}`;
  const cache = await caches.open(cacheName);
  try {
    // Skip the HTTP cache so every file comes from the same deploy.
    await Promise.all(
      APP_SHELL.map(async (path) => {
        const url = new URL(path, scope);
        const response = await fetch(url, { cache: 'no-cache' });
        if (!response.ok) {
          throw new Error(`Couldn't download ${path} (${response.status})`);
        }
        await cache.put(url, response);
      }),
    );
  } catch (error) {
    await caches.delete(cacheName);
    throw error;
  }

  current = { build: latest, cache: cacheName };
  await (await caches.open(META_CACHE)).put(
    'current',
    new Response(JSON.stringify(current)),
  );
  await deleteOtherAppCaches();
  return true;
}

async function deployedBuild() {
  const response = await fetch(new URL('build_id.txt', scope), {
    cache: 'no-store',
  });
  // Local builds have no build_id.txt.
  return response.ok ? (await response.text()).trim() : 'unversioned';
}

async function deleteOtherAppCaches() {
  const keep = await currentCache();
  const names = await caches.keys();
  await Promise.all(
    names
      .filter((name) => name.startsWith('rewards-app-') && name !== keep)
      .map((name) => caches.delete(name)),
  );
}

function isAppFile(url) {
  if (!url.href.startsWith(scope.href)) {
    return false;
  }
  const file = url.pathname.split('/').pop();
  return file !== 'sw.js' && file !== 'build_id.txt';
}

function isCdnFile(url) {
  return CDN_PATHS.some((path) => url.href.startsWith(path));
}

async function serveApp(key, request) {
  return cacheFirst(await currentCache(), key, request);
}

async function keepLoaded(urls) {
  const appCache = await currentCache();
  await Promise.all(
    urls.map(async (href) => {
      const url = new URL(href);
      const cacheName = isAppFile(url)
        ? appCache
        : isCdnFile(url)
          ? CDN_CACHE
          : null;
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
  );
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
