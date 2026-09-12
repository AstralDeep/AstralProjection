// Real bundled browser export; synthetic data only, no runtime/user credentials.
import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { convertPlaywrightV8Coverage } from "../coverage-conversion.mjs";

const ROOT = resolve(import.meta.dirname, "../../..");
const template = await readFile(resolve(ROOT, "contracts/assets/exports/export.html"), "utf8");
const vendor = await readFile(resolve(ROOT, "backend/webrender/static/vendor/plotly.min.js"), "utf8");
const exportSources = await Promise.all(["canvas-export.js", "canvas-export-host.js"].map(async name => {
  const path = `backend/webrender/static/${name}`;
  return { path, source: await readFile(resolve(ROOT, path), "utf8") };
}));
const coverageOutput = process.env.ASTRAL_EXPORT_COVERAGE_OUTPUT;
const coverageDocuments = [];

test.beforeEach(async ({ page, browserName }) => {
  if (!coverageOutput) return;
  if (browserName !== "chromium") throw new Error("Export coverage requires pinned Chromium");
  await page.coverage.startJSCoverage({ reportAnonymousScripts: true, resetOnNavigation: false });
});

test.afterEach(async ({ page }) => {
  if (!coverageOutput) return;
  for (const entry of await page.coverage.stopJSCoverage()) {
    const exact = exportSources.find(candidate => candidate.source === entry.source);
    if (exact) coverageDocuments.push(await convertPlaywrightV8Coverage(
      [{ ...entry, sourcePath: exact.path }], candidate => candidate.sourcePath,
    ));
  }
});

test.afterAll(async () => {
  if (!coverageOutput) return;
  if (!coverageDocuments.length) throw new Error("Missing exact export browser coverage");
  const output = { ...coverageDocuments[0], coverage: {} };
  for (const document of coverageDocuments) {
    for (const [path, record] of Object.entries(document.coverage)) {
      const prior = output.coverage[path];
      if (!prior) output.coverage[path] = structuredClone(record);
      else {
        if (JSON.stringify(prior.statementMap) !== JSON.stringify(record.statementMap)) throw new Error("Export source changed during coverage collection");
        for (const [key, count] of Object.entries(record.s)) prior.s[key] = prior.s[key] > 0 || count > 0 ? 1 : 0;
      }
    }
  }
  await mkdir(dirname(resolve(coverageOutput)), { recursive: true });
  await writeFile(resolve(coverageOutput), JSON.stringify(output, null, 2) + "\n", { mode: 0o600 });
  for (const { path } of exportSources) {
    const counts = Object.values(output.coverage[path]?.s || {});
    expect(counts.length, path).toBeGreaterThan(0);
    expect(counts.filter(count => count > 0).length / counts.length, path).toBeGreaterThanOrEqual(.90);
  }
});
const theme = { bg: "#0F1221", surface: "#1A1E2E", surface2: "#1E2338", border: "#FFFFFF14", primary: "#6366F1",
  secondary: "#8B5CF6", accent: "#06B6D4", text: "#F3F4F6", muted: "#9CA3AF", success: "#22C55E", warning: "#EAB308", error: "#EF4444", info: "#3B82F6" };

const PIXEL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNITvv4HwAFpAK6buOwBAAAAABJRU5ErkJggg==";

function presentation(width = 393, colors = theme, pixels = PIXEL, windowWidth = width) {
  const input = { version: "astral.canvas-export/v1", viewport: { width, height: 852, window_width: windowWidth, window_height: 900 }, theme: colors,
    components: [{ type: "grid", columns: 1, children: [
      { type: "text", content: "Committed A" },
      { type: "card", title: "Visible transient B", content: [
        { type: "metric", title: "Total", value: "7" },
        { type: "plotly_chart", title: "Alpha vs Beta", data: [{ marker: { color: "#6366F1" }, type: "bar", x: ["Alpha", "Beta"], y: [2, 5] }], layout: { xaxis: { type: "category" }, height: 260 } },
        { type: "table", headers: ["Name", "Value"], rows: [["Alpha", 2], ["Beta", 5]], page_size: 2, total_rows: 10, page_offset: 4 },
      ] },
      { type: "collapsible", component_id: "disclosure", title: "Expanded details", children: [{ type: "text", content: "Current expanded text" }] },
    ] }],
    display_state: [{ path: "/components/0/children/2", component_id: "disclosure", kind: "collapsible_open", value: true }], images: [{ path: "/components/0/children/1/content/1", component_id: null, data_url: pixels }] };
  return renderCapture(input);
}

