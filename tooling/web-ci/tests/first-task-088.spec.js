// SC-007 / SC-002 first-task reachability. The REAL shipped shell template,
// the REAL server-rendered top bar, the REAL astral.css/client.js, and the
// tracked Work/notes surface fixtures — driven at 1440/768/320 px and at 320 px
// with 200% root text. Synthetic socket replies exercise presentation and the
// client reducer, not institutional IAM or a live staging deployment.
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { delimiter, resolve } from "node:path";

import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const ORIGIN = "http://first-task.test";

// One python hop renders the same chrome the server sends: the role-gated top
// bar, and the tracked Work surface frames put through the real web component
// renderer inside the real chrome modal shell.
const PY = [
  "import json",
  "from webrender import render_one",
  "from webrender.chrome import render_modal_shell",
  "from webrender.chrome.topbar import render_topbar",
  "frames = json.load(open('contracts/fixtures/work_088/read_surface.json', encoding='utf-8'))['frames']",
  "work = {name: render_modal_shell(frames[name]['title'],"
    + " ''.join(render_one(component) for component in frames[name]['components']), 'work')"
    + " for name in ('detail', 'unavailable')}",
  "print(json.dumps({'topbar': render_topbar(['user'], export_enabled=True, share_enabled=True,"
    + " pulse_enabled=True), 'work': work}))",
].join("\n");

const RENDERED = JSON.parse(execFileSync(process.env.ASTRAL_TEST_PYTHON || "python3", ["-c", PY], {
  cwd: ROOT,
  env: { ...process.env, PYTHONUTF8: "1", PYTHONPATH: [resolve(ROOT, "src"), resolve(ROOT, "backend")].join(delimiter) },
  encoding: "utf8",
  maxBuffer: 32 * 1024 * 1024,
}));

const NOTES = JSON.parse(await readFile(
  resolve(ROOT, "contracts/fixtures/guidance_088/notes_surface.json"), "utf8"));

// The composer's voice control ships disabled until the server's authoritative
// projection arrives; the tracked voice conformance vector is that projection.
const VOICE = JSON.parse(await readFile(
  resolve(ROOT, "contracts/fixtures/voice_065/client_conformance.json"), "utf8"))
  .cases.find(entry => entry.id === "C0")
  .positive.find(entry => entry.id === "C0-P1-composer").payload;

const SHELL = (await readFile(resolve(ROOT, "backend/webrender/templates/shell.html"), "utf8"))
  .replace(/\?v=%%ASTRAL_V:[^%]*%%/gu, "")
  .replaceAll("%%ASTRAL_NONCE%%", "first-task-nonce")
  .replaceAll("%%ASTRAL_TOKEN%%", "fixture-owner-token")
  .replaceAll("%%ASTRAL_RESUMED%%", "true")
  .replaceAll("%%ASTRAL_ACCEPT%%", ".txt,.pdf")
  .replaceAll("%%ASTRAL_LANDING%%", JSON.stringify({ agents: [], scenarios: [], categories: [] }))
  .replaceAll("%%ASTRAL_USER_NAME%%", "Fixture owner")
  .replaceAll("%%ASTRAL_USER_ROLE%%", "Member")
  .replace("%%ASTRAL_TOPBAR%%", () => RENDERED.topbar);

// Every control a first task needs, named by the role the success criteria use.
// Recent chats is not among them any more: on the web it opened the list that
// sits directly beneath it in the sidebar, and the owner took it off the
// History header on 2026-09-19. It is still in the chrome model, and a native
// client still receives it.
const CONTROLS = [
  ["New chat", "#astral-newchat-btn"],
  ["Settings", "#astral-settings-btn"],
  ["Composer", "#astral-input"],
  ["Paperclip", "#astral-attach-btn"],
  ["Voice", "#astral-voice-controls button[data-voice-key=\"voice-start\"]"],
  ["More options", "#astral-composer-more"],
  ["Background", "#astral-bg-btn"],
  ["Advanced", "#astral-advanced-btn"],
  ["Workspace timeline", "#astral-timeline-btn"],
  ["Pulse", "#astral-pulse-btn"],
  ["Send", "#astral-form button[type=\"submit\"]"],
];

