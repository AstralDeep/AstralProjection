// Exercises the installed panel iframe through the official MCP Apps AppBridge and a separate-origin sandbox proxy.
// The loopback fixture keeps host protocol execution, browser isolation, and fallback observations independently inspectable.

import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { dirname, resolve } from "node:path";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { ToolSchema, ReadResourceResultSchema, CallToolResultSchema } from "@modelcontextprotocol/core";
import { convertPlaywrightV8Coverage } from "../coverage-conversion.mjs";
import { AppBridge } from "@modelcontextprotocol/ext-apps/app-bridge";
import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const PYTHON = process.env.ASTRAL_PANEL_PYTHON || "python3";
const FIXTURE = JSON.parse(execFileSync(PYTHON, ["-I", "-c", `
import json, sys
wheel_dir = ${JSON.stringify(process.env.ASTRAL_PANEL_WHEEL_DIR || "")}
if wheel_dir:
    sys.path.insert(0, wheel_dir)
from webrender.targets.chatgpt_panel import panel_document, panel_resource, render_chatgpt_panel
v = {"kind": "astral_work_status", "state": "waiting", "title": "Initial work"}
p = render_chatgpt_panel(v)
print(json.dumps({"document": panel_document(), "resource": panel_resource(), "descriptor": {"name":"astral_work_status","inputSchema":{"type":"object"},"_meta":p["metadata"]}, "result": {"content": p["content"], "structuredContent": p["structuredContent"], "isError": False}}))
`], { cwd: ROOT, encoding: "utf8" }));
const CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
let hostServer, sandboxServer, hostOrigin, sandboxOrigin;

async function listen(handler) {
  const server = createServer(handler);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return server;
}

function respond(response, body, headers = {}) {
  response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", ...headers });
  response.end(body);
}

function proxyPage() {
  return `<!doctype html><html><title>Sandbox proxy</title><body style="margin:0"><script>
const hostOrigin = ${JSON.stringify(hostOrigin)};
let app;
addEventListener("message", e => {
  if (e.source === parent && e.origin === hostOrigin) {
    if (e.data?.method === "ui/notifications/sandbox-resource-ready" && !app) {
      app = document.createElement("iframe"); app.title = "Astral panel"; app.name = "astral-panel";
      app.sandbox = "allow-scripts allow-popups"; app.style.cssText = "width:100%;border:0"; app.srcdoc = '<meta http-equiv="Content-Security-Policy" content="' + ${JSON.stringify(CSP)} + '">' + e.data.params.html; document.body.append(app);
    } else if (app) app.contentWindow.postMessage(e.data, "*");
  } else if (app && e.source === app.contentWindow && e.origin === "null") {
    parent.postMessage(e.data, hostOrigin);
  }
});
parent.postMessage({jsonrpc:"2.0",method:"ui/notifications/sandbox-proxy-ready",params:{}}, hostOrigin);
</script></body></html>`;
}

const SOURCE_PATH = "backend/webrender/static/chatgpt-panel.js";
const SOURCE = await readFile(resolve(ROOT, SOURCE_PATH), "utf8");
const coverageOutput = process.env.ASTRAL_PANEL_COVERAGE_OUTPUT;
const observations = [];
test.beforeEach(async ({ page, browserName }) => {
  if (!coverageOutput) return;
  if (browserName !== "chromium") throw new Error("Panel coverage requires Chromium");
  await page.coverage.startJSCoverage({ reportAnonymousScripts: true, resetOnNavigation: false });
});
test.afterEach(async ({ page }) => {
  if (!coverageOutput) return;
  for (const entry of await page.coverage.stopJSCoverage()) {
    if (entry.source === SOURCE) observations.push(entry);
  }
});
test.afterAll(async () => {
  if (!coverageOutput) return;
  expect(await readFile(resolve(ROOT, SOURCE_PATH), "utf8")).toBe(SOURCE);
  expect(observations.length).toBeGreaterThan(0);
  let output;
  for (const observation of observations) {
    const document = await convertPlaywrightV8Coverage([observation], () => SOURCE_PATH);
    if (!output) output = document;
    else {
      const prior = output.coverage[SOURCE_PATH];
      const record = document.coverage[SOURCE_PATH];
      expect(record.statementMap).toEqual(prior.statementMap);
      for (const [id, count] of Object.entries(record.s)) prior.s[id] = prior.s[id] || count;
    }
  }
  await mkdir(dirname(resolve(coverageOutput)), { recursive: true });
  await writeFile(coverageOutput, JSON.stringify(output) + "\n");
});

