// Tests for the Advanced-settings composition picker (src/astralprojection/resources.py):
// server-issued selections stay scoped to the owner's key, and Send remains a single action without
// one.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import { expect, test } from "@playwright/test";

import { collectClientCoverage } from "./client-coverage-fixture.mjs";
import { consoleShell } from "./console-shell.mjs";

collectClientCoverage(test, "selection-088");

import { convertPlaywrightV8Coverage } from "../coverage-conversion.mjs";

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const CLIENT_PATH = "backend/webrender/static/client.js";
const SOURCE = await readFile(resolve(ROOT, CLIENT_PATH), "utf8");
const ORIGIN = "https://selection.test";
const STORAGE_PREFIX = "astraldeep.turn_selection.v1.";

const FIXTURE = JSON.parse(await readFile(
  resolve(ROOT, "contracts/fixtures/guidance_088/selection_surface.json"), "utf8"));
const NOTES = JSON.parse(await readFile(
  resolve(ROOT, "contracts/fixtures/guidance_088/notes_surface.json"), "utf8"));

const TOPBAR = '<div class="flex items-center gap-2 px-3"><button type="button" id="astral-newchat-btn">New chat</button>'
  + '<a id="logout" href="/auth/logout">Sign out</a></div>';
const SHELL = consoleShell(ROOT)
  .replace(/\?v=%%ASTRAL_V:[^%]*%%/gu, "")
  .replaceAll("%%ASTRAL_NONCE%%", "selection-nonce")
  .replaceAll("%%ASTRAL_TOKEN%%", "fixture-owner-token")
  .replaceAll("%%ASTRAL_RESUMED%%", "true")
  .replaceAll("%%ASTRAL_ACCEPT%%", ".txt,.pdf")
  .replaceAll("%%ASTRAL_LANDING%%", JSON.stringify({ agents: [], scenarios: [], categories: [] }))
  .replaceAll("%%ASTRAL_USER_NAME%%", "Fixture owner")
  .replaceAll("%%ASTRAL_USER_ROLE%%", "Member")
  .replace("%%ASTRAL_TOPBAR%%", () => TOPBAR);

const coverageOutput = process.env.ASTRAL_SELECTION_COVERAGE_OUTPUT;
const rawCoverageOutput = process.env.ASTRAL_SELECTION_RAW_COVERAGE_OUTPUT;
const coverageDocuments = [];
const rawCoverage = [];

test.beforeEach(async ({ page, browserName }) => {
  if (!coverageOutput && !rawCoverageOutput) return;
  if (browserName !== "chromium") throw new Error("Selection coverage requires pinned Chromium");
  await page.coverage.startJSCoverage({ reportAnonymousScripts: true, resetOnNavigation: false });
});

test.afterEach(async ({ page }) => {
  if (!coverageOutput && !rawCoverageOutput) return;
  for (const entry of await page.coverage.stopJSCoverage()) {
    if (entry.source !== SOURCE) continue;
    if (rawCoverageOutput) rawCoverage.push(entry);
    if (!coverageOutput) continue;
    coverageDocuments.push(await convertPlaywrightV8Coverage(
      [{ ...entry, sourcePath: CLIENT_PATH }], candidate => candidate.sourcePath,
    ));
  }
});

test.afterAll(async () => {
  if (rawCoverageOutput) {
    expect(await readFile(resolve(ROOT, CLIENT_PATH), "utf8")).toBe(SOURCE);
    expect(rawCoverage.length).toBeGreaterThan(0);
    await mkdir(dirname(resolve(rawCoverageOutput)), { recursive: true });
    await writeFile(resolve(rawCoverageOutput), JSON.stringify(rawCoverage) + "\n", { mode: 0o600 });
  }
  if (!coverageOutput) return;
  if (!coverageDocuments.length) throw new Error("Missing exact client.js browser coverage");
  const output = { ...coverageDocuments[0], coverage: {} };
  for (const document of coverageDocuments) {
    for (const [path, record] of Object.entries(document.coverage)) {
      const prior = output.coverage[path];
      if (!prior) output.coverage[path] = structuredClone(record);
      else {
        if (JSON.stringify(prior.statementMap) !== JSON.stringify(record.statementMap)) {
          throw new Error("client.js changed during coverage collection");
        }
        for (const [key, count] of Object.entries(record.s)) prior.s[key] = prior.s[key] > 0 || count > 0 ? 1 : 0;
      }
    }
  }
  await mkdir(dirname(resolve(coverageOutput)), { recursive: true });
  await writeFile(resolve(coverageOutput), JSON.stringify(output, null, 2) + "\n", { mode: 0o600 });
});

