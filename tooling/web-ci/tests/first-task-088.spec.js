// Browser tests for first-task reachability against the real shipped shell, top bar, and client
// script (src/astralprojection/resources.py): controls stay reachable and on screen at desktop,
// tablet, and 320px/200%-text viewports.

import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { delimiter, dirname, resolve } from "node:path";

import { expect, test } from "@playwright/test";

import { collectClientCoverage } from "./client-coverage-fixture.mjs";

collectClientCoverage(test, "first-task-088");

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const ORIGIN = "http://first-task.test";
const CLIENT = resolve(STATIC, "client.js");
const SOURCE = await readFile(CLIENT, "utf8");
const coverageOutput = process.env.ASTRAL_FIRST_TASK_COVERAGE_OUTPUT;
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




const PY = [
  "import json",
  "from webrender import render_one",
  "from webrender.chrome import render_modal_shell, render_settings_nav",
  "from webrender.chrome.menu_model import build_menu_model",
  "from webrender.chrome.topbar import render_topbar",
  "frames = json.load(open('contracts/fixtures/work_088/read_surface.json', encoding='utf-8'))['frames']",
  "work = {name: render_modal_shell(frames[name]['title'],"
    + " ''.join(render_one(component) for component in frames[name]['components']), 'work')"
    + " for name in ('detail', 'unavailable')}",
  "reasoning = render_one({'type': 'collapsible', 'title': 'Reasoning', 'content': [{'type': 'text', 'content': 'Planning step. ' * 300}]})",
  "print(json.dumps({'topbar': render_topbar(['user'], export_enabled=True, share_enabled=True,"
    + " pulse_enabled=True), 'work': work, 'reasoning': reasoning, 'agent_example': render_modal_shell('Agent examples', '%%EXAMPLE_BODY%%', 'agent_intro'), 'settings': render_modal_shell('Agents & permissions', '', 'agents',"
    + " nav_html=render_settings_nav(build_menu_model(['user']), 'agents'))}))",
].join("\n");

const RENDERED = JSON.parse(execFileSync(process.env.ASTRAL_TEST_PYTHON || "python3", ["-c", PY], {
  cwd: ROOT,
  env: { ...process.env, PYTHONUTF8: "1", PYTHONPATH: [resolve(ROOT, "src"), resolve(ROOT, "backend")].join(delimiter) },
  encoding: "utf8",
  maxBuffer: 32 * 1024 * 1024,
}));

const NOTES = JSON.parse(await readFile(
  resolve(ROOT, "contracts/fixtures/guidance_088/notes_surface.json"), "utf8"));



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
  .replaceAll("%%ASTRAL_USER_NAME%%", "Fixture owner")
  .replaceAll("%%ASTRAL_USER_ROLE%%", "Member")
  .replace("%%ASTRAL_TOPBAR%%", () => RENDERED.topbar);






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


async function revealComposerControls(page) {
  const more = page.locator("#astral-composer-more");
  if (await more.isVisible() && await more.getAttribute("aria-expanded") !== "true") await more.click();
}




async function revealSidebar(page) {
  const toggle = page.locator("#astral-drawer-toggle");
  if (await toggle.isVisible() && await toggle.getAttribute("aria-expanded") !== "true") {
    await toggle.click();
  }


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

async function setup(page, { width = 320, font = "100%", landing = { agents: [], scenarios: [], categories: [] } } = {}) {
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
      await route.fulfill({ contentType: "text/html", body: SHELL.replaceAll("%%ASTRAL_LANDING%%", JSON.stringify(landing)) });
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

async function startTour(page, targets) {
  const pending = await openSurface(page, "tour", {});
  const steps = targets.map(key => ({ target_kind: "static", target_key: key, title: key, body: "Tour fixture" }));
  await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: "tour",
    request_generation: pending.request_generation,
    html: `<div data-tour-steps='${JSON.stringify(steps)}'></div>` });
}

async function replyWithSettings(page) {
  const pending = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open").at(-1));
  expect(pending.payload.surface).toBe("agents");
  await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: "agents",
    request_generation: pending.request_generation, html: RENDERED.settings });
}

