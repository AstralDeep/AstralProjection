// Canvas regression fixtures exercise real Plotly and downloaded HTML offline.
// These deterministic browser checks do not replace an authenticated live smoke.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const STATIC = resolve(ROOT, "backend/webrender/static");
const client = await readFile(resolve(STATIC, "client.js"), "utf8");
const chartCode = client.slice(client.indexOf("  var chartResizeObserver"), client.indexOf("  // ---- theme_apply:"));
const exportCode = client.slice(client.indexOf("  async function snapshotCanvasDocument"), client.indexOf("  function mintShare"));

async function setup(page, width = 1200) {
  await page.setViewportSize({ width, height: 900 });
  await page.route("http://canvas.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path.startsWith("/static/fonts/")) {
      await route.fulfill({ body: await readFile(resolve(STATIC, "fonts", path.split("/").at(-1))), contentType: "font/woff2" });
    } else if (path.startsWith("/api/export/canvas/")) {
      await route.fulfill({ body: "<!doctype html><p>Authorized server export</p>", contentType: "text/html", headers: { "X-Astral-Render-Revision": "8" } });
    } else if (path === "/") {
      await route.fulfill({ contentType: "text/html;charset=utf-8", body: `<!doctype html><html><head><meta charset="utf-8"></head><body data-astral-view="work" data-astral-layout="stacked">
        <div class="astral-app flex flex-col"><main class="flex flex-1 min-h-0">
        <section id="astral-canvas" class="astral-canvas-panel flex-1 overflow-y-auto p-4">
        <div class="dynamic-renderer space-y-3"><div class="astral-component"><div class="astral-card">
        <h3 class="text-base font-semibold">Lexington forecast</h3>
        <div class="astral-chart-card"><div class="astral-chart" data-chart-type="plotly" role="img" aria-label="High and low temperatures"></div></div>
        <div class="astral-chart-card"><div class="astral-chart" data-chart-type="plotly" role="img" aria-label="Precipitation"></div></div>
        <div class="astral-table-wrap"><div class="overflow-x-auto"><table class="w-full"><thead><tr><th>Date</th><th>High</th><th>Low</th><th>Precipitation</th></tr></thead><tbody>
        ${Array.from({ length: 7 }, (_, i) => `<tr><td>2026-09-${11 + i}</td><td>81.5°F</td><td>71.4°F</td><td>0.102 in</td></tr>`).join("")}
        </tbody></table></div></div>
        <div class="astral-provenance--grounded">✓ tool data</div>
        <div class="astral-component-chrome"><button data-ui-action="danger">Refine</button></div>
        <p onclick="window.injected=true" data-ctx="private">Complete seven-day forecast</p>
        </div></div></div></section>
        <aside class="astral-chat-panel"><textarea>Private conversation</textarea></aside>
        </main></div></body></html>` });
    } else {
      await route.abort();
    }
  });
  await page.goto("http://canvas.test/");
  await page.addStyleTag({ path: resolve(STATIC, "astral.css") });
  await page.addScriptTag({ path: resolve(STATIC, "vendor/tailwind.js") });
  await page.addScriptTag({ path: resolve(STATIC, "vendor/plotly.min.js") });
  await page.addScriptTag({ content: `var canvas=document.getElementById('astral-canvas'); var API_URL=location.origin; var token='fixture-token'; var activeChatId='chat-a'; var accountPrivacyEpoch=1; var revision=8; function lastCommittedRenderRevision(){return revision;} var errors=[]; function showToast(message){errors.push(message);} ${chartCode}\n${exportCode}` });
  await page.evaluate(async () => {
    const charts = document.querySelectorAll(".astral-chart");
    charts[0].dataset.chart = JSON.stringify({ data: [{ x: ["2026-09-11", "2026-09-12", "2026-09-13"], y: [81.5, 83.6, 89.5], name: "High", type: "scatter" }, { x: ["2026-09-11", "2026-09-12", "2026-09-13"], y: [71.4, 70.9, 67.4], name: "Low", type: "scatter" }], layout: { width: 1400, height: 320, xaxis: { title: "Date" } } });
    charts[1].dataset.chart = JSON.stringify({ data: [{ x: ["Mon", "Tue", "Wed"], y: [0.102, 0, 0], type: "bar" }], layout: { width: 1400 } });
    window.initCharts(document);
    await Promise.all(Array.from(charts, chart => chart._astralPlotReady));
    await document.fonts.ready;
  });
}