function installOwner(page, user) {
  return page.addInitScript(owner => {
    window.__frames = [];
    window.__sockets = [];
    window.requestIdleCallback = () => 0;
    window.fetch = async () => ({ json: async () => ({ authenticated: true,
      access_token: "fixture-owner-token", resumed: true, user_id: owner }) });
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
  }, user);
}

async function registered(page) {
  await page.waitForFunction(() => window.__frames.some(frame => frame.type === "register_ui"));
  return await page.evaluate(() => window.__frames.find(frame => frame.type === "register_ui"));
}

async function setup(page, { width = 1024, font = "100%", user = "owner" } = {}) {
  await page.setViewportSize({ width, height: 800 });
  await installOwner(page, user);
  await page.route(`${ORIGIN}/**`, async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") { await route.fulfill({ contentType: "text/html", body: SHELL }); return; }
    if (path.startsWith("/static/")) {
      try { await route.fulfill({ path: resolve(STATIC, path.slice("/static/".length)) }); }
      catch { await route.abort(); }
      return;
    }
    await route.abort();
  });
  await page.goto(`${ORIGIN}/`);
  const registration = await registered(page);
  if (font !== "100%") await page.evaluate(size => { document.documentElement.style.fontSize = size; }, font);
  return registration;
}

async function receive(page, frame) {
  await page.evaluate(value => window.__sockets.at(-1).receive(value), frame);
}

async function frames(page, action) {
  return await page.evaluate(name => window.__frames.filter(frame => frame.action === name), action);
}

async function lastFrame(page, action) {
  return (await frames(page, action)).at(-1);
}

const advanced = page => page.locator("#astral-advanced-btn");
const chip = page => page.locator("#astral-selection");
const modal = page => page.locator("#astral-modal");

async function requestPicker(page) {
  const more = page.getByRole("button", { name: "More options", exact: true });
  if (await more.getAttribute("aria-expanded") !== "true") await more.click();
  await expect(page.getByRole("menuitem", { name: "Advanced settings", exact: true })).toBeVisible();
  await advanced(page).click();
}

async function openPicker(page) {
  await requestPicker(page);
  const pending = await lastFrame(page, "chrome_open");
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: pending.request_generation });
  await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toBeVisible();
  return pending;
}

async function choose(page, label) {
  const button = modal(page).getByRole("button", { name: label, exact: true });
  const carried = JSON.parse(await button.getAttribute("data-ui-payload"));
  await button.click();
  return { carried, sent: await lastFrame(page, "chrome_turn_selection_set") };
}

async function send(page, text) {
  const before = (await frames(page, "chat_message")).length;
  await page.locator("#astral-input").fill(text);
  await page.locator("#astral-input").press("Enter");
  await expect.poll(async () => (await frames(page, "chat_message")).length).toBe(before + 1);
  return await lastFrame(page, "chat_message");
}

async function storedSelections(page) {
  return await page.evaluate(prefix => Object.keys(localStorage)
    .filter(key => key.startsWith(prefix))
    .map(key => [key, JSON.parse(localStorage.getItem(key))]), STORAGE_PREFIX);
}

async function noHorizontalScroll(page, width) {
  expect(await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }))).toEqual({ scrollWidth: width, clientWidth: width });
}

test("a plain Send is one action with no preflight and no selection key", async ({ page }) => {
  const registration = await setup(page);
  expect(registration.capabilities).toContain("guidance_selection_v1");
  await expect(page.getByRole("button", { name: "More options", exact: true })).toBeVisible();
  await expect(advanced(page)).toBeHidden();
  await expect(chip(page)).toBeHidden();
  const sent = await send(page, "What is on my plate today?");
  expect(sent.payload.message).toBe("What is on my plate today?");
  expect("selection" in sent.payload).toBe(false);
  expect(await frames(page, "chrome_open")).toEqual([]);
  expect(await frames(page, "chrome_turn_selection_set")).toEqual([]);
  await expect(modal(page)).toBeEmpty();
  expect(await storedSelections(page)).toEqual([]);
});