for (const [width, font] of [[1440, "100%"], [320, "200%"]]) {
  test(`the persisted tour moves between settings and the real timeline menu at ${width}px/${font}`, async ({ page }) => {
    await setup(page, { width, font });
    await startTour(page, ["sidebar.agents", "topbar.timeline", "canvas.workspace"]);
    await replyWithSettings(page);
    await expect(page.locator('[data-tour-target="sidebar.agents"]')).toHaveClass(/astral-tour-highlight/u);
    await expect(page.locator("#astral-tour-card")).not.toContainText("isn’t available");
    await page.getByRole("button", { name: "Next", exact: true }).click();
    await expect(page.locator("#astral-modal")).toBeEmpty();
    await expect(page.locator("#astral-composer-more")).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator("#astral-timeline-btn")).toBeVisible();
    await expect(page.locator("#astral-timeline-btn")).toHaveClass(/astral-tour-highlight/u);
    await expect(page.locator("#astral-tour-card")).not.toContainText("isn’t available");
    await noHorizontalScroll(page, width);
    await page.getByRole("button", { name: "Back", exact: true }).click();
    await replyWithSettings(page);
    await expect(page.locator("#astral-composer-more")).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator('[data-tour-target="sidebar.agents"]')).toHaveClass(/astral-tour-highlight/u);
    await page.getByRole("button", { name: "Next", exact: true }).click();
    await page.getByRole("button", { name: "Skip tour", exact: true }).click();
    await expect(page.locator("#astral-tour-card")).toHaveCount(0);
    await expect(page.locator("#astral-composer-more")).toHaveAttribute("aria-expanded", "false");
  });
}

test("a missing first settings target is reported after one server response, without retrying forever", async ({ page }) => {
  await setup(page);
  await startTour(page, ["sidebar.unavailable"]);
  await replyWithSettings(page);
  await expect(page.locator("#astral-tour-card")).toContainText("isn’t available");
  expect(await page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open"
    && frame.payload.surface === "agents").length)).toBe(1);
  await page.getByRole("button", { name: "Finish", exact: true }).click();
  await expect(page.locator("#astral-tour-card")).toHaveCount(0);
  await expect(page.locator("#astral-modal")).toBeEmpty();
});

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

for (const [width, font] of [[1440, "100%"], [1440, "200%"], [1024, "100%"],
  [768, "100%"], [768, "200%"], [390, "100%"], [320, "100%"], [320, "200%"]]) {
  test(`the first task fits ${width}px at ${font} text without horizontal scrolling`, async ({ page }, testInfo) => {
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
      if (scope === COMPOSER) {
        const menu = page.locator("#astral-composer-controls");
        const bounds = await menu.boundingBox();
        expect(bounds.x).toBeGreaterThanOrEqual(0);
        expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
        expect(bounds.y).toBeGreaterThanOrEqual(0);
        for (const item of await menu.getByRole("menuitem").all()) {


          expect(await item.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
          await item.click({ trial: true });
        }
        await testInfo.attach(`composer-${width}-${font}.png`, {
          body: await page.screenshot(), contentType: "image/png",
        });
      }
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



      const from = Math.max(present.indexOf(seen[0]), 0);
      expect(seen).toEqual([...present.slice(from), ...present.slice(0, from)]);
      observed.push(...seen);
    }
    expect([...observed].sort()).toEqual(CONTROLS.map(([name]) => name).sort());
  });
}