function renderCapture(input) {
  const python = process.env.PYTHON_BIN || "python3";
  return JSON.parse(execFileSync(python, ["-c", "import sys,json;sys.path.insert(0,'backend');from webrender.export_presentation import render_presentation;print(json.dumps(render_presentation(sys.stdin.buffer.read())))"],
    { cwd: ROOT, input: JSON.stringify(input), encoding: "utf8" }));
}

async function mount(page, input, width = 393) {
  await page.setViewportSize({ width, height: 900 });
  const requests = [];
  await page.route("**/*", async route => {
    requests.push(route.request().url());
    if (route.request().url() === "http://export.test/") {
      const html = template.replace("__ASTRAL_EXPORT_PRESENTATION_BASE64__", () => Buffer.from(JSON.stringify(input)).toString("base64"));
      await route.fulfill({ contentType: "text/html", body: html });
    } else await route.abort();
  });
  await page.goto("http://export.test/");
  return requests;
}

for (const [name, width, colors, windowWidth = width] of [["phone", 393, theme], ["wide", 1200, theme], ["compact", 296, theme, 320], ["narrow canvas", 400, theme, 1200],
  ["light", 393, { ...theme, bg: "#F8FAFC", surface: "#FFFFFF", surface2: "#EEF0F5", text: "#1E293B", border: "#00000014" }]]) {
  test(`bundled ${name} renderer exports visible transient charts theme and disclosure offline`, async ({ page, context }) => {
    await page.setContent('<div id="chart" style="width:360px;height:260px"></div>');
    await page.addScriptTag({ content: vendor });
    const pixels = await page.evaluate(async () => {
      const chart = document.getElementById("chart");
      await window.Plotly.newPlot(chart, [{ type: "bar", x: ["Alpha", "Beta"], y: [2, 5], marker: { color: "#6366F1" } }], { width: 360, height: 260 });
      await window.Plotly.relayout(chart, { "yaxis.range": [0, 8] });
      return window.Plotly.toImage(chart, { format: "png", width: 360, height: 260, scale: 2 });
    });
    const requests = await mount(page, presentation(width, colors, pixels, windowWidth), windowWidth);
    await expect(page.locator("html")).toHaveAttribute("data-export-state", "ready");
    const result = await page.evaluate(() => window.AstralExportResult);
    expect(result.state).toBe("ready");
    expect(result.html).toContain("Committed A");
    expect(result.html).toContain("Visible transient B");
    expect(result.html).toContain("Current expanded text");
    expect(result.html).toContain("data:image/png;base64,");
    expect(result.html).toContain("data:font/woff2;base64,");
    expect(await page.locator("#astral-canvas > .dynamic-renderer").evaluate(el => el.getBoundingClientRect().width)).toBe(width);
    if (name === "narrow canvas") expect(await page.locator(".astral-card").evaluate(el => getComputedStyle(el).paddingLeft)).toBe("16px");
    expect(await page.evaluate(() => typeof window.Plotly)).toBe("undefined");
    expect(result.html).not.toMatch(/<script|data-chart|data-payload|data-ui-action|href=|https?:\/\//i);
    expect(requests).toEqual(["http://export.test/"]);
    const output = await context.newPage();
    let network = 0;
    await output.route("**/*", route => { network++; return route.abort(); });
    await output.setContent(result.html);
    await expect(output.locator("img")).toHaveCount(1);
    expect(await output.locator("img").evaluate(el => el.decode().then(() => el.naturalWidth))).toBeGreaterThan(100);
    await expect(output.locator("details")).toHaveAttribute("open", "");
    expect(await output.locator("body").evaluate(el => getComputedStyle(el).backgroundColor)).toBe(name === "light" ? "rgb(248, 250, 252)" : "rgb(15, 18, 33)");
    expect(network).toBe(0);
    await output.close();
  });
}

test("captured two-column layout survives a 500px window and canonical icons retain their text", async ({ page, context }) => {
  const input = renderCapture({ version: "astral.canvas-export/v1", theme,
    viewport: { width: 476, height: 700, window_width: 500, window_height: 800 },
    components: [{ type: "grid", columns: 2, gap: 8, children: [
      { type: "alert", title: "Current warning", message: "Visible details" },
      { type: "rating", label: "Rating", value: 3.5, max_value: 5 },
    ] }], display_state: [], images: [] });
  const requests = await mount(page, input, 500);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "ready");
  const layout = await page.locator("#astral-canvas > .dynamic-renderer > .grid").evaluate(el => ({
    width: el.getBoundingClientRect().width, columns: getComputedStyle(el).gridTemplateColumns,
    children: [...el.children].map(child => ({ x: child.getBoundingClientRect().x, y: child.getBoundingClientRect().y })),
  }));
  expect(layout.width).toBe(476);
  expect(layout.columns).toBe("234px 234px");
  expect(layout.children[0].y).toBe(layout.children[1].y);
  expect(layout.children[1].x - layout.children[0].x).toBe(242);
  const html = await page.evaluate(() => window.AstralExportResult.html);
  expect(html).toContain("Current warning");
  expect(html).toContain("Visible details");
  expect(html).toContain("3.5");
  expect(html).not.toMatch(/<svg|<path/);
  const offline = await context.newPage();
  await offline.setContent(html);
  expect(await offline.locator("main > div > div").evaluate(el => getComputedStyle(el).gridTemplateColumns.split(" ").length)).toBe(2);
  await offline.close();
  expect(requests).toEqual(["http://export.test/"]);
});

