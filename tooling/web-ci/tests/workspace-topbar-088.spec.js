// Actual shared renderer/CSS plus the shipped canvas visibility reducer.
// Synthetic authenticated-context flags exercise presentation, not release IAM.
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const topbar = execFileSync(process.env.ASTRAL_TEST_PYTHON || "python3", ["-c",
  "from webrender.chrome.topbar import render_topbar; print(render_topbar(['user'], export_enabled=True, share_enabled=True, pulse_enabled=True))"],
{ cwd: ROOT, env: { ...process.env, PYTHONPATH: `${resolve(ROOT, "src")}:${resolve(ROOT, "backend")}` }, encoding: "utf8" });
const client = await readFile(resolve(STATIC, "client.js"), "utf8");
const start = client.indexOf("  var canvasFlags = ");
const visibility = client.slice(start, client.indexOf('  document.addEventListener("click"', start));
const ids = ["astral-newchat-btn", "astral-chats-btn", "astral-export-page-btn",
  "astral-share-page-btn", "astral-pulse-btn", "astral-timeline-btn", "astral-settings-btn"];

async function setup(page, width, font = 16) {
  await page.setViewportSize({ width, height: 900 });
  await page.route("http://chrome.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") {
      await route.fulfill({ contentType: "text/html", body: `<!doctype html><html><body data-astral-layout="stacked" data-astral-view="work"><header id="astral-topbar">${topbar}</header><section id="astral-canvas"><div class="dynamic-renderer" data-astral-export="1" data-astral-share="1"></div></section></body></html>` });
    } else if (path.startsWith("/static/")) {
      await route.fulfill({ body: await readFile(resolve(STATIC, path.slice(8))) });
    } else await route.abort();
  });
  await page.goto("http://chrome.test/");
  await page.addScriptTag({ path: resolve(STATIC, "vendor/tailwind.js") });
  await page.addStyleTag({ path: resolve(STATIC, "astral.css") });
  await page.evaluate(font => { document.documentElement.style.fontSize = `${font}px`; }, font);
  await page.addScriptTag({ content: `var canvas = document.getElementById('astral-canvas'); var timelineMode = false; ${visibility}; readCanvasFlags(); syncCanvasToolbar();` });
  await expect(page.locator("#astral-share-page-btn")).toBeVisible();
}

for (const [width, font] of [[320, 16], [320, 32], [393, 16], [1200, 16]]) {
  test(`all topbar controls remain ordered and reachable at ${width}px with ${font}px text`, async ({ page }) => {
    await setup(page, width, font);
    const boxes = [];
    for (const id of ids) {
      const button = page.locator(`#${id}`);
      await expect(button).toBeVisible();
      await expect(button).toBeEnabled();
      await button.click({ trial: true });
      boxes.push(await button.boundingBox());
    }
    for (const box of boxes) {
      expect(box.x).toBeGreaterThanOrEqual(0);
      expect(box.x + box.width).toBeLessThanOrEqual(width);
    }
    for (let i = 1; i < boxes.length; i++) {
      expect(boxes[i].y).toBeGreaterThanOrEqual(boxes[i - 1].y);
      if (boxes[i].y === boxes[i - 1].y) expect(boxes[i].x).toBeGreaterThan(boxes[i - 1].x);
    }
    const layout = await page.locator("#astral-topbar").evaluate(el => ({
      height: el.getBoundingClientRect().height,
      bottom: el.getBoundingClientRect().bottom,
      scrollWidth: document.documentElement.scrollWidth,
      wrap: getComputedStyle(el.firstElementChild.lastElementChild).flexWrap,
    }));
    expect(layout.scrollWidth).toBeLessThanOrEqual(width);
    expect(layout.bottom).toBeGreaterThanOrEqual(Math.max(...boxes.map(box => box.y + box.height)));
    if (width === 320 && font === 32) expect(new Set(boxes.map(box => box.y)).size).toBeGreaterThan(1);
    if (width >= 700) expect(new Set(boxes.map(box => box.y)).size).toBe(1);
    expect(layout.wrap).toBe(width < 700 ? "wrap" : "nowrap");
    // The dropdown remains outside the wrapping cluster's flow and unclipped.
    await page.locator("#astral-settings-menu").evaluate(el => { el.hidden = false; });
    const menu = await page.locator("#astral-settings-menu").boundingBox();
    expect(menu.x).toBeGreaterThanOrEqual(0);
    expect(menu.x + menu.width).toBeLessThanOrEqual(width);
  });
}

test("server canvas capability and timeline still govern workspace visibility", async ({ page }) => {
  await setup(page, 320);
  await page.evaluate(() => { window.timelineMode = true; window.syncCanvasToolbar(); });
  await expect(page.locator("#astral-export-page-btn")).toBeHidden();
  await expect(page.locator("#astral-share-page-btn")).toBeHidden();
  await page.evaluate(() => {
    window.timelineMode = false;
    document.querySelector(".dynamic-renderer").removeAttribute("data-astral-share");
    window.readCanvasFlags(); window.syncCanvasToolbar();
  });
  await expect(page.locator("#astral-export-page-btn")).toBeVisible();
  await expect(page.locator("#astral-share-page-btn")).toBeHidden();
  await page.evaluate(() => {
    document.querySelector(".dynamic-renderer").remove();
    window.readCanvasFlags(); window.syncCanvasToolbar();
  });
  await expect(page.locator("#astral-export-page-btn")).toBeHidden();
  await expect(page.locator("#astral-settings-btn")).toBeVisible();
});