for (const [width, font] of [[1440, "100%"], [320, "100%"], [320, "200%"]]) {
  test(`bounded result preview keeps collapse and full screen operable at ${width}px/${font}`, async ({ page }) => {
    await setup(page, { width, font });
    const html = '<div class="dynamic-renderer" data-astral-export="true" data-astral-share="true"><div class="astral-component" data-component-id="responsive-result"><label>Workspace note<input aria-label="Workspace note" value="Retain this note"></label><div style="height:900px">A tall interactive result</div><button type="button">Last workspace action</button></div></div>';
    await page.evaluate(markup => window.__ASTRAL_PARITY__.seedConversation({
      query: "Show a detailed result",
      agent_id: "Specialist with a descriptive result title",
      ui_html: markup,
    }), html);
    await receive(page, { type: "ui_update", html });
    const card = page.locator('[data-astral-live-turn] .sdui-widget-container');
    const body = card.locator(".sdui-widget-body");
    const collapse = card.getByRole("button", { name: "Collapse container", exact: true });
    const expand = card.getByRole("button", { name: "Open this result in full screen", exact: true });
    await expect(body).toHaveClass(/has-overflow/u);
    await expect(body.locator(".sdui-widget-expand-chip")).toBeVisible();
    expect((await card.boundingBox()).height).toBeLessThanOrEqual(441);
    await noHorizontalScroll(page, width);
    for (const control of [collapse, expand, page.locator("#astral-export-page-btn"), page.locator("#astral-share-page-btn")]) {
      await expect(control).toBeVisible();
      await control.click({ trial: true });
      const box = await control.boundingBox();
      expect(box.x).toBeGreaterThanOrEqual(0);
      expect(box.x + box.width).toBeLessThanOrEqual(width);
    }
    await collapse.click();
    await expect(body).toBeHidden();
    const restore = card.getByRole("button", { name: "Expand container", exact: true });
    await expect(restore).toHaveAttribute("aria-expanded", "false");
    await expand.click({ trial: true });
    await restore.click();
    await expect(body).toBeVisible();
    await expect(body).toHaveClass(/has-overflow/u);
    await page.evaluate(() => { window.__responsiveInput = document.querySelector('[aria-label="Workspace note"]'); });
    await expand.click();
    const fullscreen = page.locator("#astral-fullscreen");
    const fullBody = fullscreen.locator(".sdui-widget-body");
    await expect(fullscreen).toBeVisible();
    await expect(fullBody).toHaveCSS("max-height", "none");
    expect((await fullBody.boundingBox()).height).toBeGreaterThan(900);
    await expect(fullBody.locator(".sdui-widget-overlay")).toBeHidden();
    await expect(page.locator("#astral-fs-actions #astral-export-page-btn")).toBeVisible();
    await expect(page.locator("#astral-fs-actions #astral-share-page-btn")).toBeVisible();
    await expect(page.getByRole("textbox", { name: "Workspace note" })).toHaveValue("Retain this note");
    await page.getByRole("textbox", { name: "Workspace note" }).fill("Edited in full screen");
    const first = fullscreen.locator("#astral-export-page-btn");
    const last = fullscreen.getByRole("button", { name: "Last workspace action", exact: true });
    await first.focus();
    await page.keyboard.press("Shift+Tab");
    await expect(last).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(first).toBeFocused();
    await expect(page.locator(".astral-app")).toHaveJSProperty("inert", true);
    await noHorizontalScroll(page, width);
    await page.keyboard.press("Escape");
    await expect(fullscreen).toBeHidden();
    await expect(expand).toBeFocused();
    await expect(page.locator(".astral-app")).toHaveJSProperty("inert", false);
    expect(await page.evaluate(() => document.querySelector('[aria-label="Workspace note"]') === window.__responsiveInput)).toBe(true);
    await expect(page.getByRole("textbox", { name: "Workspace note" })).toHaveValue("Edited in full screen");
    await expect(card.locator("#astral-export-page-btn")).toBeVisible();
    await expect(card.locator("#astral-share-page-btn")).toBeVisible();
    await expect(body.locator(".sdui-widget-expand-chip")).toBeVisible();
  });
}


