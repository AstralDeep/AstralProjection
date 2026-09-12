// Isolated worker VM: synthetic public bytes only, no user browser or credentials.
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import vm from "node:vm";

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const worker = await readFile(resolve(STATIC, "service-worker.js"), "utf8");
const registration = await readFile(resolve(STATIC, "offline-registration.js"), "utf8");
const ORIGIN = "https://astral.example";
const assets = JSON.parse(worker.match(/const PUBLIC_ASSETS = (\[[\s\S]*?\]);/)[1]);
const bodies = new Map(await Promise.all(assets.map(async asset =>
  [asset.path, await readFile(resolve(STATIC, asset.path.slice(8)))])));

function responseFor(asset, overrides = {}) {
  const response = new Response(overrides.body ?? bodies.get(asset.path), {
    status: overrides.status ?? 200,
    headers: { "Content-Type": asset.type, "Cache-Control": "no-cache",
      "X-Private-Metadata": "must-not-retain", ...overrides.headers },
  });
  Object.defineProperties(response, {
    type: { value: overrides.type ?? "basic" },
    url: { value: overrides.url ?? ORIGIN + asset.path },
    redirected: { value: overrides.redirected ?? false },
    ...(overrides.noBody ? { body: { value: null } } : {}),
  });
  return response;
}

function harness(overrideFetch) {
  const stores = new Map();
  const listeners = {};
  const fetches = [];
  let skipped = false;
  let claimed = false;
  const caches = {
    async open(name) {
      if (!stores.has(name)) stores.set(name, new Map());
      const store = stores.get(name);
      return {
        async match(url) { return store.get(url)?.clone(); },
        async put(url, response) { store.set(url, response.clone()); },
        async delete(url) { return store.delete(url); },
      };
    },
    async keys() { return [...stores.keys()]; },
    async delete(name) { return stores.delete(name); },
  };
  const context = vm.createContext({
    URL, Response, Uint8Array, crypto: webcrypto, caches,
    self: { location: { origin: ORIGIN },
      addEventListener(type, callback) { listeners[type] = callback; },
      async skipWaiting() { skipped = true; },
      clients: { async claim() { claimed = true; } },
    },
    async fetch(input, options) {
      fetches.push({ input, options });
      if (overrideFetch) return overrideFetch(input, options);
      return responseFor(assets.find(asset => input === ORIGIN + asset.path));
    },
  });
  vm.runInContext(worker, context, { filename: pathToFileURL(resolve(STATIC, "service-worker.js")).href });
  return {
    context, stores, caches, fetches,
    get skipped() { return skipped; },
    get claimed() { return claimed; },
    get cacheName() { return vm.runInContext("CACHE_NAME", context); },
    async event(type) {
      let pending;
      listeners[type]({ waitUntil(value) { pending = value; } });
      return pending;
    },
    fetch(path, overrides = {}) {
      let response;
      const request = { url: new URL(path, ORIGIN).href, method: "GET", mode: "cors",
        headers: new Headers(), ...overrides };
      listeners.fetch({ request, respondWith(value) { response = value; } });
      return response;
    },
  };
}

test("install caches only verified public bytes anonymously, with no private metadata", async () => {
  const h = harness();
  await h.event("install");
  assert.equal(h.skipped, true);
  assert.equal(h.stores.size, 1);
  assert.deepEqual([...h.stores.get(h.cacheName).keys()], assets.map(asset => ORIGIN + asset.path));
  for (const { input, options } of h.fetches) {
    assert.ok(assets.some(asset => input === ORIGIN + asset.path));
    assert.equal(options.credentials, "omit");
    assert.equal(options.redirect, "error");
    assert.equal(options.cache, "no-store");
  }
  for (const response of h.stores.get(h.cacheName).values()) {
    assert.equal(response.headers.has("X-Private-Metadata"), false);
    assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  }
});

for (const [name, changes] of Object.entries({
  "HTTP refusal": { status: 401 }, "server failure": { status: 500 },
  "opaque response": { type: "opaque" }, "CORS response": { type: "cors" },
  redirect: { redirected: true }, "wrong URL": { url: ORIGIN + "/" },
  "wrong MIME": { headers: { "Content-Type": "application/json" } },
  "private metadata": { headers: { "Cache-Control": 'max-age=0, private="Set-Cookie"' } },
  "no-store metadata": { headers: { "Cache-Control": "no-store" } },
  "missing body": { noBody: true }, "short body": { body: "private" },
})) {
  test(`failed install refuses ${name} and never activates or writes a cache`, async () => {
    const h = harness(input => {
      const asset = assets.find(item => input === ORIGIN + item.path);
      return responseFor(asset, asset === assets[0] ? changes : {});
    });
    await assert.rejects(h.event("install"));
    assert.equal(h.skipped, false);
    assert.equal(h.stores.size, 0);
  });
}

for (const extra of [0, 1]) {
  test(`same-size changed bytes and oversized assets cannot enter the cache (${extra})`, async () => {
    const h = harness(input => {
      const asset = assets.find(item => input === ORIGIN + item.path);
      return responseFor(asset, asset === assets[0] ? { body: Buffer.alloc(asset.bytes + extra) } : {});
    });
    await assert.rejects(h.event("install"));
    assert.equal(h.stores.size, 0);
  });
}