test("Advanced opens the server-rendered picker on demand and Close, Escape and stale replies retire it", async ({ page }) => {
  await setup(page);
  await requestPicker(page);
  const pending = await lastFrame(page, "chrome_open");
  expect(pending.payload).toMatchObject({ surface: "guidance", params: { view: "selection" } });
  expect(Object.keys(pending.payload.params)).toEqual(["view"]);
  expect(pending.session_id).toBeUndefined();
  await expect(modal(page).locator("[aria-busy=\"true\"]")).toBeVisible();
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: "2e7c1b0a-4f6d-4a8b-9c1e-3d5f7a9b1c2d" });
  await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toHaveCount(0);
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: pending.request_generation });
  await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toBeVisible();
  await expect(modal(page).getByText("your selection applies to this chat only", { exact: false })).toBeVisible();
  await modal(page).getByRole("button", { name: "Close", exact: true }).click();
  await expect(modal(page)).toBeEmpty();
  expect((await frames(page, "chrome_close")).length).toBe(1);
  await openPicker(page);
  await page.keyboard.press("Escape");
  await expect(modal(page)).toBeEmpty();
  await expect(chip(page)).toBeHidden();
  expect(await frames(page, "chrome_turn_selection_set")).toEqual([]);
});

test("a picker button keeps the exact server-issued selection, shows a bounded chip and rides each send", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  const { carried, sent } = await choose(page, "Add note");
  expect(sent.payload).toMatchObject(carried);
  expect(Object.keys(sent.payload).sort()).toEqual(["agent", "notes", "request_generation", "skills", "submission_id", "version"]);
  expect(sent.session_id).toBeUndefined();
  await expect(modal(page).locator("[aria-busy=\"true\"]")).toBeVisible();
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: sent.request_generation });
  await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toBeVisible();
  await expect(chip(page)).toBeVisible();
  await expect(chip(page)).toHaveText(/Using 1 agent, 1 skill, 2 notes for this chat/u);
  await expect(chip(page)).not.toContainText("Literature scout");
  await expect(advanced(page)).toHaveAttribute("data-selection", "active");
  const stored = await storedSelections(page);
  expect(stored).toHaveLength(1);
  expect(stored[0][1]).toMatchObject({ schema_version: 1, selection: carried });
  await page.keyboard.press("Escape");
  const first = await send(page, "Summarize my week");
  expect(first.payload.selection).toEqual(carried);
  expect((await frames(page, "chat_message")).filter(frame => "selection" in frame.payload)).toHaveLength(1);
  const second = await send(page, "And next week");
  expect(second.payload.selection).toEqual(carried);
  expect(second.payload.selection).not.toBe(first.payload.selection);
});

test("Clear selection in the picker and the chip control both remove the selection", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  await choose(page, "Add note");
  await expect(chip(page)).toBeVisible();
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: (await lastFrame(page, "chrome_turn_selection_set")).request_generation });
  const cleared = await choose(page, "Clear selection");
  expect(cleared.sent.payload).toMatchObject({ version: 1, agent: null, skills: [], notes: [] });
  await expect(chip(page)).toBeHidden();
  expect(await storedSelections(page)).toEqual([]);
  await page.keyboard.press("Escape");
  expect("selection" in (await send(page, "Plain again")).payload).toBe(false);

  await openPicker(page);
  await choose(page, "Remove skill");
  await page.keyboard.press("Escape");
  await expect(chip(page)).toHaveText(/Using 1 agent, 1 note for this chat/u);
  const commands = (await frames(page, "chrome_turn_selection_set")).length;
  await page.getByRole("button", { name: "Clear the selection for this chat", exact: true }).click();
  await expect(chip(page)).toBeHidden();
  await expect(page.getByRole("button", { name: "More options", exact: true })).toBeFocused();
  expect((await frames(page, "chrome_turn_selection_set")).length).toBe(commands);
  expect(await storedSelections(page)).toEqual([]);
  expect("selection" in (await send(page, "Still plain")).payload).toBe(false);
});

test("the selection survives a reload for the same verified owner and is erased for another owner", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  const { carried } = await choose(page, "Add note");
  await page.reload();
  await registered(page);
  await expect(chip(page)).toHaveText(/Using 1 agent, 1 skill, 2 notes for this chat/u);
  expect((await send(page, "After reload")).payload.selection).toEqual(carried);

  await installOwner(page, "other");
  await page.reload();
  await registered(page);
  await expect(chip(page)).toBeHidden();
  expect(await storedSelections(page)).toEqual([]);
  expect("selection" in (await send(page, "Other owner")).payload).toBe(false);

  await installOwner(page, "owner");
  await page.reload();
  await registered(page);
  await expect(chip(page)).toBeHidden();
  expect("selection" in (await send(page, "Owner back")).payload).toBe(false);
});