test("result controls expand the live chart and resize it again when restored", async ({ page }) => {
  await setup(page, { width: 1440 });
  await page.evaluate(() => {
    window.__chartResizes = [];
    window.Plotly = { Plots: { resize(node) {
      window.__chartResizes.push({ fullScreen: Boolean(node.closest("#astral-fs-canvas")), width: node.parentElement.clientWidth });
      node.style.width = `${node.parentElement.clientWidth}px`;
    } } };
    window.__ASTRAL_PARITY__.seedConversation({
      query: "Show the complete chart",
      agent_id: "Chart Specialist",
      ui_html: '<div class="js-plotly-plot" style="height:900px">Chart result</div>',
    });
    window.__liveChart = document.querySelector(".js-plotly-plot");
  });
  const card = page.locator('[data-astral-live-turn] .sdui-widget-container');
  const body = card.locator(".sdui-widget-body");
  await expect(body).toHaveClass(/has-overflow/u);
  await expect(card.locator(".window-dot")).toHaveCount(0);
  await card.getByRole("button", { name: "Collapse container", exact: true }).click();
  await expect(body).toBeHidden();
  await card.getByRole("button", { name: "Expand container", exact: true }).click();
  await expect(body).toBeVisible();
  await expect(card).toHaveCSS("box-shadow", "none");
  await card.hover();
  await expect(card).toHaveCSS("box-shadow", "none");
  await card.getByRole("button", { name: "Open this result in full screen" }).click();
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  await expect.poll(() => page.evaluate(() => window.__chartResizes.some(entry => entry.fullScreen))).toBe(true);
  expect(await page.evaluate(() => document.querySelector("#astral-fs-canvas .js-plotly-plot") === window.__liveChart)).toBe(true);
  await page.locator("#astral-fs-exit").click();
  await expect.poll(() => page.evaluate(() => window.__chartResizes.some(entry => !entry.fullScreen))).toBe(true);
  const dimensions = await page.evaluate(() => window.__chartResizes);
  expect(dimensions.find(entry => entry.fullScreen).width).toBeGreaterThan(dimensions.find(entry => !entry.fullScreen).width);
  await body.locator(".sdui-widget-expand-chip").click();
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  await expect(page.locator("#astral-fs-canvas")).toContainText("Chart result");
  await page.keyboard.press("Escape");
  expect(await page.evaluate(() => document.querySelector("#astral-chat .js-plotly-plot") === window.__liveChart)).toBe(true);
});


test("keyboard focus reveals a clipped result input in full screen", async ({ page }) => {
  await setup(page, { width: 320 });
  await page.evaluate(() => window.__ASTRAL_PARITY__.seedConversation({
    query: "Edit a detailed result",
    agent_id: "Specialist",
    ui_html: '<div style="height:900px">Detailed result</div><label>Result annotation<input aria-label="Result annotation"></label>',
  }));
  const body = page.locator('[data-astral-live-turn] .sdui-widget-body');
  await expect(body).toHaveClass(/has-overflow/u);
  await page.getByRole("button", { name: "Open this result in full screen" }).focus();
  await page.keyboard.press("Tab");
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  const input = page.getByRole("textbox", { name: "Result annotation" });
  await expect(input).toBeFocused();
  await input.fill("Accessible through the keyboard");
  await expect(input).toHaveValue("Accessible through the keyboard");
  await page.keyboard.press("Escape");
  await expect(page.locator("#astral-fullscreen")).toBeHidden();
  await expect(page.getByRole("textbox", { name: "Result annotation" })).toHaveValue("Accessible through the keyboard");
});


test("settings status colors and actions follow the current shared theme", async ({ page }) => {
  await setup(page, { width: 768 });


  await page.evaluate(() => {
    const surface = document.createElement("section");
    surface.id = "palette-probe";
    surface.dataset.chromeSurface = "theme";
    for (const variant of ["success", "warning", "error"]) {
      const badge = document.createElement("span");
      badge.role = "status";
      badge.dataset.badgeVariant = variant;
      badge.textContent = variant;
      const alert = document.createElement("div");
      alert.dataset.alertVariant = variant;
      alert.textContent = variant;
      surface.append(badge, alert);
    }
    for (const action of ["save", "forget"]) {
      const button = document.createElement("button");
      button.dataset.uiAction = `chrome_note_${action}`;
      if (action === "save") button.dataset.buttonVariant = "primary";
      button.textContent = action;
      surface.append(button);
    }
    document.getElementById("astral-canvas").append(surface);
  });
  const readColors = () => page.locator("#palette-probe").evaluate(el =>
    [...el.children].map(child => {
      const style = getComputedStyle(child);
      return { color: style.color, background: style.backgroundColor, border: style.borderTopColor };
    }));
  const dark = await readColors();
  await page.evaluate(() => {
    const style = document.documentElement.style;
    style.setProperty("--astral-bg", "248 250 252");
    style.setProperty("--astral-surface", "255 255 255");
    style.setProperty("--astral-text", "15 23 42");
    style.setProperty("--astral-primary", "29 78 216");
  });
  const light = await readColors();
  for (let index = 0; index < dark.length; index++) {
    expect(light[index].color, `settings control ${index} must follow the theme`).not.toBe(dark[index].color);
  }


  await page.evaluate(() => {
    for (const role of ["success", "warning", "error"]) {
      document.documentElement.style.setProperty(`--color-${role}`, "91 33 182");
    }
  });
  const changed = await readColors();
  for (let index = 0; index < 6; index++) {
    for (const property of ["color", "background", "border"]) {
      expect(changed[index][property]).not.toBe(light[index][property]);
    }
  }
});

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