test.beforeAll(async () => {
  hostServer = await listen((_request, response) => respond(response, `<!doctype html><html><title>Offline MCP Apps host</title><body style="margin:0"><p id="fallback">Complete text fallback: Waiting to start</p><script>
window.wire = [];
addEventListener("message", e => {
  const proxy = document.querySelector("#proxy");
  if (proxy && e.source === proxy.contentWindow && e.origin === window.sandboxOrigin) {
    window.wire.push(e.data); window.hostReceive(e.data);
  }
});
</script></body></html>`));
  hostOrigin = `http://127.0.0.1:${hostServer.address().port}`;
  sandboxServer = await listen((request, response) => {
    if (request.url === "/panel") respond(response, FIXTURE.document, { "Content-Security-Policy": CSP });
    else respond(response, proxyPage());
  });
  sandboxOrigin = `http://127.0.0.1:${sandboxServer.address().port}`;
});

test.afterAll(async () => {
  await Promise.all([hostServer, sandboxServer].map(server => new Promise(resolve => server.close(resolve))));
});

async function boot(page, { input = true, handshake = true, initial = null, html = FIXTURE.document } = {}) {
  let initialized = false;
  const bridge = new AppBridge(null, { name: "Astral offline fixture", version: "1.0.0" }, {});
  const transport = {
    start: async () => {}, close: async () => {},
    send: async message => page.evaluate(({ message, origin }) => {
      document.querySelector("#proxy").contentWindow.postMessage(message, origin);
    }, { message, origin: sandboxOrigin }),
  };
  bridge.oninitialized = async () => {
    initialized = true;
    if (input) await bridge.sendToolInput({ arguments: { work_id: "work-1" } });
    if (initial) await bridge.sendToolResult(initial);
  };
  await bridge.connect(transport);
  await page.exposeFunction("hostReceive", message => {
    if (message.method === "ui/notifications/sandbox-proxy-ready") {
      return transport.send({ jsonrpc: "2.0", method: "ui/notifications/sandbox-resource-ready", params: { html } });
    }
    if (handshake) transport.onmessage(message);
  });
  await page.goto(hostOrigin);
  await page.evaluate(origin => {
    window.sandboxOrigin = origin;
    const frame = document.createElement("iframe");
    frame.id = "proxy"; frame.title = "MCP sandbox"; frame.style.cssText = "width:100%;border:0";
    frame.sandbox = "allow-scripts allow-same-origin allow-popups";
    frame.src = origin + "/proxy"; document.body.append(frame);
  }, sandboxOrigin);
  const panel = page.frameLocator("#proxy").frameLocator("iframe");
  await expect(panel.locator("#ap-panel")).toBeVisible();
  if (handshake) await expect.poll(() => initialized).toBe(true);
  return { bridge, panel, transport };
}

function result(state, extra = {}) {
  return { ...FIXTURE.result, structuredContent: { kind: "astral_work_status", state, title: state + " work", ...extra } };
}

async function raw(transport, message) {
  await transport.send(message);
}