test("sign-out erases the selection immediately", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  await choose(page, "Add note");
  await page.keyboard.press("Escape");
  await expect(chip(page)).toBeVisible();
  await page.locator("#logout").evaluate(link => link.addEventListener("click", event => event.preventDefault()));
  await page.locator("#logout").click();
  await expect(chip(page)).toBeHidden();
  expect(await storedSelections(page)).toEqual([]);
});

test("New chat erases the selection because it applies to this chat only", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  await choose(page, "Add note");
  await page.keyboard.press("Escape");
  await page.locator("#astral-newchat-btn").click();
  await expect(chip(page)).toBeHidden();
  expect(await storedSelections(page)).toEqual([]);
  expect("selection" in (await send(page, "Fresh chat")).payload).toBe(false);
});

for (const [damage, payload] of [
  ["version", { version: 2, agent: null, skills: [], notes: [{ note_id: FIXTURE.states.picker.notes[0].note_id, revision: 3 }] }],
  ["extra-key", { version: 1, agent: null, skills: [], notes: [], value: "private" }],
  ["duplicate", { version: 1, agent: null, skills: [], notes: [
    { note_id: FIXTURE.states.picker.notes[0].note_id, revision: 3 },
    { note_id: FIXTURE.states.picker.notes[0].note_id, revision: 4 }] }],
  ["revision", { version: 1, agent: { agent_id: "scout", revision_id: "not-a-uuid" }, skills: [], notes: [] }],
  ["bounds", { version: 1, agent: null, skills: [], notes: Array.from({ length: 9 }, (_, index) =>
    ({ note_id: `0d9c2f9a-3e5b-4c7d-8a1f-6b2e4d8c0a1${index}`, revision: 1 })) }],
]) {
  test(`a malformed ${damage} selection is refused locally and never sent`, async ({ page }) => {
    await setup(page);
    await page.evaluate(value => {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = "Damaged";
      button.setAttribute("data-ui-action", "chrome_turn_selection_set");
      button.setAttribute("data-ui-payload", JSON.stringify(value));
      document.querySelector("#astral-form").append(button);
      button.click();
    }, payload);
    expect(await frames(page, "chrome_turn_selection_set")).toEqual([]);
    await expect(chip(page)).toBeHidden();
    expect(await storedSelections(page)).toEqual([]);
    expect("selection" in (await send(page, "Unaffected")).payload).toBe(false);
  });
}

test("a server-issued binding on a guidance render replaces the local one; other renders leave it alone", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  const { carried, sent } = await choose(page, "Add note");
  const agentOnly = { version: 1, agent: carried.agent, skills: [], notes: [] };
  const stamped = FIXTURE.web_frames.picker.html.replace(
    'data-chrome-surface="guidance"',
    `data-chrome-surface="guidance" data-astral-selection='${JSON.stringify(agentOnly)}'`);
  await receive(page, { ...FIXTURE.web_frames.picker, html: stamped, request_generation: sent.request_generation });
  await expect(chip(page)).toHaveText(/Using 1 agent for this chat/u);
  expect((await storedSelections(page))[0][1].selection).toEqual(agentOnly);
  await page.keyboard.press("Escape");
  await expect(modal(page)).toBeEmpty();
  await requestPicker(page);
  const reopened = await lastFrame(page, "chrome_open");
  const broken = FIXTURE.web_frames.picker.html.replace(
    'data-chrome-surface="guidance"', 'data-chrome-surface="guidance" data-astral-selection="{not json"');
  await receive(page, { ...FIXTURE.web_frames.picker, html: broken, request_generation: reopened.request_generation });
  await expect(chip(page)).toHaveText(/Using 1 agent for this chat/u);
  await page.keyboard.press("Escape");
  await page.evaluate(() => {
    const button = document.createElement("button");
    button.setAttribute("data-ui-action", "chrome_open");
    button.setAttribute("data-ui-payload", JSON.stringify({ surface: "guidance", params: { mode: "list" } }));
    document.querySelector("#astral-form").append(button);
    button.click();
  });
  const notes = await lastFrame(page, "chrome_open");
  await receive(page, { ...NOTES.web_frames.list, request_generation: notes.request_generation });
  await expect(chip(page)).toHaveText(/Using 1 agent for this chat/u);
  await page.keyboard.press("Escape");
  expect((await send(page, "Agent only")).payload.selection).toEqual(agentOnly);
});