test("activation removes only old caches in this public namespace", async () => {
  const h = harness();
  await h.event("install");
  h.stores.set("astraldeep-public-offline-old", new Map());
  h.stores.set("unrelated-origin-cache", new Map());
  await h.event("activate");
  assert.equal(h.claimed, true);
  assert.deepEqual([...h.stores.keys()], [h.cacheName, "unrelated-origin-cache"]);
});

test("static hit is cached, and eviction can refill only the fixed public entry", async () => {
  const h = harness();
  await h.event("install");
  const before = h.fetches.length;
  await h.fetch(assets[0].path);
  assert.equal(h.fetches.length, before);
  h.stores.get(h.cacheName).delete(ORIGIN + assets[0].path);
  await h.fetch(assets[0].path);
  assert.equal(h.fetches.length, before + 1);
  assert.equal(h.stores.get(h.cacheName).size, assets.length);
});

test("corrupt or accidentally private cache bytes are discarded before anonymous refill", async () => {
  const h = harness();
  await h.event("install");
  h.stores.get(h.cacheName).set(ORIGIN + assets[0].path,
    new Response("synthetic private data", { headers: { "Content-Type": "text/html" } }));
  const response = await h.fetch(assets[0].path);
  assert.equal(await response.text(), bodies.get(assets[0].path).toString());
  assert.equal(h.fetches.at(-1).options.credentials, "omit");
  assert.equal(h.stores.get(h.cacheName).size, assets.length);
});

test("offline cache poisoning fails closed when verified public bytes cannot be fetched", async () => {
  const h = harness(() => { throw new Error("offline"); });
  const cache = await h.caches.open(h.cacheName);
  await cache.put(ORIGIN + assets[0].path, new Response("private synthetic data"));
  await assert.rejects(h.fetch("/", { mode: "navigate" }), /offline/);
  assert.equal(h.stores.get(h.cacheName).size, 0);
});

for (const path of ["/auth/login", "/auth/callback?code=private", "/api/chats", "/attachments/1",
  "/static/client.js", "/static/offline.html?owner=private", "/?state=private", "/#private",
  "https://other.example/static/offline.html", "/static/unknown.css", "/ws"]) {
  test(`does not intercept excluded path ${path}`, () => {
    const h = harness();
    assert.equal(h.fetch(path, { mode: "navigate" }), undefined);
    assert.equal(h.fetches.length, 0);
    assert.equal(h.stores.size, 0);
  });
}

for (const overrides of [
  { method: "POST" }, { method: "HEAD" },
  { headers: new Headers({ Authorization: "synthetic" }) },
  { headers: new Headers({ Range: "bytes=0-1" }) },
]) {
  test(`excluded method/headers ${JSON.stringify(overrides)} bypass the worker`, () => {
    const h = harness();
    assert.equal(h.fetch(assets[0].path, overrides), undefined);
  });
}

for (const status of [200, 302, 401, 403, 500]) {
  test(`root status ${status} is returned without caching or replacing auth/errors`, async () => {
    const expected = new Response("synthetic private shell", { status });
    const h = harness(() => expected);
    assert.equal(await h.fetch("/", { mode: "navigate" }), expected);
    assert.equal(h.stores.size, 0);
    assert.equal(h.fetches[0].options.cache, "no-store");
    assert.equal(h.fetch("/"), undefined);
  });
}

test("offline root receives only public disconnected HTML; empty cache preserves failure", async () => {
  const h = harness(input => {
    if (typeof input !== "string") throw new Error("network unavailable");
    return responseFor(assets.find(asset => input === ORIGIN + asset.path));
  });
  // No cached fallback and a failed public fetch preserve the original root error.
  const empty = harness(() => { throw new Error("network unavailable"); });
  await assert.rejects(empty.fetch("/", { mode: "navigate" }), /network unavailable/);
  await h.event("install");
  const fallback = await h.fetch("/", { mode: "navigate" });
  assert.match(await fallback.text(), /You're offline/);
  assert.equal(h.stores.get(h.cacheName).has(ORIGIN + "/"), false);
  h.stores.get(h.cacheName).set(ORIGIN + assets[0].path,
    new Response("synthetic private data", { headers: { "Content-Type": "text/html" } }));
  const safe = await h.fetch("/", { mode: "navigate" });
  assert.match(await safe.text(), /You're offline/);
});

test("registration is optional, uses stable worker URL and bypasses HTTP cache", async () => {
  for (const [secure, supported] of [[false, true], [true, false], [true, true]]) {
    const calls = [], warnings = [];
    vm.runInNewContext(registration, {
      window: { isSecureContext: secure },
      navigator: supported ? { serviceWorker: { register(...args) {
        calls.push(args); return Promise.reject(new Error("private failure detail"));
      } } } : {}, console: { warn(message) { warnings.push(message); } },
    }, { filename: pathToFileURL(resolve(STATIC, "offline-registration.js")).href });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls.length, secure && supported ? 1 : 0);
    if (calls.length) {
      assert.equal(calls[0][0], "/static/service-worker.js");
      assert.equal(calls[0][1].scope, "/");
      assert.equal(calls[0][1].updateViaCache, "none");
      assert.deepEqual(warnings, ["AstralDeep offline page could not be enabled."]);
    }
  }
});