test("official bridge initializes, delivers initial and delayed states, and opens a literal artifact", async ({ page }) => {
  const { bridge, panel } = await boot(page, { initial: result("waiting") });
  await expect(panel.locator("#ap-state-text")).toHaveText("Waiting to start");
  await bridge.sendToolResult(result("running", { progress: { completed: 3, total: 5 } }));
  await expect(panel.locator("#ap-progress")).toHaveAttribute("aria-valuenow", "60");
  for (const [state, label] of [["input_required", "Input required"], ["failed", "Failed"], ["cancelled", "Cancelled"]]) {
    await bridge.sendToolResult(result(state));
    await expect(panel.locator("#ap-state-text")).toHaveText(label);
  }
  const hostile = '<img src=x onerror="window.pwned=1">';
  await bridge.sendToolResult(result("succeeded", { title: hostile, artifacts: [{ id: "a", title: hostile, media_type: "text/plain", url: hostOrigin + "/artifact", size_bytes: 1 }] }));
  await expect(panel.locator("#ap-title")).toHaveText(hostile);
  await expect(panel.locator("img")).toHaveCount(0);
  await expect(panel.locator("#ap-state-text")).toHaveText("Completed");
  await expect(panel.locator("a")).toHaveAttribute("rel", "noopener noreferrer");
  const popup = page.waitForEvent("popup");
  await panel.locator("a").click();
  await expect(await popup).toHaveURL(hostOrigin + "/artifact");
  await panel.locator("#ap-panel").press("Escape");
  await expect(panel.locator("#ap-panel")).toBeFocused();
  const messages = await page.evaluate(() => window.wire);
  expect(messages[0].method).toBe("ui/notifications/sandbox-proxy-ready");
  expect(messages.some(message => message.method === "ui/initialize")).toBe(true);
  expect(messages.some(message => message.method === "ui/notifications/initialized")).toBe(true);
});

test("foreign and raw parent messages cannot replace accepted state", async ({ page }) => {
  const { bridge, panel, transport } = await boot(page, { initial: result("running") });
  await expect(panel.locator("#ap-title")).toHaveText("running work");
  const forged = result("succeeded", { title: "Forged" });
  await raw(transport, forged.structuredContent);
  await page.evaluate(data => {
    const target = document.querySelector("#proxy").contentWindow.frames[0];
    target.postMessage({ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: data }, "*");
  }, forged);
  const app = page.frames().find(frame => frame.name() === "astral-panel");
  await app.evaluate(data => {
    const wire = { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: data };
    dispatchEvent(new MessageEvent("message", { data: wire, source: parent, origin: "https://foreign.invalid" }));
    dispatchEvent(new MessageEvent("message", { data: wire, source: window, origin: new URL(document.referrer).origin }));
  }, forged);
  await expect(panel.locator("#ap-title")).toHaveText("running work");
  await bridge.sendToolResult(result("succeeded"));
  await expect(panel.locator("#ap-title")).toHaveText("succeeded work");
});

test("uncorrelated initialization and pre-input delivery remain unavailable", async ({ page }) => {
  const { panel, transport } = await boot(page, { handshake: false });
  await raw(transport, { jsonrpc: "2.0", id: "unrelated", result: { protocolVersion: "2026-01-26", hostCapabilities: {}, hostInfo: { name: "x", version: "1" }, hostContext: {} } });
  await raw(transport, { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result("succeeded") });
  await expect(panel.locator("#ap-off")).toBeVisible();
  await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
});

test("results require the complete tool input and cannot change input identity", async ({ page }) => {
  const { bridge, panel, transport } = await boot(page, { input: false });
  await bridge.sendToolResult(result("succeeded"));
  await expect(panel.locator("#ap-off")).toBeVisible();
  await bridge.sendToolInput({ arguments: { work_id: "work-1" } });
  await bridge.sendToolResult(result("running"));
  await expect(panel.locator("#ap-title")).toHaveText("running work");
  await raw(transport, { jsonrpc: "2.0", method: "ui/notifications/tool-input", params: { arguments: { work_id: "work-2" } } });
  await bridge.sendToolResult(result("succeeded"));
  await expect(panel.locator("#ap-off")).toBeVisible();
  await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
});