test("a lost selection acknowledgement retries a picker read and never replays the command", async ({ page }) => {
  await setup(page);
  await page.clock.install();
  await openPicker(page);
  const { sent } = await choose(page, "Add note");
  await page.clock.fastForward(6100);
  await receive(page, { ...FIXTURE.web_frames.picker, request_generation: sent.request_generation });
  await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toHaveCount(0);
  await modal(page).getByRole("button", { name: "Retry", exact: true }).click();
  const retried = await lastFrame(page, "chrome_open");
  expect(retried.payload).toMatchObject({ surface: "guidance", params: { view: "selection" } });
  expect(retried.request_generation).not.toBe(sent.request_generation);
  expect((await frames(page, "chrome_turn_selection_set")).length).toBe(1);
  await expect(chip(page)).toBeVisible();
});

test("an offline selection command keeps the local binding but is refused, never queued", async ({ page }) => {
  await setup(page);
  await openPicker(page);
  await page.evaluate(() => { window.__sockets.at(-1).readyState = 3; });
  const { carried } = await choose(page, "Add note");
  expect(await frames(page, "chrome_turn_selection_set")).toEqual([]);
  await expect(chip(page)).toBeVisible();
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.waitForFunction(() => window.__sockets.length === 2, null, { timeout: 8000 });
  expect(await frames(page, "chrome_turn_selection_set")).toEqual([]);
  expect((await storedSelections(page))[0][1].selection).toEqual(carried);
});

for (const [width, font] of [[320, "100%"], [320, "200%"]]) {
  test(`keyboard-only selection at ${width}px with ${font} text stays operable`, async ({ page }) => {
    await setup(page, { width, font });
    await noHorizontalScroll(page, width);
    const more = page.locator("#astral-composer-more");
    if (await more.isVisible()) {
      await more.focus();
      await page.keyboard.press("Enter");
    }
    await page.locator("#astral-input").focus();
    for (let step = 0; step < 12 && !(await advanced(page).evaluate(el => el === document.activeElement)); step++) {
      await page.keyboard.press("Tab");
    }
    await expect(advanced(page)).toBeFocused();
    const box = await advanced(page).boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(width);
    await page.keyboard.press("Enter");
    const pending = await lastFrame(page, "chrome_open");
    expect(pending.payload).toMatchObject({ surface: "guidance", params: { view: "selection" } });
    await receive(page, { ...FIXTURE.web_frames.picker, request_generation: pending.request_generation });
    await expect(modal(page).getByRole("dialog", { name: "Use for this chat" })).toBeVisible();
    await noHorizontalScroll(page, width);
    const target = modal(page).getByRole("button", { name: "Add note", exact: true });
    for (let step = 0; step < 40 && !(await target.evaluate(el => el === document.activeElement)); step++) {
      await page.keyboard.press("Tab");
    }
    await expect(target).toBeFocused();
    await page.keyboard.press("Enter");
    const sent = await lastFrame(page, "chrome_turn_selection_set");
    expect(sent.payload).toMatchObject({ version: 1 });
    await receive(page, { ...FIXTURE.web_frames.picker, request_generation: sent.request_generation });
    await page.keyboard.press("Escape");
    await expect(modal(page)).toBeEmpty();
    await expect(chip(page)).toBeVisible();
    const chipBox = await chip(page).boundingBox();
    expect(chipBox.x + chipBox.width).toBeLessThanOrEqual(width);
    await noHorizontalScroll(page, width);
    const clear = page.getByRole("button", { name: "Clear the selection for this chat", exact: true });
    await page.locator("#astral-input").focus();
    for (let step = 0; step < 12 && !(await clear.evaluate(el => el === document.activeElement)); step++) {
      await page.keyboard.press("Shift+Tab");
    }
    await expect(clear).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(chip(page)).toBeHidden();
    await expect(await advanced(page).isVisible()
      ? advanced(page) : page.locator("#astral-composer-more")).toBeFocused();
    expect("selection" in (await send(page, "Keyboard only")).payload).toBe(false);
  });
}
