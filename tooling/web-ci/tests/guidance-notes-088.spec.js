// Browser tests for the notes guidance surface against the packaged classic client with controlled
// socket replies: read correlation and retirement, not live backend behavior.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { expect, test } from "@playwright/test";

import { collectClientCoverage } from "./client-coverage-fixture.mjs";

collectClientCoverage(test, "guidance-notes-088");

const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT = resolve(ROOT, "backend/webrender/static/client.js");
const SOURCE = await readFile(CLIENT, "utf8");
const coverageOutput = process.env.ASTRAL_GUIDANCE_COVERAGE_OUTPUT;
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
  await page.route("https://guidance-read.example/**", route => route.fulfill({
    contentType: "text/html", body: `<!doctype html><html><body>
      <button id="astral-newchat-btn">New chat fixture</button><a id="logout" href="/auth/logout">Sign out fixture</a><header id="astral-topbar">
      <button data-ui-action="chrome_open" data-ui-payload='{"surface":"guidance","params":{"mode":"list"}}'>Open Notes fixture</button>
      <button data-ui-action="chrome_open" data-ui-payload='{"surface":"agents"}'>Open other fixture</button>
      </header><div id="astral-history"></div><div id="astral-status"></div>
      <section id="astral-canvas"></section><div id="astral-chat"></div>
      <form id="astral-form"><input id="astral-input"><button type="submit">Send</button></form>
      <div id="astral-modal"></div></body></html>`,
  }));
  await page.goto("https://guidance-read.example/");
  await page.addScriptTag({ content: SOURCE });
  await page.waitForFunction(() => window.__frames.some(frame => frame.type === "register_ui"));
}

async function open(page) {
  await page.getByRole("button", { name: "Open Notes fixture", exact: true }).click();
  return await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "guidance").at(-1));
}

function reply(request, text = "Current owner result") {
  return { type: "chrome_render", region: "modal", mode: "replace", surface_key: "guidance",
    request_generation: request.request_generation,
    html: `<div class="astral-modal-card" role="dialog" tabindex="-1"><p>${text}</p><button class="astral-modal-close">Close</button></div>` };
}

async function receive(page, frame) {
  await page.evaluate(value => window.__sockets.at(-1).receive(value), frame);
}

const FIXTURE = JSON.parse(await readFile(resolve(ROOT, "contracts/fixtures/guidance_088/notes_surface.json"), "utf8"));
function view(request, mode) {
  return { ...FIXTURE.web_frames[mode], request_generation: request.request_generation };
}
async function lastAction(page, action) {
  return await page.evaluate(name => window.__frames.filter(frame => frame.action === name).at(-1), action);
}

test("registration advertises implemented notes and list text remains literal", async ({ page }) => {
  await setup(page);
  expect(await page.evaluate(() => window.__frames.find(f => f.type === "register_ui").capabilities)).toContain("guidance_notes_v1");
  const pending = await open(page);
  await receive(page, view(pending, "list"));
  await expect(page.getByText(FIXTURE.states.list.notes[0].value, { exact: true })).toBeVisible();
  await expect(page.locator('#astral-modal a[href="https://example.invalid/private"]')).toHaveCount(0);
  expect(pending.session_id).toBeUndefined();
  expect(pending.payload.request_generation).toBe(pending.request_generation);
});

test("a notes form submits exact typed fields and original revision", async ({ page }) => {
  await setup(page);
  const pending = await open(page);
  await receive(page, view(pending, "edit"));
  await page.getByLabel("Note", { exact: true }).fill("Use shorter paragraphs.");
  await page.getByLabel("Category", { exact: true }).selectOption({ label: "Workflow tag" });
  await page.getByLabel("Enabled", { exact: true }).uncheck();
  await page.getByRole("button", { name: "Save note", exact: true }).click();
  const sent = await lastAction(page, "chrome_note_save");
  expect(sent.request_generation).not.toBe(pending.request_generation);
  expect(sent.payload.note_id).toBe(FIXTURE.states.edit.note.note_id);
  expect(sent.payload.expected_revision).toBe(3);
  expect(sent.payload.fields).toMatchObject({ category: "Workflow tag", value: "Use shorter paragraphs.", enabled: false, expiry: "Keep current expiry" });
  expect(sent.session_id).toBeUndefined();
  await receive(page, reply(pending, "Stale private edit"));
  await expect(page.getByText("Stale private edit")).toHaveCount(0);
  await receive(page, reply(sent, "Saved current note"));
  await expect(page.getByText("Saved current note")).toBeVisible();
});

test("expiry visibility follows the shared field choice", async ({ page }) => {
  await setup(page);
  await receive(page, view(await open(page), "new"));
  await expect(page.getByLabel("Expiry date (UTC)", { exact: true })).toBeHidden();
  await page.getByLabel("Expiry", { exact: true }).selectOption({ label: "Set a date" });
  await expect(page.getByLabel("Expiry date (UTC)", { exact: true })).toBeVisible();
  await page.getByLabel("Expiry date (UTC)", { exact: true }).fill("2027-01-02T03:04:05.123Z");
  await page.getByLabel("Note", { exact: true }).fill("Remember the original exact expiry.");
  await page.getByRole("button", { name: "Save note", exact: true }).click();
  expect((await lastAction(page, "chrome_note_save")).payload.fields.expiry_date).toBe("2027-01-02T03:04:05.123Z");
});

