// Share feedback regressions exercise the exact shipped client with synthetic authenticated transport and controlled clipboard outcomes.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { collectClientCoverage } from "./client-coverage-fixture.mjs";

collectClientCoverage(test, "share-feedback");

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const source = await readFile(resolve(STATIC, "client.js"), "utf8");
const CHAT_ID = "11111111-1111-4111-8111-111111111111";
const TOKEN = `header.${Buffer.from(JSON.stringify({ iss: "https://identity.example/realms/astral", sub: "share-user" })).toString("base64url")}.signature`;

async function changeIdentity(page, change) {
  await page.locator(change === "owner" ? "#logout" : "#astral-newchat-btn").evaluate(element => element.click());
}

async function setup(page, { clipboard = "pending", status = 201, body = { share_url: "/share/test-token" }, deferred = false, width = 1200 } = {}) {
  await page.setViewportSize({ width, height: 800 });
  await page.route("https://share.test/**", route => route.fulfill({ contentType: "text/html", body: `<!doctype html><html><body>
    <header id="astral-topbar"><a id="logout" href="/auth/logout">Sign out</a></header>
    <button id="astral-newchat-btn" type="button">New chat</button>
    <div data-component-id="component-a"><button id="create" class="astral-share-btn" data-share-scope="component">Create share</button></div>
    <div id="astral-status"></div><div id="astral-history"></div>
    <form id="astral-form"><textarea id="astral-input"></textarea><button type="submit">Send</button></form>
    <section id="astral-canvas"><div id="astral-chat" class="astral-feed"></div></section>
    <div id="astral-attachments"></div><button id="astral-attach-btn" type="button"></button><input id="astral-attach-input" type="file" hidden>
    <div id="astral-voice-controls"></div><div id="astral-voice-transcript"></div>
    <div id="astral-voice-turn-notice"><span id="astral-voice-turn-notice-title"></span><span id="astral-voice-turn-notice-message"></span></div>
    <button id="astral-bg-btn" type="button" aria-pressed="false"></button><div id="astral-slash-menu" class="hidden"></div>
    <div id="astral-modal"></div></body></html>` }));
  await page.goto(`https://share.test/?chat=${CHAT_ID}`);
  await page.addStyleTag({ path: resolve(STATIC, "astral.css") });
  await page.addScriptTag({ path: resolve(STATIC, "vendor/tailwind.js") });
  await page.evaluate(({ clipboard, status, body, deferred, token }) => {
    window.__ASTRAL_TOKEN__ = token;
    window.__ASTRAL_RESUMED__ = true;
    window.requestIdleCallback = () => 0;
    window.registrations = [];
    class FakeWebSocket {
      static OPEN = 1;
      constructor() {
        this.readyState = 0;
        queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
      }
      send(raw) {
        const frame = JSON.parse(raw);
        if (frame.type === "register_ui") {
          window.registrations.push(frame);
          queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ type: "rote_config", device_profile: { device_type: "browser" } }) }));
        }
      }
      close() { this.readyState = 3; this.onclose?.(); }
    }
    window.WebSocket = FakeWebSocket;
    window.requests = [];
    window.copies = [];
    window.fetch = (url, options) => {
      if (!String(url).endsWith("/api/share")) return Promise.resolve({ json: async () => ({ authenticated: true, access_token: token, resumed: true, user_id: "share-user" }) });
      window.requests.push({ url, options });
      return new Promise((resolve, reject) => {
        window.finishShare = (failure = false) => failure ? reject(new Error("Network unavailable"))
          : resolve({ ok: status < 400, status, json: async () => body });
        if (!deferred) window.finishShare();
      });
    };
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: clipboard === "missing" ? undefined : {
      writeText: value => {
        window.copies.push({ value, visible: Boolean(document.getElementById("astral-share-link")?.value) });
        if (clipboard === "throw") throw new Error("Clipboard unavailable");
        if (clipboard === "reject") return Promise.reject(new Error("Clipboard denied"));
        if (clipboard === "success") return Promise.resolve();
        return new Promise((resolve, reject) => {
          window.finishClipboard = failure => failure ? reject(new Error("Clipboard denied")) : resolve();
        });
      },
    } });
    document.getElementById("logout").addEventListener("click", event => event.preventDefault());
  }, { clipboard, status, body, deferred, token: TOKEN });
  await page.addScriptTag({ content: source });
  await page.waitForFunction(() => window.registrations.length > 0);
  await page.getByRole("button", { name: "Create share" }).click();
}