/** UI v2 keeps secondary controls behind More options at every width. */
async function revealComposerControls(page) {
  const more = page.locator("#astral-composer-more");
  if (await more.isVisible() && await more.getAttribute("aria-expanded") !== "true") await more.click();
}

/** Below 1024 the sidebar is an off-canvas drawer (089 T053), so the controls
 *  it hosts sit outside the viewport until its toggle opens it. Open it, for
 *  the same reason: reachable is the claim, not permanently on screen. */
async function revealSidebar(page) {
  const toggle = page.locator("#astral-drawer-toggle");
  if (await toggle.isVisible() && await toggle.getAttribute("aria-expanded") !== "true") {
    await toggle.click();
  }
  // The drawer slides in. Measuring before it lands reads the position it is
  // travelling through, not the one it comes to rest at.
  await page.waitForFunction(() => {
    const sidebar = document.getElementById("astral-sidebar");
    return !sidebar || sidebar.getBoundingClientRect().x >= 0;
  });
}

async function closeSidebar(page) {
  const toggle = page.locator("#astral-drawer-toggle");
  if (await toggle.isVisible() && await toggle.getAttribute("aria-expanded") === "true") {
    await page.keyboard.press("Escape");
  }
}

async function receive(page, frame) {
  await page.evaluate(value => window.__sockets.at(-1).receive(value), frame);
}

async function setup(page, { width = 320, font = "100%" } = {}) {
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.setViewportSize({ width, height: 800 });
  await page.addInitScript(() => {
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
  await page.route(`${ORIGIN}/**`, async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") {
      await route.fulfill({ contentType: "text/html", body: SHELL });
      return;
    }
    if (path.startsWith("/static/")) {
      try {
        await route.fulfill({ path: resolve(STATIC, path.slice("/static/".length)) });
      } catch {
        await route.abort();
      }
      return;
    }
    await route.abort();
  });
  await page.goto(`${ORIGIN}/`);
  await page.waitForFunction(() => window.__frames.some(frame => frame.type === "register_ui"));
  if (font !== "100%") await page.evaluate(size => {
    document.documentElement.style.fontSize = size;
  }, font);
  // The authoritative composer projection enables the shipped voice control.
  const registration = await page.evaluate(() => window.__frames.find(f => f.type === "register_ui"));
  await receive(page, { ...VOICE, connection_generation: registration.connection_generation });
  await expect(page.locator("#astral-voice-controls button[data-voice-key=\"voice-start\"]")).toBeEnabled();
  expect(errors, "the real shell must initialize without JavaScript errors").toEqual([]);
  return registration;
}

async function openSurface(page, surface, params) {
  await page.evaluate(({ name, args }) => {
    let button = document.getElementById("astral-first-task-open");
    if (!button) {
      button = document.createElement("button");
      button.type = "button";
      button.id = "astral-first-task-open";
      document.body.append(button);
    }
    button.setAttribute("data-ui-action", "chrome_open");
    button.setAttribute("data-ui-payload", JSON.stringify({ surface: name, params: args }));
    button.click();
  }, { name: surface, args: params });
  return await page.evaluate(name => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === name).at(-1), surface);
}

async function noHorizontalScroll(page, width) {
  expect(await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }))).toEqual({ scrollWidth: width, clientWidth: width });
}

async function operable(page, names) {
  const viewport = await page.evaluate(() => window.innerWidth);
  for (const name of names) {
    const control = page.locator("#astral-modal").getByRole("button", { name, exact: true });
    await expect(control).toBeVisible();
    await expect(control).toBeEnabled();
    await control.click({ trial: true });
    const box = await control.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(viewport);
  }
}