test("loaded image preserves measured logical box and actual visible caption", async ({ page, context }) => {
  const input = renderCapture({ version: "astral.canvas-export/v1", theme,
    viewport: { width: 296, height: 700, window_width: 320, window_height: 800 },
    components: [{ type: "image", width: 120.5, height: 80, caption: "Visible caption", alt: "Loaded image" }],
    display_state: [], images: [{ path: "/components/0", component_id: null, data_url: PIXEL }] });
  await mount(page, input, 320);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "ready");
  const image = await page.locator("#astral-canvas img").boundingBox();
  expect(image.width).toBe(120.5); expect(image.height).toBeCloseTo(80, 3);
  await expect(page.locator("#astral-canvas figcaption")).toHaveText("Visible caption");
  const offline = await context.newPage();
  await offline.setContent(await page.evaluate(() => window.AstralExportResult.html));
  const copied = await offline.locator("img").boundingBox();
  expect(copied.width).toBe(120.5); expect(copied.height).toBeCloseTo(80, 3);
  await expect(offline.locator("figcaption")).toHaveText("Visible caption");
  await offline.close();
});

test("private hidden renderer completes when animation frames are suspended", async ({ page }) => {
  await page.addInitScript(() => { window.requestAnimationFrame = () => 1; });
  const requests = await mount(page, presentation(296, theme, PIXEL, 320), 320);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "ready");
  expect(await page.locator("#astral-canvas > .dynamic-renderer").evaluate(el => el.getBoundingClientRect().width)).toBe(296);
  expect(await page.locator(".astral-card").evaluate(el => getComputedStyle(el).paddingLeft)).toBe("12px");
  expect(await page.evaluate(() => window.AstralExportResult.html)).toContain("Visible transient B");
  expect(requests).toEqual(["http://export.test/"]);
});

