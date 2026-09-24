// Service worker that caches only the exact public asset bytes in PUBLIC_ASSETS, never personalized
// or authenticated responses. scripts/build_offline_assets.py regenerates that list;
// offline-registration.js registers the worker.

"use strict";

const CACHE_PREFIX = "astraldeep-public-offline-";
// BEGIN GENERATED PUBLIC ASSETS
const CACHE_NAME = CACHE_PREFIX + "a828aec1e17a6b895cffd0c7";
const PUBLIC_ASSETS = [
  {
    "path": "/static/offline.html",
    "type": "text/html",
    "bytes": 1087,
    "sha256": "3325519d7a38149518a6202d1b8bc7b8595268fbd64ac3b4dc21db0313b502b7"
  },
  {
    "path": "/static/offline.css",
    "type": "text/css",
    "bytes": 853,
    "sha256": "56fa79095aedd500d9783375bec6e89816f79266729a7953af092f210a7b2acb"
  },
  {
    "path": "/static/astral.css",
    "type": "text/css",
    "bytes": 115231,
    "sha256": "533f535d6b94779fa7ceb191365cb540dbf793fbc75e863b3c90862ebefe8e19"
  },
  {
    "path": "/static/fonts/open-sans-latin.woff2",
    "type": "font/woff2",
    "bytes": 48320,
    "sha256": "d8e4fe0452aa2076429a9bb5d8757d00a994dd95986cf950e9a1a371b9a072a0"
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
  // Rebuilt headers only — never copy response's original headers/cookies
  return new Response(bytes, { headers: {
    "Content-Type": asset.type,
    "Cache-Control": "public, max-age=0, must-revalidate",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  } });
}

async function installPublicAssets() {
  const responses = await Promise.all(PUBLIC_ASSETS.map(fetchPublicAsset));
  const cache = await caches.open(CACHE_NAME);
  await Promise.all(PUBLIC_ASSETS.map((asset, index) =>
    cache.put(new URL(asset.path, ORIGIN).href, responses[index])));
  await self.skipWaiting();
}

async function activatePublicAssets() {
  const names = await caches.keys();
  await Promise.all(names.filter(name => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
    .map(name => caches.delete(name)));
  await self.clients.claim();
}

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