for (const width of [1440, 320]) {
  test(`agent example Run loads the composer and sends one ordinary turn at ${width}px`, async ({ page }) => {
    await setup(page, { width });
    const prompt = 'Build a grant-spend workbook with monthly detail and a summary sheet.';
    const pending = await openSurface(page, "agent_intro", { agent_id: "connectors" });
    const payload = JSON.stringify({ message: prompt });
    await receive(page, { type: "chrome_render", region: "modal", mode: "replace", surface_key: "agent_intro",
      request_generation: pending.request_generation,
      html: RENDERED.agent_example.replace("%%EXAMPLE_BODY%%", `<div class="astral-agent-example"><button data-ui-action="chat_message" data-ui-payload='${payload}'>Run workbook</button></div>`) });
    await page.getByRole("button", { name: "Run workbook", exact: true }).click();
    await expect(page.locator("#astral-modal")).toBeEmpty();
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveValue(prompt);
    await expect(page.locator(".astral-user-bubble")).toContainText(prompt);
    const sends = await page.evaluate(() => window.__frames.filter(frame => frame.action === "chat_message"));
    expect(sends).toHaveLength(1);
    expect(sends[0].payload.message).toBe(prompt);
    expect(sends[0].submission_id).toMatch(/^[0-9a-f-]{36}$/u);
    expect(sends[0].payload.snapshot_purpose).toBe("commit");
    await noHorizontalScroll(page, width);
  });
}

test("scenario Run loads its prompt and empty examples never submit", async ({ page }) => {
  const prompt = "Compare monthly grant spending across two programs";
  await setup(page, { width: 1440, landing: { agents: [], categories: ["Analysis"], scenarios: [
    { title: "Grant comparison", category: "Analysis", prompt },
    { title: "Empty example", category: "Analysis", prompt: " " },
  ] } });
  await page.getByRole("button", { name: "Run: Empty example", exact: true }).click();
  expect(await page.evaluate(() => window.__frames.filter(frame => frame.action === "chat_message"))).toEqual([]);
  await page.getByRole("button", { name: "Run: Grant comparison", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveValue(prompt);
  expect(await page.evaluate(() => window.__frames.filter(frame => frame.action === "chat_message").length)).toBe(1);
});

test("reasoning remains a compact keyboard-operable disclosure", async ({ page }) => {
  await setup(page, { width: 320 });
  await receive(page, { type: "ui_render", target: "chat", html: RENDERED.reasoning });
  const reasoning = page.locator(".astral-reasoning");
  const body = reasoning.locator(":scope > div");
  await expect(body).toBeHidden();
  await reasoning.locator("summary").focus();
  await page.keyboard.press("Enter");
  await expect(body).toBeVisible();
  expect(await body.evaluate(node => node.clientHeight)).toBeLessThanOrEqual(160);
  expect(await body.evaluate(node => node.scrollHeight)).toBeGreaterThan(160);
  await noHorizontalScroll(page, 320);
  await reasoning.locator("summary").press("Enter");
  await expect(body).toBeHidden();
});

for (const [width, font] of [[1440, "100%"], [320, "200%"]]) {
  test(`summary bubble and separate reasoning fit ${width}px at ${font} text`, async ({ page }) => {
    await setup(page, { width, font });
    await receive(page, { type: "ui_render", target: "canvas", html: "<p>Grant workbook</p>" });
    await receive(page, { type: "ui_render", target: "chat", html: `${RENDERED.reasoning}<p>Your grant workbook is ready. Download ${"grant_summary_".repeat(30)}.xlsx.</p>` });
    const summary = page.locator(".chat-text-summary");
    await expect(summary).toHaveCount(1);
    await expect(summary).toHaveCSS("border-top-width", "1px");
    await expect(summary).toHaveCSS("border-radius", "12px");
    await expect(summary.locator(".astral-reasoning")).toHaveCount(0);
    await expect(page.locator(".astral-reasoning-turn summary")).toBeVisible();
    await noHorizontalScroll(page, width);
  });
}