test("ready image pixels survive and truncated PNG fails visibly", async ({ page }) => {
  const input = presentation();
  const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNITvv4HwAFpAK6buOwBAAAAABJRU5ErkJggg==";
  input.html = `<div class="dynamic-renderer"><img src="${png}" alt="Loaded pixel"></div>`;
  await mount(page, input);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "ready");
  expect(await page.evaluate(() => window.AstralExportResult.html)).toContain("Loaded pixel");
  await page.unrouteAll();
  input.html = `<div class="dynamic-renderer"><img src="${png.slice(0, 70)}" alt="Truncated"></div>`;
  await mount(page, input);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "error");
  expect(await page.evaluate(() => window.AstralExportResult)).toEqual({ state: "error", code: "export_render_unavailable" });
});

for (const [name, change] of [
  ["executable markup", value => { value.html = '<script>window.injected=true</script>'; }],
  ["remote pixels", value => { value.html = '<div class="dynamic-renderer"><img src="https://private/image"></div>'; }],
  ["action attributes", value => { value.html = '<div class="dynamic-renderer" data-action="share">Private</div>'; }],
  ["unsafe chart keys", value => { value.html = '<div class="dynamic-renderer"><div class="astral-chart" data-chart-type="plotly" data-chart=\'{"data":[],"layout":{"__proto__":{"bad":true}}}\'></div></div>'; }],
  ["remote chart source", value => { value.html = '<div class="dynamic-renderer"><div class="astral-chart" data-chart-type="plotly" data-chart=\'{"data":[],"layout":{"images":[{"source":"https://private/image"}]}}\'></div></div>'; }],
  ["malformed chart", value => { value.html = '<div class="dynamic-renderer"><div class="astral-chart" data-chart-type="unknown" data-chart="{}"></div></div>'; }],
]) {
  test(`${name} refuses without a successful blank export or network request`, async ({ page }) => {
    const input = presentation();
    change(input);
    const requests = await mount(page, input);
    await expect(page.locator("html")).toHaveAttribute("data-export-state", "error");
    expect(await page.evaluate(() => window.AstralExportResult.html)).toBeUndefined();
    expect(await page.evaluate(() => window.injected)).toBeUndefined();
    expect(requests).toEqual(["http://export.test/"]);
  });
}

test("shared web finalizer captures actual chart zoom and refuses unavailable pixels", async ({ page }) => {
  await page.setContent('<main id="canvas"><div class="dynamic-renderer"><div class="astral-chart" id="chart" style="width:360px;height:260px" aria-label="Current chart"></div></div></main>');
  await page.addScriptTag({ content: vendor });
  await page.addScriptTag({ content: exportSources[0].source });
  const result = await page.evaluate(async () => {
    const chart = document.getElementById("chart");
    chart._astralPlotReady = window.Plotly.newPlot(chart, [{ type: "bar", x: ["Alpha", "Beta"], y: [2, 5] }], { width: 360, height: 260 });
    await chart._astralPlotReady;
    await window.Plotly.relayout(chart, { "yaxis.range": [0, 8] });
    chart.dataset.rendered = "1";
    const options = { canvas: document.getElementById("canvas"), plotly: window.Plotly, loadFont: () => new ArrayBuffer(0) };
    const html = await (await window.AstralCanvasExport.snapshot(options)).text();
    delete chart.dataset.rendered;
    let refused = false;
    try { await window.AstralCanvasExport.snapshot(options); } catch { refused = true; }
    return { html, refused };
  });
  expect(result.html).toContain("data:image/png;base64,");
  expect(result.html).toContain("Current chart");
  expect(result.html).not.toContain("data-chart");
  expect(result.refused).toBe(true);
});

test("private host timeout cannot later publish a successful stale document", async ({ page }) => {
  await page.clock.install();
  await page.addInitScript(() => {
    Object.defineProperty(document.fonts, "ready", { value: new Promise(resolve => { window.releaseFonts = resolve; }) });
  });
  await mount(page, presentation());
  await page.clock.runFor(20001);
  await expect(page.locator("html")).toHaveAttribute("data-export-state", "error");
  await page.evaluate(() => window.releaseFonts());
  await page.clock.runFor(100);
  expect(await page.evaluate(() => window.AstralExportResult)).toEqual({ state: "error", code: "export_render_unavailable" });
});
