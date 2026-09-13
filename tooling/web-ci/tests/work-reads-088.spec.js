// Actual packaged classic client with controlled socket replies. This proves
// read correlation/retirement, not institutional IAM or live staging.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT = resolve(ROOT, "backend/webrender/static/client.js");
const SOURCE = await readFile(CLIENT, "utf8");
const coverageOutput = process.env.ASTRAL_WORK_COVERAGE_OUTPUT;
const rawCoverage = [];

test.beforeEach(async ({ page }) => {
  if (coverageOutput) await page.coverage.startJSCoverage({ reportAnonymousScripts: true, resetOnNavigation: false });
});
test.afterEach(async ({ page }) => {
  if (!coverageOutput) return;
  for (const entry of await page.coverage.stopJSCoverage()) {
    if (entry.source === SOURCE) rawCoverage.push(entry);
  }
});
test.afterAll(async () => {
  if (!coverageOutput) return;
  expect(await readFile(CLIENT, "utf8")).toBe(SOURCE);
  expect(rawCoverage.length).toBeGreaterThan(0);
  await mkdir(dirname(resolve(coverageOutput)), { recursive: true });
  await writeFile(resolve(coverageOutput), JSON.stringify(rawCoverage) + "\n", { mode: 0o600 });
});

async function setup(page) {
  await page.addInitScript(() => {
    window.__ASTRAL_TOKEN__ = "fixture-owner-token";
    window.__frames = [];
    window.__sockets = [];
    window.requestIdleCallback = () => 0;
    window.fetch = async () => ({ json: async () => ({ authenticated: true,
      access_token: "fixture-owner-token", resumed: true, user_id: "owner" }) });
    class Socket {
      static OPEN = 1;
      constructor() {
        this.readyState = 0;
        window.__sockets.push(this);
        queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
      }
      send(raw) {
        const frame = JSON.parse(raw);
        window.__frames.push(frame);
        if (frame.type === "register_ui") queueMicrotask(() => this.receive({
          type: "rote_config", device_profile: { device_type: "browser" },
        }));
      }
      receive(frame) { this.onmessage?.({ data: JSON.stringify(frame) }); }
      close() { this.readyState = 3; this.onclose?.(); }
    }
    window.WebSocket = Socket;
  });
  await page.route("https://work-read.example/**", route => route.fulfill({
    contentType: "text/html", body: `<!doctype html><html><body>
      <button id="astral-newchat-btn">New chat fixture</button><a id="logout" href="/auth/logout">Sign out fixture</a><header id="astral-topbar">
      <button data-ui-action="chrome_open" data-ui-payload='{"surface":"work","params":{"mode":"list"}}'>Open Work fixture</button>
      <button data-ui-action="chrome_open" data-ui-payload='{"surface":"agents"}'>Open other fixture</button>
      </header><div id="astral-history"></div><div id="astral-status"></div>
      <section id="astral-canvas"></section><div id="astral-chat"></div>
      <form id="astral-form"><input id="astral-input"><button type="submit">Send</button></form>
      <div id="astral-modal"></div></body></html>`,
  }));
  await page.goto("https://work-read.example/");
  await page.addScriptTag({ content: SOURCE });
  await page.waitForFunction(() => window.__frames.some(frame => frame.type === "register_ui"));
}

async function open(page) {
  await page.getByRole("button", { name: "Open Work fixture", exact: true }).click();
  return await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "work").at(-1));
}

function reply(request, text = "Current owner result") {
  return { type: "chrome_render", region: "modal", mode: "replace", surface_key: "work",
    request_generation: request.request_generation,
    html: `<div class="astral-modal-card" role="dialog" tabindex="-1"><p>${text}</p><button class="astral-modal-close">Close</button></div>` };
}

async function receive(page, frame) {
  await page.evaluate(value => window.__sockets.at(-1).receive(value), frame);
}

test("only the newest read can display and a duplicate cannot replace it", async ({ page }) => {
  await setup(page);
  const first = await open(page);
  const second = await open(page);
  expect(second.request_generation).not.toBe(first.request_generation);
  expect(second.payload.request_generation).toBe(second.request_generation);
  await receive(page, reply(first, "Stale owner result"));
  await expect(page.getByText("Stale owner result")).toHaveCount(0);
  await receive(page, reply(second));
  await expect(page.getByText("Current owner result")).toBeVisible();
  await receive(page, reply(second, "Duplicate changed result"));
  await expect(page.getByText("Duplicate changed result")).toHaveCount(0);
});