test("phone canvas contains charts and scrolls intact table values", async ({ page }) => {
  await setup(page, 393);
  const bounds = await page.evaluate(() => {
    const canvas = document.getElementById("astral-canvas");
    const scroll = document.querySelector(".astral-table-wrap > div");
    const cell = document.querySelector("td");
    return { viewport: innerWidth, pageWidth: document.documentElement.scrollWidth, canvasWidth: canvas.getBoundingClientRect().width,
      chartWidth: document.querySelector(".astral-chart .svg-container").getBoundingClientRect().width,
      scrollWidth: scroll.scrollWidth, containerWidth: scroll.clientWidth, cellHeight: cell.getBoundingClientRect().height,
      wrap: getComputedStyle(cell).whiteSpace, rows: document.querySelectorAll("tbody tr").length };
  });
  expect(bounds.pageWidth).toBeLessThanOrEqual(393);
  expect(bounds.canvasWidth).toBeLessThanOrEqual(393);
  expect(bounds.chartWidth).toBeLessThan(393);
  expect(bounds.wrap).toBe("nowrap");
  expect(bounds.rows).toBe(7);
  expect(bounds.scrollWidth).toBeGreaterThan(bounds.containerWidth);
  expect(bounds.cellHeight).toBeLessThan(55);
});

test("charts resize when available canvas width changes without window resize", async ({ page }) => {
  await setup(page);
  await page.evaluate(() => { document.getElementById("astral-canvas").style.maxWidth = "420px"; });
  await expect.poll(() => page.locator(".astral-chart .svg-container").first().evaluate(el => Math.round(el.getBoundingClientRect().width))).toBeLessThan(420);
});

test("authorized download preserves chart images theme and values without executable content", async ({ page }, testInfo) => {
  await setup(page);
  await page.evaluate(() => document.documentElement.style.setProperty("--astral-bg", "12 18 34"));
  const before = await page.locator("body").evaluate(el => getComputedStyle(el).backgroundColor);
  const download = page.waitForEvent("download");
  await page.evaluate(() => window.exportDownload("/api/export/canvas/chat-a.html", "canvas-chat-a.html", false, true));
  const result = await download;
  const path = testInfo.outputPath("canvas-chat-a.html");
  await result.saveAs(path);
  const html = await readFile(path, "utf8");
  expect(html.match(/data:image\/png;base64,/g)).toHaveLength(2);
  expect(html).toContain("2026-09-17");
  expect(html).toContain("0.102 in");
  expect(html).toContain("81.5°F");
  expect(html).toContain("data:font/woff2;base64,");
  for (const text of ["<script", "onclick", "data-ctx", "private", "Private conversation", "Refine", "tool data", "fixture-token", "<button", "<textarea"]) expect(html).not.toContain(text);
  expect(html).toContain("script-src 'none'");
  await page.setContent(html);
  await expect(page.locator("img")).toHaveCount(2);
  expect(await page.locator("body").evaluate(el => getComputedStyle(el).backgroundColor)).toBe(before);
  expect(await page.locator("img").evaluateAll(images => images.every(image => image.complete && image.naturalWidth > 0))).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("canvas-export.png"), fullPage: true });
});

test("denied export never creates a local snapshot or download", async ({ page }) => {
  await setup(page);
  await page.route("**/api/export/canvas/**", route => route.fulfill({ status: 403, body: "Forbidden" }));
  const downloads = [];
  page.on("download", item => downloads.push(item));
  await page.evaluate(() => window.exportDownload("/api/export/canvas/chat-a.html", "canvas.html", false, true));
  await expect.poll(() => page.evaluate(() => window.errors)).toEqual(["Export failed (403)"]);
  expect(downloads).toHaveLength(0);
});