test("successful share displays a selectable labelled link before clipboard completion", async ({ page }) => {
  await setup(page, { clipboard: "success" });
  await expect(page.getByRole("dialog", { name: "Share link ready" })).toBeVisible();
  const link = page.getByRole("textbox", { name: "Anyone with this link can view this snapshot." });
  await expect(link).toHaveValue("https://share.test/share/test-token");
  await expect(link).toHaveAttribute("readonly", "");
  await expect(page.locator("#astral-share-status")).toHaveText("Share link copied to clipboard.");
  expect(await page.evaluate(() => window.copies)).toEqual([{ value: "https://share.test/share/test-token", visible: true }]);
  const request = await page.evaluate(() => window.requests[0]);
  expect(request.options.headers.Authorization).toBe(`Bearer ${TOKEN}`);
  expect(JSON.parse(request.options.body)).toEqual({ chat_id: CHAT_ID, scope: "component", component_id: "component-a" });
  await page.getByRole("button", { name: "Copy link", exact: true }).click();
  expect(await page.evaluate(() => window.copies.length)).toBe(2);
});

test("pending clipboard never hides the link and keyboard controls fit a phone", async ({ page }) => {
  await setup(page, { width: 320 });
  const dialog = page.getByRole("dialog", { name: "Share link ready" });
  await expect(dialog).toBeVisible();
  const link = page.locator("#astral-share-link");
  await expect(link).toBeFocused();
  expect(await link.evaluate(input => input.selectionEnd - input.selectionStart)).toBe("https://share.test/share/test-token".length);
  await page.keyboard.press("Shift+Tab");
  await expect(page.getByRole("button", { name: "Close", exact: true })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(link).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Copy link", exact: true })).toBeFocused();
  expect(await page.locator("body").evaluate(element => element.scrollWidth)).toBeLessThanOrEqual(320);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Create share" })).toBeFocused();
  await page.evaluate(() => window.finishClipboard(false));
  await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
});

for (const clipboard of ["missing", "reject", "throw"]) {
  test(`clipboard ${clipboard} retains the link and manual-copy guidance`, async ({ page }) => {
    await setup(page, { clipboard });
    await expect(page.locator("#astral-share-status")).toContainText("copy it manually");
    await expect(page.locator("#astral-share-link")).toHaveValue("https://share.test/share/test-token");
    await expect(page.locator("#astral-share-link")).toBeFocused();
    await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
  });
}

for (const [status, body, message] of [
  [403, { error: "phi_blocked" }, "Sharing refused: the content matched the PHI gate."],
  [503, { detail: "Sharing unavailable" }, "Sharing unavailable"],
  [500, {}, "Share failed (500)"],
  [201, {}, "Share failed: no link returned."],
]) {
  test(`share response ${status} ${message} shows error without exposing a link`, async ({ page }) => {
    await setup(page, { status, body });
    await expect(page.locator("#astral-toasts .astral-toast").last()).toHaveText(message);
    await expect(page.getByRole("dialog")).toHaveCount(0);
    expect(await page.evaluate(() => window.copies)).toEqual([]);
  });
}

for (const change of ["owner", "chat"]) {
  for (const failure of [false, true]) {
    test(`late share ${failure ? "failure" : "success"} after ${change} change reveals nothing`, async ({ page }) => {
      await setup(page, { deferred: true });
      await changeIdentity(page, change);
      await page.evaluate(failure => window.finishShare(failure), failure);
      await expect(page.getByRole("dialog")).toHaveCount(0);
      await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
      expect(await page.evaluate(() => window.copies)).toEqual([]);
    });
  }
}

for (const failure of [false, true]) {
  test(`late clipboard ${failure ? "failure" : "success"} after privacy cleanup cannot restore the link`, async ({ page }) => {
    await setup(page);
    await expect(page.getByRole("dialog", { name: "Share link ready" })).toBeVisible();
    await changeIdentity(page, "owner");
    await page.evaluate(failure => window.finishClipboard(failure), failure);
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText("test-token");
    await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
  });
}

test("network failure reports a visible error", async ({ page }) => {
  await setup(page, { deferred: true });
  await page.evaluate(() => window.finishShare(true));
  await expect(page.locator("#astral-toasts .astral-toast").last()).toHaveText("Couldn't create the share link.");
  await expect(page.getByRole("dialog")).toHaveCount(0);
});
