// Exact offline native assets, real Plotly, and a real browser CSP boundary.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const vendor = await readFile(resolve(ROOT, "backend/webrender/static/vendor/plotly.min.js"), "utf8");
const template = (await readFile(resolve(ROOT, "contracts/assets/charts/chart.html"), "utf8"))
  .replace("__ASTRAL_PLOTLY_VENDOR__", () => vendor);

async function load(page, component, width = 1100) {
  await page.setViewportSize({ width, height: 1300 });
  const payload = Buffer.from(JSON.stringify({ component, viewport_width: width })).toString("base64");
  await page.setContent(template.replace("__ASTRAL_CHART_PAYLOAD_BASE64__", payload));
  await page.waitForFunction(() => document.documentElement.dataset.chartState !== "loading");
}

for (const [type, expected] of [["bar_chart", "bar"], ["line_chart", "scatter"], ["pie_chart", "pie"]]) {
  test(`${type} uses canonical data and category labels`, async ({ page }) => {
    await load(page, { type, labels: ["A", "B"], datasets: [{ data: [-2, 5] }], data: [2, 5] });
    await expect(page.locator("html")).toHaveAttribute("data-chart-state", "ready");
    const plot = await page.evaluate(() => {
      const c = document.getElementById("chart");
      return { type: c.data[0].type, labels: c.data[0].x || c.data[0].labels, values: c.data[0].y || c.data[0].values };
    });
    expect(plot.type).toBe(expected);
    expect(plot.labels).toEqual(["A", "B"]);
    expect(plot.values).toEqual(type === "pie_chart" ? [2, 5] : [-2, 5]);
  });
}

test("mixed trace types, hover, and zoom remain Plotly behaviors", async ({ page }) => {
  await load(page, { type: "plotly_chart", data: [
    { type: "bar", x: ["A", "B"], y: [1, -3], name: "One" },
    { type: "bar", x: ["A", "B"], y: [4, 2], name: "Two" },
    { type: "scatter", mode: "lines+markers", x: ["A", "B"], y: [2, 4], name: "Trend" },
  ], config: { displayModeBar: true } });
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "ready");
  expect(await page.evaluate(() => document.getElementById("chart").data.map(x => x.type)))
    .toEqual(["bar", "bar", "scatter"]);
  await page.evaluate(() => window.Plotly.Fx.hover("chart", [{ curveNumber: 2, pointNumber: 1 }]));
  await expect(page.locator(".hoverlayer")).toContainText("Trend");
  const before = await page.evaluate(() => document.getElementById("chart")._fullLayout.xaxis.range);
  await page.locator('[data-title="Zoom in"]').click();
  await expect.poll(() => page.evaluate(() => document.getElementById("chart")._fullLayout.xaxis.range)).not.toEqual(before);
});

test("nested marker and category-axis options from a committed chart render", async ({ page }) => {
  await load(page, { type: "plotly_chart", title: "Alpha vs Beta", data: [
    { marker: { color: "#6366F1" }, type: "bar", x: ["Alpha", "Beta"], y: [2, 5] },
  ], layout: {
    xaxis: { categoryorder: "category ascending", tickangle: -45, type: "category", automargin: true },
    autosize: true, height: 260, margin: { l: 44, r: 12, t: 32, b: 60 }, yaxis: { automargin: true },
  }, config: {} }, 393);
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "ready");
  expect(await page.evaluate(() => {
    const chart = document.getElementById("chart");
    return { values: chart.data[0].y, color: chart._fullData[0].marker.color, axis: chart._fullLayout.xaxis.type };
  })).toEqual({ values: [2, 5], color: "#6366F1", axis: "category" });
});

test("scrubbed nested options preserve JSON data keys without changing object prototypes", async ({ page }) => {
  const component = JSON.parse('{"type":"plotly_chart","data":[{"type":"bar","x":["A","B"],"y":[2,5],"marker":{"color":"#6366F1","__proto__":{"chartPrototypeAttack":true},"constructor":{"prototype":{"chartPrototypeAttack":true}}}}]}');
  await load(page, component, 393);
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "ready");
  expect(await page.evaluate(() => {
    const marker = document.getElementById("chart").data[0].marker;
    return {
      ordinary: Object.getPrototypeOf(marker) === Object.prototype,
      ownKey: Object.prototype.hasOwnProperty.call(marker, "__proto__"),
      inheritedAttack: ({}).chartPrototypeAttack === true,
      values: document.getElementById("chart").data[0].y,
    };
  })).toEqual({ ordinary: true, ownKey: true, inheritedAttack: false, values: [2, 5] });
});

test("self-contained chart images and array-valued sources remain supported", async ({ page }) => {
  const image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7XQAAAAASUVORK5CYII=";
  await load(page, { type: "plotly_chart", data: [{
    type: "sankey", node: { label: ["Alpha", "Beta"] }, link: { source: [0], target: [1], value: [5] },
  }], layout: { images: [{ source: image, x: 0, y: 1, sizex: 1, sizey: 1 }] } });
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "ready");
  expect(await page.evaluate(() => document.getElementById("chart").data[0].link.source)).toEqual([0]);
});

for (const source of ["/private-chart.png", "//invalid.astral.example/image.png", "http://invalid.astral.example/image.png"]) {
  test(`non-embedded image source is refused before Plotly: ${source}`, async ({ page }) => {
    const requests = [];
    page.on("request", request => requests.push(request.url()));
    await load(page, { type: "plotly_chart", data: [{ type: "bar", x: ["A"], y: [1] }],
      layout: { images: [{ source, x: 0, y: 1, sizex: 1, sizey: 1 }] } });
    await expect(page.locator("html")).toHaveAttribute("data-chart-state", "error");
    expect(requests).toEqual([]);
  });
}

for (const [width, height, expected] of [[380, 600, 260], [1100, 600, 600], [1100, 99999, 1200]]) {
  test(`geometry remains bounded at ${width}px with authored height ${height}`, async ({ page }) => {
    await load(page, { type: "plotly_chart", data: [{ type: "scatter", x: [1, 2], y: [1, 2] }], layout: { width: 99999, height } }, width);
    const size = await page.evaluate(() => {
      const c = document.getElementById("chart");
      return { width: c.getBoundingClientRect().width, height: c._fullLayout.height };
    });
    expect(size.width).toBeLessThanOrEqual(width);
    expect(size.height).toBe(expected);
  });
}

test("empty and malformed charts have truthful terminal states", async ({ page }) => {
  await load(page, { type: "bar_chart", datasets: [] });
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "empty");
  await expect(page.getByRole("status")).toHaveText("No chart data.");
  await load(page, { type: "unknown", data: [1] });
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "error");
  await expect(page.getByRole("status")).toContainText("could not be displayed");
});

test("author HTML cannot execute or fetch remote images", async ({ page }) => {
  const network = [];
  page.on("request", request => { if (/^https?:/.test(request.url())) network.push(request.url()); });
  await load(page, { type: "plotly_chart", title: "</script><script>window.attacked=true</script>", data: [{
    type: "scatter", x: [1, 2], y: [1, 2], name: '<img src=x onerror="window.attacked=true">',
  }], layout: { images: [{ source: "https://invalid.astral.example/never-fetch.png", x: 0, y: 1, sizex: 1, sizey: 1 }] } });
  expect(await page.evaluate(() => Boolean(window.attacked))).toBe(false);
  expect(network).toEqual([]);
  await expect(page.locator("html")).toHaveAttribute("data-chart-state", "error");
  await expect(page.getByRole("status")).toContainText("web client");
});