// Below 1024 the shell has two regions rather than one flat surface: a
// focus-trapped sidebar drawer, and the composer, whose secondary controls sit
// behind one overflow button. They are deliberately never open together -- the
// drawer's backdrop covers the composer -- so each region is checked where its
// own controls live. Every control still has to be reachable and on screen.
const SIDEBAR = "#astral-sidebar";
const COMPOSER = "#astral-composer";

async function inRegion(page, scope) {
  return page.evaluate(([controls, selector]) => controls
    .map(([name, control]) => [name, document.querySelector(control)])
    .filter(([, element]) => element && element.closest(selector))
    .sort(([, a], [, b]) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1))
    .map(([name]) => name), [CONTROLS, scope]);
}

async function enterRegion(page, scope) {
  if (scope === SIDEBAR) {
    await revealSidebar(page);
  } else {
    await closeSidebar(page);
    await revealComposerControls(page);
  }
}

for (const [width, font] of [[1440, "100%"], [768, "100%"], [320, "100%"], [320, "200%"]]) {
  test(`the first task fits ${width}px at ${font} text without horizontal scrolling`, async ({ page }) => {
    await setup(page, { width, font });
    await noHorizontalScroll(page, width);
    const covered = [];
    for (const scope of [SIDEBAR, COMPOSER]) {
      await enterRegion(page, scope);
      for (const name of await inRegion(page, scope)) {
        const [, selector] = CONTROLS.find(([label]) => label === name);
        const control = page.locator(selector);
        await expect(control).toBeVisible();
        const box = await control.boundingBox();
        expect(box.x, `${name} must fit the viewport's left edge`).toBeGreaterThanOrEqual(0);
        expect(box.x + box.width, `${name} must fit the viewport's right edge`).toBeLessThanOrEqual(width);
        covered.push(name);
      }
      await noHorizontalScroll(page, width);
    }
    expect([...covered].sort()).toEqual(CONTROLS.map(([name]) => name).sort());
  });

  test(`every first-task control is tab reachable in DOM order at ${width}px / ${font}`, async ({ page }) => {
    await setup(page, { width, font });
    const observed = [];
    for (const scope of [SIDEBAR, COMPOSER]) {
      await enterRegion(page, scope);
      const present = await inRegion(page, scope);
      await page.evaluate(() => document.activeElement?.blur?.());
      const seen = [];
      for (let step = 0; step < 60 && seen.length < present.length; step++) {
        await page.keyboard.press("Tab");
        const name = await page.evaluate(([controls, selector]) => {
          const active = document.activeElement;
          if (!active?.closest?.(selector)) return null;
          const hit = controls.find(([, control]) => active.matches?.(control));
          return hit ? hit[0] : null;
        }, [CONTROLS, scope]);
        if (name && !seen.includes(name)) seen.push(name);
      }
      // Tab order must follow DOM order; where the walk happens to start is an
      // accident of what had focus when the region was entered, so compare the
      // sequence as the cycle it is rather than pinning its first element.
      const from = Math.max(present.indexOf(seen[0]), 0);
      expect(seen).toEqual([...present.slice(from), ...present.slice(0, from)]);
      observed.push(...seen);
    }
    expect([...observed].sort()).toEqual(CONTROLS.map(([name]) => name).sort());
  });
}