for (const mutation of ["missing", "malformed", "wrong-mode", "wrong-region"]) {
  test(`${mutation} correlation cannot paint Work`, async ({ page }) => {
    await setup(page);
    const frame = reply(await open(page));
    if (mutation === "missing") delete frame.request_generation;
    if (mutation === "malformed") frame.request_generation = "wrong";
    if (mutation === "wrong-mode") frame.mode = "append";
    if (mutation === "wrong-region") frame.region = "topbar";
    await receive(page, frame);
    await expect(page.getByText("Current owner result")).toHaveCount(0);
  });
}

test("close and later navigation retire read replies immediately", async ({ page }) => {
  await setup(page);
  const first = await open(page);
  await receive(page, reply(first));
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await receive(page, reply(first, "Late after close"));
  await expect(page.getByText("Late after close")).toHaveCount(0);
  const next = await open(page);
  await page.getByRole("button", { name: "Open other fixture", exact: true }).click();
  await receive(page, reply(next, "Late after navigation"));
  await expect(page.getByText("Late after navigation")).toHaveCount(0);
  await receive(page, { type: "chrome_render", region: "modal", html: "<p>Other surface</p>" });
  await expect(page.getByText("Other surface")).toBeVisible();
});

test("a delayed generic close cannot clear the current Work surface", async ({ page }) => {
  await setup(page);
  await receive(page, reply(await open(page)));
  await receive(page, { type: "chrome_render", region: "modal", html: "" });
  await expect(page.getByText("Current owner result")).toBeVisible();
});

test("disconnect erases Work and offline read never enters reconnect queue", async ({ page }) => {
  await setup(page);
  const first = await open(page);
  await receive(page, reply(first));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.getByText("Current owner result")).toHaveCount(0);
  await page.getByRole("button", { name: "Open Work fixture", exact: true }).click();
  await page.waitForFunction(() => window.__sockets.length === 2, null, { timeout: 8000 });
  const requests = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "work"));
  expect(requests).toHaveLength(1);
  await receive(page, reply(first, "Old connection result"));
  await expect(page.getByText("Old connection result")).toHaveCount(0);
  const fresh = await open(page);
  expect(fresh.request_generation).not.toBe(first.request_generation);
  await receive(page, reply(fresh, "New connection result"));
  await expect(page.getByText("New connection result")).toBeVisible();
});

for (const navigation of ["new_chat", "load_chat"]) {
  test(`${navigation} retires the current Work read`, async ({ page }) => {
    await setup(page);
    const pending = await open(page);
    await page.evaluate(action => {
      const button = document.createElement("button");
      button.setAttribute("data-ui-action", action);
      button.setAttribute("data-ui-payload", JSON.stringify({chat_id: "3359fc9b-7e28-46bb-9563-a606f9be737c"}));
      document.querySelector("#astral-topbar").append(button);
      button.click();
    }, navigation);
    await receive(page, reply(pending, "Retired navigation result"));
    await expect(page.getByText("Retired navigation result")).toHaveCount(0);
  });
}

test("timed out read cannot overwrite retry and retry uses a new identity", async ({ page }) => {
  await setup(page);
  await page.clock.install();
  const pending = await open(page);
  await page.clock.fastForward(6100);
  await expect(page.getByRole("button", { name: "Retry", exact: true })).toBeVisible();
  await receive(page, reply(pending, "Timed out result"));
  await expect(page.getByText("Timed out result")).toHaveCount(0);
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  const fresh = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "work").at(-1));
  expect(fresh.request_generation).not.toBe(pending.request_generation);
  await receive(page, reply(fresh, "Retried result"));
  await expect(page.getByText("Retried result")).toBeVisible();
});

test("authentication renewal retires Work before the async token response", async ({ page }) => {
  await setup(page);
  const pending = await open(page);
  await page.evaluate(() => { window.fetch = () => new Promise(() => {}); });
  await receive(page, { type: "auth_required" });
  await receive(page, reply(pending, "Retired authentication result"));
  await expect(page.getByText("Retired authentication result")).toHaveCount(0);
});

