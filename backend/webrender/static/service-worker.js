/* 088: only exact public package bytes may enter this worker's cache.
 * The personalized root document, API/auth responses, drafts, and results are
 * always excluded. Regenerate the block with scripts/build_offline_assets.py.
 */
"use strict";

const CACHE_PREFIX = "astraldeep-public-offline-";
// BEGIN GENERATED PUBLIC ASSETS
const CACHE_NAME = CACHE_PREFIX + "a75616fae4227a529327c5ec";
const PUBLIC_ASSETS = [
  {
    "path": "/static/offline.html",
    "type": "text/html",
    "bytes": 922,
    "sha256": "5e2869b72add93d993a4633bd34b27792f1f03308a3d53c389969f0c1ecfffc3"
  },
  {
    "path": "/static/offline.css",
    "type": "text/css",
    "bytes": 822,
    "sha256": "5978d277da2bae09d591bf8e3909f3961bbc835f5cb95d542c89b9fac585884f"
  },
  {
    "path": "/static/astral.css",
    "type": "text/css",
    "bytes": 56292,
    "sha256": "5a8977f8d823ac870a606a4168f600af82f5e0c9a5326a1e4707d542a86c48de"
  },
  {
    "path": "/static/fonts/inter-latin.woff2",
    "type": "font/woff2",
    "bytes": 48256,
    "sha256": "3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62"
  },
  {
    "path": "/static/fonts/jetbrains-mono-latin.woff2",
    "type": "font/woff2",
    "bytes": 21168,
    "sha256": "14425ba9c695763c1547f48a206b7aa60350a33ae23de09f0407877f3fcd89eb"
  },
  {
    "path": "/static/img/astra-fav.png",
    "type": "image/png",
    "bytes": 43816,
    "sha256": "c7ad520fb2cf7ee04953404bcada21e587a36f24a8919c5bf4e1bd9bdc4d879a"
  },
  {
    "path": "/static/manifest.webmanifest",
    "type": "application/manifest+json",
    "bytes": 386,
    "sha256": "2f39375c2e7e67807d5970f61480b154268820475859e7c009bc5f791fb8f38d"
  }
];
// END GENERATED PUBLIC ASSETS
const OFFLINE_PATH = "/static/offline.html";
const ORIGIN = self.location.origin;

/** Fetch a bounded public asset anonymously and verify its exact package bytes. */
async function fetchPublicAsset(asset) {
  const url = new URL(asset.path, ORIGIN).href;
  const response = await fetch(url, {
    credentials: "omit", redirect: "error", cache: "no-store",
  });
  if (response.type !== "basic" || response.redirected || response.url !== url) {
    throw new Error("Public offline asset origin refused.");
  }
  return verifiedPublicResponse(asset, response);
}

/** Validate cache hits too: only known public bytes may be displayed offline. */
async function verifiedPublicResponse(asset, response) {
  const contentType = (response.headers.get("Content-Type") || "").split(";")[0].trim();
  if (response.status !== 200 || contentType !== asset.type || !response.body ||
      /(?:^|,)\s*(?:private|no-store)\b/i.test(response.headers.get("Cache-Control") || "")) {
    throw new Error("Public offline asset refused.");
  }
  const reader = response.body.getReader();
  const bytes = new Uint8Array(asset.bytes);
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.byteLength > bytes.byteLength) {
        await reader.cancel();
        throw new Error("Public offline asset exceeds its package size.");
      }
      bytes.set(value, size);
      size += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
    .map(value => value.toString(16).padStart(2, "0")).join("");
  if (size !== asset.bytes || digest !== asset.sha256) {
    throw new Error("Public offline asset differs from its package.");
  }
  // Retain only public metadata, never response cookies or request headers.
  return new Response(bytes, { headers: {
    "Content-Type": asset.type,
    "Cache-Control": "public, max-age=0, must-revalidate",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  } });
}

/** A complete verified install precedes activation; a failed update stays inactive. */
async function installPublicAssets() {
  const responses = await Promise.all(PUBLIC_ASSETS.map(fetchPublicAsset));
  const cache = await caches.open(CACHE_NAME);
  await Promise.all(PUBLIC_ASSETS.map((asset, index) =>
    cache.put(new URL(asset.path, ORIGIN).href, responses[index])));
  await self.skipWaiting();
}

/** Retire only this worker's old public assets, preserving unrelated origin stores. */
async function activatePublicAssets() {
  const names = await caches.keys();
  await Promise.all(names.filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
    .map(name => caches.delete(name)));
  await self.clients.claim();
}

/** A fixed allowlist bounds cache growth even if the browser evicts an entry. */
async function publicAsset(asset) {
  const cache = await caches.open(CACHE_NAME);
  const url = new URL(asset.path, ORIGIN).href;
  const cached = await cache.match(url);
  if (cached) {
    try {
      return await verifiedPublicResponse(asset, cached);
    } catch {
      await cache.delete(url);
    }
  }
  const response = await fetchPublicAsset(asset);
  await cache.put(url, response.clone());
  return response;
}

/** Never persist the root response, and preserve all online redirects/errors. */
async function rootNavigation(request) {
  try {
    return await fetch(request, { cache: "no-store" });
  } catch (error) {
    try {
      return await publicAsset(PUBLIC_ASSETS.find(asset => asset.path === OFFLINE_PATH));
    } catch {
      throw error;
    }
  }
}

self.addEventListener("install", event => event.waitUntil(installPublicAssets()));
self.addEventListener("activate", event => event.waitUntil(activatePublicAssets()));
self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== ORIGIN || url.search || url.hash ||
      request.headers.has("Authorization") || request.headers.has("Range")) return;
  const asset = PUBLIC_ASSETS.find(candidate => candidate.path === url.pathname);
  if (asset) {
    event.respondWith(publicAsset(asset));
  } else if (request.mode === "navigate" && url.pathname === "/") {
    event.respondWith(rootNavigation(request));
  }
});