for (const damage of ["missing", "malformed", "wrong-region", "wrong-mode", "cross-surface"]) {
  test(`${damage} response cannot display private notes`, async ({ page }) => {
    await setup(page);
    const frame = reply(await open(page));
    if (damage === "missing") delete frame.request_generation;
    if (damage === "malformed") frame.request_generation = "invalid";
    if (damage === "wrong-region") frame.region = "topbar";
    if (damage === "wrong-mode") frame.mode = "append";
    if (damage === "cross-surface") frame.surface_key = "work";
    await receive(page, frame);
    await expect(page.getByText("Current owner result")).toHaveCount(0);
  });
}

test("newest notes request wins and duplicate response is ignored", async ({ page }) => {
  await setup(page);
  const first = await open(page), second = await open(page);
  await receive(page, reply(first, "Old private notes"));
  await expect(page.getByText("Old private notes")).toHaveCount(0);
  await receive(page, reply(second));
  await receive(page, reply(second, "Duplicate private notes"));
  await expect(page.getByText("Current owner result")).toBeVisible();
  await expect(page.getByText("Duplicate private notes")).toHaveCount(0);
});

for (const navigation of ["close", "other", "new_chat", "load_chat", "logout"]) {
  test(`${navigation} retires notes immediately`, async ({ page }) => {
    await setup(page);
    const pending = await open(page);
    await receive(page, reply(pending));
    if (navigation === "close") await page.getByRole("button", { name: "Close", exact: true }).click();
    else if (navigation === "other") await page.getByRole("button", { name: "Open other fixture", exact: true }).click();
    else if (navigation === "logout") {
      await page.locator("#logout").evaluate(link => link.addEventListener("click", event => event.preventDefault()));
      await page.locator("#logout").click();
    }
    else await page.evaluate(action => {
      const button = document.createElement("button");
      button.dataset.uiAction = action;
      button.dataset.uiPayload = JSON.stringify({ chat_id: "3359fc9b-7e28-46bb-9563-a606f9be737c" });
      document.querySelector("#astral-topbar").append(button); button.click();
    }, navigation);
    await receive(page, reply(pending, "Retired private notes"));
    await expect(page.getByText("Retired private notes")).toHaveCount(0);
    await expect(page.getByText("Current owner result")).toHaveCount(0);
  });
}

test("lost write acknowledgement retries a current read without form values", async ({ page }) => {
  await setup(page);
  await page.clock.install();
  await receive(page, view(await open(page), "edit"));
  await page.getByLabel("Note", { exact: true }).fill("Private value must never enter retry state.");
  await page.getByRole("button", { name: "Save note", exact: true }).click();
  const sent = await lastAction(page, "chrome_note_save");
  await page.clock.fastForward(6100);
  await receive(page, reply(sent, "Expired command reply"));
  await expect(page.getByText("Expired command reply")).toHaveCount(0);
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  expect(await page.evaluate(() => window.__frames.filter(f => f.action === "chrome_note_save").length)).toBe(1);
  const request = await lastAction(page, "chrome_open");
  expect(request.payload).toMatchObject({ surface: "guidance", params: { mode: "list" } });
  expect(JSON.stringify(request)).not.toContain("Private value");
  expect(request.request_generation).not.toBe(sent.request_generation);
});

test("search, toggle and Forget carry exact shared commands", async ({ page }) => {
  await setup(page);
  await receive(page, view(await open(page), "list"));
  await page.getByLabel("Search notes").fill("source");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  const search = await lastAction(page, "chrome_note_search");
  expect(search.payload.fields).toEqual({ search: "source" });
  await receive(page, view(search, "list"));
  await page.getByRole("button", { name: "Disable", exact: true }).click();
  const toggle = await lastAction(page, "chrome_note_toggle");
  expect(toggle.payload).toMatchObject({ note_id: FIXTURE.states.edit.note.note_id, expected_revision: 3, enabled: false });
  await receive(page, view(toggle, "list"));
  await page.getByRole("button", { name: "Forget", exact: true }).click();
  const review = await lastAction(page, "chrome_open");
  expect(review.payload.params).toMatchObject({ mode: "forget", note_id: FIXTURE.states.edit.note.note_id, expected_revision: 3 });
  expect(await lastAction(page, "chrome_note_forget")).toBeUndefined();
  await receive(page, view(review, "forget"));
  await page.getByRole("button", { name: "Forget note", exact: true }).click();
  expect((await lastAction(page, "chrome_note_forget")).payload).toMatchObject({ note_id: FIXTURE.states.edit.note.note_id, expected_revision: 3 });
});

test("offline notes command is refused and never reconnect-replayed", async ({ page }) => {
  await setup(page);
  const pending = await open(page);
  await receive(page, view(pending, "edit"));
  await page.evaluate(() => {
    const socket = window.__sockets.at(-1);
    socket.readyState = 3;
  });
  await page.getByLabel("Note", { exact: true }).fill("Never queue this private value.");
  await page.getByRole("button", { name: "Save note", exact: true }).click();
  expect(await lastAction(page, "chrome_note_save")).toBeUndefined();
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.waitForFunction(() => window.__sockets.length === 2, null, { timeout: 8000 });
  expect(await lastAction(page, "chrome_note_save")).toBeUndefined();
  await receive(page, reply(pending, "Old connection private notes"));
  await expect(page.getByText("Old connection private notes")).toHaveCount(0);
});