test("chat switch while export authorization is pending discards capture", async ({ page }) => {
  await setup(page);
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  await page.route("**/api/export/canvas/**", async route => { await pending; await route.fulfill({ body: "authorized" }); });
  const request = page.waitForRequest("**/api/export/canvas/**");
  await page.evaluate(() => { window.exportPending = window.exportDownload("/api/export/canvas/chat-a.html", "canvas.html", false, true); });
  await request;
  await page.evaluate(() => { window.activeChatId = "chat-b"; window.snapshotCanvasDocument = () => { throw new Error("Should not capture"); }; });
  release();
  await page.evaluate(() => window.exportPending);
  expect(await page.evaluate(() => window.errors)).toEqual([]);
});

test("unready charts report failure instead of silently losing their data", async ({ page }) => {
  await setup(page);
  await page.evaluate(() => { delete document.querySelector(".astral-chart").dataset.rendered; });
  const error = await page.evaluate(() => window.snapshotCanvasDocument().then(() => "unexpected success", error => error.message));
  expect(error).toContain("Charts are still loading");
});

for (const change of ["owner", "revision"]) {
  test(`${change} change during asynchronous chart capture discards download`, async ({ page }) => {
    await setup(page);
    const downloads = [];
    page.on("download", item => downloads.push(item));
    const response = page.waitForResponse("**/api/export/canvas/**");
    await page.evaluate(() => {
      const chart = document.querySelector(".astral-chart");
      chart._astralPlotReady = new Promise(resolve => { window.finishChart = resolve; });
      window.exportPending = window.exportDownload("/api/export/canvas/chat-a.html", "canvas.html", false, true);
    });
    await response;
    await page.evaluate(change => {
      if (change === "owner") window.accountPrivacyEpoch++;
      else window.revision++;
      window.finishChart();
    }, change);
    await page.evaluate(() => window.exportPending);
    expect(downloads).toHaveLength(0);
  });
}

test("stale server revision rejects visual capture", async ({ page }) => {
  await setup(page);
  await page.route("**/api/export/canvas/**", route => route.fulfill({ status: 409, body: "Canvas changed" }));
  await page.evaluate(() => window.exportDownload("/api/export/canvas/chat-a.html", "canvas.html", false, true));
  expect(await page.evaluate(() => window.errors)).toEqual(["Canvas changed. Reload the chat before exporting."]);
});

test("offline snapshot removes active tags URL attributes and network CSS", async ({ page }) => {
  await setup(page);
  await page.evaluate(() => {
    const region = document.querySelector(".astral-card");
    const link = document.createElement("a");
    link.href = "javascript:alert(1)";
    link.setAttribute("ping", "https://external.invalid/track");
    link.style.backgroundImage = "url(https://external.invalid/image.png)";
    link.textContent = "Safe label";
    region.appendChild(link);
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.innerHTML = '<script>alert(1)</script><foreignObject>unsafe</foreignObject>';
    region.appendChild(svg);
  });
  const html = await page.evaluate(() => window.snapshotCanvasDocument().then(blob => blob.text()));
  for (const text of ["external.invalid", "javascript:", "<svg", "<script", "foreignObject", "ping="]) expect(html).not.toContain(text);
  expect(html).toContain("Safe label");
  expect(html).not.toContain("data:image/svg");
});

test("restore-to-sidebar button obeys the hidden attribute with live CSS", async ({ page }) => {
  await setup(page, 393);
  await page.evaluate(() => {
    const button = document.createElement("button");
    button.id = "astral-restore-chat-btn";
    button.className = "astral-attach-btn";
    button.hidden = true;
    document.body.appendChild(button);
  });
  await expect(page.locator("#astral-restore-chat-btn")).toBeHidden();
});