test("admission refusal retires the rejected read", async ({ page }) => {
  await setup(page);
  const pending = await open(page);
  await receive(page, { type: "error", accepted: false, submission_id: pending.submission_id,
    code: "capacity_exceeded", message: "Busy; retry.", retryable: true, retry_after_ms: 1000 });
  await receive(page, reply(pending, "Rejected result"));
  await expect(page.getByText("Rejected result")).toHaveCount(0);
});

test("failed socket send is not queued or allowed to receive", async ({ page }) => {
  await setup(page);
  await page.evaluate(() => {
    window.__sockets.at(-1).send = raw => {
      window.__attempt = JSON.parse(raw);
      throw new Error("controlled send failure");
    };
  });
  await open(page);
  const attempted = await page.evaluate(() => window.__attempt);
  await receive(page, reply(attempted, "Unsent result"));
  await expect(page.getByText("Unsent result")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Retry", exact: true })).toBeVisible();
});

test("nested Work navigation excludes the unrelated current conversation", async ({ page }) => {
  await setup(page);
  await receive(page, { type: "chat_created", payload: { chat_id: "3359fc9b-7e28-46bb-9563-a606f9be737c" } });
  const pending = await open(page);
  const frame = reply(pending);
  frame.html = `<button class="astral-action" data-action="chrome_open" data-payload='{"surface":"work","params":{"mode":"list"}}'>Refresh Work fixture</button>`;
  await receive(page, frame);
  await page.getByRole("button", { name: "Refresh Work fixture", exact: true }).click();
  const next = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "work").at(-1));
  expect(next.session_id).toBeUndefined();
  expect(next.payload.chat_id).toBeUndefined();
  expect(next.request_generation).not.toBe(pending.request_generation);
});

test("the actual new chat and history controls close Work", async ({ page }) => {
  await setup(page);
  const first = await open(page);
  await page.getByRole("button", { name: "New chat fixture", exact: true }).click();
  await receive(page, reply(first, "Discarded new chat result"));
  await expect(page.getByText("Discarded new chat result")).toHaveCount(0);
  const second = await open(page);
  await page.evaluate(() => {
    const button = document.createElement("button");
    button.className = "astral-action";
    button.setAttribute("data-action", "load_chat");
    button.setAttribute("data-payload", '{"chat_id":"3359fc9b-7e28-46bb-9563-a606f9be737c"}');
    document.body.append(button); button.click();
  });
  await receive(page, reply(second, "Discarded history result"));
  await expect(page.getByText("Discarded history result")).toHaveCount(0);
});

test("a chat send and deliberate sign-out discard Work", async ({ page }) => {
  await setup(page);
  const first = await open(page);
  await page.locator("#astral-input").fill("Synthetic request");
  await page.locator("#astral-form").evaluate(form => form.requestSubmit());
  await receive(page, reply(first, "Discarded send result"));
  await expect(page.getByText("Discarded send result")).toHaveCount(0);
  const second = await open(page);
  await page.locator("#logout").evaluate(link => link.addEventListener("click", event => event.preventDefault()));
  await page.getByRole("link", { name: "Sign out fixture", exact: true }).click();
  await receive(page, reply(second, "Discarded signed-out result"));
  await expect(page.getByText("Discarded signed-out result")).toHaveCount(0);
});

test("a correlated failed operation retires Work immediately", async ({ page }) => {
  await setup(page);
  const pending = await open(page);
  await receive(page, {type: "operation_status", action: "chrome_open", chat_id: null,
    connection_generation: pending.connection_generation, request_generation: pending.request_generation,
    operation_id: "3359fc9b-7e28-46bb-9563-a606f9be737c", sequence: 1, state: "failed", phase: "failed",
    surface: "work", terminal: true, retryable: false, retry_after_ms: null,
    label: "Read failed", error: {code: "operation_failed", message: "Read failed"},
    updated_at: "2026-09-13T05:00:00Z"});
  await receive(page, reply(pending, "Failed operation result"));
  await expect(page.getByText("Failed operation result")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Retry", exact: true })).toBeVisible();
});