test("malformed bounded payload clears private state and valid recovery renders", async ({ page }) => {
  const { bridge, panel } = await boot(page, { initial: result("running") });
  await expect(panel.locator("#ap-title")).toHaveText("running work");
  for (const invalid of [
    { title: "x".repeat(201) }, { html: "<script>alert(1)</script>" },
    { progress: { completed: 2, total: 1 } },
    { artifacts: [{ id: "a", title: "a", url: "javascript:alert(1)", media_type: "text/plain" }] },
    { artifacts: [{ id: "a", title: "a", url: "//foreign.invalid", media_type: "text/plain" }] },
    { artifacts: [{ id: "a", title: "a", url: "/a", media_type: "application/x-executable" }] },
  ]) {
    await bridge.sendToolResult(result("running", invalid));
    await expect(panel.locator("#ap-off")).toBeVisible();
    await expect(panel.locator("#ap-artifacts")).toBeEmpty();
    await bridge.sendToolResult(result("running"));
    await expect(panel.locator("#ap-title")).toHaveText("running work");
  }
  await bridge.sendToolResult({ content: [{ type: "text", text: "Access revoked" }], isError: true });
  await expect(panel.locator("#ap-off")).toBeVisible();
  await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
});

test("teardown acknowledges and cancellation retires delayed results", async ({ page }) => {
  const { bridge, panel } = await boot(page, { initial: result("succeeded") });
  await expect(panel.locator("#ap-title")).toHaveText("succeeded work");
  await expect(bridge.teardownResource({ reason: "owner revoked" })).resolves.toEqual({});
  await expect(panel.locator("#ap-off")).toBeVisible();
  await bridge.sendToolResult(result("running"));
  await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
});

test("tool cancellation preserves truthful text fallback", async ({ page }) => {
  const { bridge, panel } = await boot(page, { initial: result("running") });
  await expect(panel.locator("#ap-title")).toHaveText("running work");
  await bridge.sendToolCancelled({ reason: "permission revoked" });
  await bridge.sendToolResult(result("succeeded"));
  await expect(panel.locator("#ap-off")).toBeVisible();
  await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
  await expect(page.locator("#fallback")).toContainText("Complete text fallback");
});

test("no host support and direct navigation retain the static fallback", async ({ page }) => {
  const { panel } = await boot(page, { handshake: false });
  await expect(panel.locator("#ap-off")).toBeVisible();
  await page.goto(sandboxOrigin + "/panel");
  await expect(page.locator("#ap-off")).toBeVisible();
  await expect(page.locator("#ap-title")).toHaveText("Astral Work");
});


test("official SDK validates the actual descriptor resource and complete result", () => {
  expect(ToolSchema.parse(FIXTURE.descriptor)._meta.ui.resourceUri).toBe(FIXTURE.resource.uri);
  expect(ReadResourceResultSchema.parse({ contents: [FIXTURE.resource] }).contents[0].mimeType).toBe("text/html;profile=mcp-app");
  expect(CallToolResultSchema.parse(FIXTURE.result).structuredContent.state).toBe("waiting");
  expect(FIXTURE.resource._meta.ui.csp.connectDomains).toEqual([]);
});

test("browser sandbox blocks host access and network requests", async ({ page }) => {
  await boot(page);
  const app = page.frames().find(frame => frame.name() === "astral-panel");
  const denial = await app.evaluate(async origin => {
    let hostDenied = false, networkDenied = false, storageDenied = false;
    try { void parent.document.body; } catch { hostDenied = true; }
    try { await fetch(origin + "/exfiltration"); } catch { networkDenied = true; }
    try { localStorage.setItem("probe", "x"); } catch { storageDenied = true; }
    return { hostDenied, networkDenied, storageDenied };
  }, hostOrigin);
  expect(denial).toEqual({ hostDenied: true, networkDenied: true, storageDenied: true });
});