test("Enter in the composer sends exactly one chat message and opens no modal", async ({ page }) => {
  await setup(page, { width: 320, font: "200%" });
  await page.locator("#astral-input").fill("What is on my plate today?");
  await page.locator("#astral-input").press("Enter");
  await expect.poll(() => page.evaluate(() => window.__frames
    .filter(frame => frame.action === "chat_message").length)).toBe(1);
  const sent = await page.evaluate(() => window.__frames.find(frame => frame.action === "chat_message"));
  expect(sent.payload.message).toBe("What is on my plate today?");
  expect(await page.evaluate(() => window.__frames
    .filter(frame => frame.action === "chrome_open").length)).toBe(0);
  await expect(page.locator("#astral-modal")).toBeEmpty();
  await expect(page.locator("#astral-input")).toHaveValue("");
  await noHorizontalScroll(page, 320);
  // Shift+Enter keeps composing instead of sending a second turn.
  await page.locator("#astral-input").fill("second line");
  await page.locator("#astral-input").press("Shift+Enter");
  expect(await page.evaluate(() => window.__frames
    .filter(frame => frame.action === "chat_message").length)).toBe(1);
});

test("UI v2 options close on Escape, outside click and surface selection", async ({ page }) => {
  await setup(page, { width: 1440 });
  const more = page.getByRole("button", { name: "More options", exact: true });
  const menu = page.locator("#astral-composer-controls");
  await expect(menu).toBeHidden();
  await more.click();
  await expect(menu.getByRole("menuitem")).toHaveCount(4);
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(more).toBeFocused();
  await more.click();
  await page.getByRole("textbox", { name: "Message", exact: true }).click();
  await expect(menu).toBeHidden();
  for (const [label, surface] of [["Advanced settings", "guidance"],
    ["Workspace timeline", "workspace_timeline"], ["Pulse digest", "pulse"]]) {
    await more.click();
    await menu.getByRole("menuitem", { name: label, exact: true }).click();
    await expect(menu).toBeHidden();
    const request = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open").at(-1));
    expect(request.payload.surface).toBe(surface);
    await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: surface,
      request_generation: request.request_generation, html: "" });
  }
});

test("the Work modal stays operable at 320px with 200% text", async ({ page }) => {
  await setup(page, { width: 320, font: "200%" });
  const pending = await openSurface(page, "work", { mode: "detail" });
  await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: "work",
    request_generation: pending.request_generation, html: RENDERED.work.detail });
  await expect(page.locator("#astral-modal .astral-modal-card")).toBeVisible();
  await operable(page, ["View result", "Refresh", "Back to recent work", "Close"]);
  await noHorizontalScroll(page, 320);

  const retry = await openSurface(page, "work", { mode: "list" });
  await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: "work",
    request_generation: retry.request_generation, html: RENDERED.work.unavailable });
  await operable(page, ["Refresh"]);
  await noHorizontalScroll(page, 320);
  await page.locator("#astral-modal").getByRole("button", { name: "Refresh", exact: true }).click();
  const refreshed = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "work").at(-1));
  expect(refreshed.request_generation).not.toBe(retry.request_generation);
});

test("the notes editor stays operable at 320px with 200% text", async ({ page }) => {
  await setup(page, { width: 320, font: "200%" });
  const editing = await openSurface(page, "guidance", { mode: "edit" });
  await receive(page, { ...NOTES.web_frames.edit, request_generation: editing.request_generation });
  await expect(page.locator("#astral-modal .astral-modal-card")).toBeVisible();
  await operable(page, ["Back to notes", "Save note"]);
  await page.getByLabel("Note", { exact: true }).fill("Shorter paragraphs, please.");
  await expect(page.getByLabel("Note", { exact: true })).toHaveValue("Shorter paragraphs, please.");
  await noHorizontalScroll(page, 320);
  await page.locator("#astral-modal").getByRole("button", { name: "Save note", exact: true }).click();
  const saved = await page.evaluate(() => window.__frames
    .filter(frame => frame.action === "chrome_note_save").at(-1));
  expect(saved.payload.fields.value).toBe("Shorter paragraphs, please.");

  const forgetting = await openSurface(page, "guidance", { mode: "forget" });
  await receive(page, { ...NOTES.web_frames.forget, request_generation: forgetting.request_generation });
  await operable(page, ["Keep note", "Forget note"]);
  await noHorizontalScroll(page, 320);
});
