// Real Chromium worker/cache/navigation checks on an isolated synthetic HTTP origin.
import { createServer } from "node:http";
import { once } from "node:events";
import { createConnection } from "node:net";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const STATIC = resolve(import.meta.dirname, "../../../backend/webrender/static");
const worker = await readFile(resolve(STATIC, "service-worker.js"), "utf8");
const assets = JSON.parse(worker.match(/const PUBLIC_ASSETS = (\[[\s\S]*?\]);/)[1]);
const routes = new Map(await Promise.all([...assets,
  { path: "/static/service-worker.js", type: "text/javascript" },
  { path: "/static/offline-registration.js", type: "text/javascript" },
].map(async asset => [asset.path, { ...asset,
  body: await readFile(resolve(STATIC, asset.path.slice(8))),
}])));
const PRIVATE = "synthetic-owner-private-shell-never-cache";

async function serverForTest() {
  const requests = [];
  let rootStatus = 200;
  const server = createServer((request, response) => {
    const path = new URL(request.url, "http://localhost").pathname;
    requests.push({ path, cookie: request.headers.cookie, destination: request.headers["sec-fetch-dest"] });
    const asset = routes.get(path);
    if (asset) {
      response.setHeader("Content-Type", asset.type);
      response.setHeader("Cache-Control", "no-cache");
      if (path === "/static/service-worker.js") {
        response.setHeader("Service-Worker-Allowed", "/");
        response.setHeader("Content-Security-Policy", "default-src 'none'; connect-src 'self'");
      }
      response.end(asset.body);
    } else if (path === "/") {
      response.statusCode = rootStatus;
      response.setHeader("Content-Type", "text/html");
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'");
      if (rootStatus === 302) response.setHeader("Location", "/auth/login");
      response.end(`<h1>${PRIVATE}</h1><script src="/static/offline-registration.js"></script>`);
    } else {
      response.statusCode = 401;
      response.setHeader("Cache-Control", "private, no-store");
      response.end(`${PRIVATE}:${path}`);
    }
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  return { origin: `http://127.0.0.1:${server.address().port}`, requests, httpServer: server,
    setRootStatus(value) { rootStatus = value; },
    close: () => new Promise(resolve => {
      server.close(resolve);
      // Browser preconnects can stay idle until the later page/context teardown.
      server.closeAllConnections();
    }),
  };
}

test("HTTP fixture teardown closes accepted idle preconnects", async () => {
  const server = await serverForTest();
  const accepted = once(server.httpServer, "connection");
  const connection = createConnection({ host: "127.0.0.1", port: Number(new URL(server.origin).port) });
  try {
    await Promise.all([accepted, once(connection, "connect")]);
    const closed = once(connection, "close");
    await server.close();
    await closed;
    expect(connection.destroyed).toBe(true);
  } finally {
    connection.destroy();
    await server.close();
  }
});

async function controlledPage(page, origin) {
  await page.goto(origin);
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller));
}

test("offline startup reveals only public help, uses anonymous bounded cache, and recovers", async ({ page, context }) => {
  const server = await serverForTest();
  try {
    await context.addCookies([{ name: "session", value: "synthetic-only", url: server.origin }]);
    await controlledPage(page, server.origin);
    await expect(page.getByRole("heading")).toHaveText(PRIVATE);
    const installed = server.requests.filter(request => assets.some(asset => asset.path === request.path));
    expect(installed.length).toBe(assets.length);
    expect(installed.every(request => !request.cookie)).toBe(true);
    const keys = await page.evaluate(async () => {
      const names = await caches.keys();
      return Promise.all(names.map(async name => ({ name,
        urls: (await (await caches.open(name)).keys()).map(request => request.url),
      })));
    });
    expect(keys).toHaveLength(1);
    expect(keys[0].urls.sort()).toEqual(assets.map(asset => server.origin + asset.path).sort());
    await context.setOffline(true);
    await page.reload();
    await expect(page.getByRole("heading", { name: "You're offline" })).toBeVisible();
    await expect(page.locator("body")).not.toContainText(PRIVATE);
    await page.setViewportSize({ width: 320, height: 700 });
    await page.evaluate(() => { document.documentElement.style.fontSize = "200%"; });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.keyboard.press("Tab");
    await expect(page.getByRole("link", { name: "Try again" })).toBeFocused();
    expect(await page.getByRole("link").evaluate(node => getComputedStyle(node).outlineWidth)).toBe("3px");
    expect(await page.evaluate(async () => {
      const results = await Promise.all(["/api/chats", "/auth/login", "/auth/callback?code=synthetic"].map(async path => {
        try { await fetch(path); return "unexpected response"; } catch { return "network failure"; }
      }));
      return results;
    })).toEqual(["network failure", "network failure", "network failure"]);
    await context.setOffline(false);
    await page.getByRole("link", { name: "Try again" }).click();
    await expect(page.getByRole("heading")).toHaveText(PRIVATE);
  } finally {
    await context.setOffline(false);
    await server.close();
  }
});

for (const status of [302, 401, 503]) {
  test(`online root ${status} and auth/API responses never become offline or cached`, async ({ page }) => {
    const server = await serverForTest();
    try {
      await controlledPage(page, server.origin);
      server.setRootStatus(status);
      const response = await page.reload();
      expect(response.status()).toBe(status === 302 ? 401 : status);
      await expect(page.locator("body")).toContainText(PRIVATE);
      if (status === 302) expect(new URL(page.url()).pathname).toBe("/auth/login");
      const result = await page.evaluate(async () => {
        const api = await fetch("/api/chats");
        const contents = [];
        for (const name of await caches.keys()) {
          const cache = await caches.open(name);
          for (const request of await cache.keys()) {
            if (request.url.endsWith(".html")) contents.push(await (await cache.match(request)).text());
          }
        }
        return { status: api.status, contents };
      });
      expect(result.status).toBe(401);
      expect(result.contents).toHaveLength(1);
      expect(result.contents[0]).not.toContain(PRIVATE);
      expect(result.contents[0]).toContain("You're offline");
    } finally { await server.close(); }
  });
}