test("panel stays within 320 pixels with doubled text and long literal content", async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 800 });
  const { panel } = await boot(page, { initial: result("succeeded", { title: "w".repeat(200), detail: "d".repeat(2000) }) });
  await expect(panel.locator("#ap-title")).toHaveText("w".repeat(200));
  const app = page.frames().find(frame => frame.name() === "astral-panel");
  const widths = await app.evaluate(() => {
    const fonts = Array.from(document.querySelectorAll("body, h1, p, div, span, a")).map(node => [node, parseFloat(getComputedStyle(node).fontSize)]);
    for (const [node, size] of fonts) node.style.fontSize = size * 2 + "px";
    return { actual: document.documentElement.scrollWidth, available: document.documentElement.clientWidth };
  });
  expect(widths.actual).toBeLessThanOrEqual(widths.available);
});


test("closed result schema rejects oversize, malformed and injected fields", async ({ page }) => {
  const { bridge, panel, transport } = await boot(page);
  const invalidViews = [
    { kind: "other" }, { state: ["succeeded"] }, { detail: "" }, { status_message: "\u0001" },
    { progress: { completed: 0, total: 0 } }, { progress: { completed: 0.5, total: 1 } },
    { artifacts: Array(9).fill({}) },
    { artifacts: [{ id: "a", title: "a", media_type: "text/plain", url: "http:///foreign.invalid" }] },
    { artifacts: [{ id: "a", title: "a", media_type: "text/plain", url: "/a", size_bytes: 2 ** 41 }] },
    { artifacts: [{ id: "a", title: "a", media_type: "text/plain", url: "/a", note: false }] },
  ];
  const invalidResults = invalidViews.map(extra => result("running", extra));
  invalidResults.push({ ...result("running"), content: "bad" },
    { ...result("running"), isError: "false" }, { ...result("running"), token: "bad" },
    { ...result("running"), content: [{ type: "text", text: "x".repeat(65537) }] },
    { ...result("running"), content: [{ type: "text", text: "界".repeat(30000) }] },
    { ...result("running"), content: Array(5).fill({ type: "text", text: "x".repeat(60000) }) });
  for (const invalid of invalidResults) {
    await bridge.sendToolResult(result("running"));
    await expect(panel.locator("#ap-title")).toHaveText("running work");
    await raw(transport, { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: invalid });
    await expect(panel.locator("#ap-off")).toBeVisible();
    await expect(panel.locator("#ap-title")).toHaveText("Astral Work");
  }
});

test("a correlated unsupported initialization retires the channel", async ({ page }) => {
  const { panel, transport } = await boot(page, { handshake: false });
  await expect.poll(() => page.evaluate(() => window.wire.some(message => message.method === "ui/initialize"))).toBe(true);
  const request = await page.evaluate(() => window.wire.find(message => message.method === "ui/initialize"));
  const response = { jsonrpc: "2.0", id: request.id, result: { protocolVersion: "2099-01-01", hostInfo: { name: "host", version: "1" }, hostCapabilities: {}, hostContext: {} } };
  await raw(transport, response);
  response.result.protocolVersion = "2026-01-26";
  await raw(transport, response);
  await raw(transport, { jsonrpc: "2.0", method: "ui/notifications/tool-input", params: { arguments: { work_id: "work-1" } } });
  await raw(transport, { jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result("succeeded") });
  await expect(panel.locator("#ap-off")).toBeVisible();
});

test("script-blocking CSP retains usable static and conversation fallback", async ({ page }) => {
  const html = FIXTURE.document.replace("<head>", `<head><meta http-equiv="Content-Security-Policy" content="script-src 'none'">`);
  const { panel } = await boot(page, { handshake: false, html });
  await expect(panel.locator("#ap-off")).toBeVisible();
  await expect(page.locator("#fallback")).toContainText("Complete text fallback");
  expect(await page.evaluate(() => window.wire.some(message => message.method === "ui/initialize"))).toBe(false);
});
