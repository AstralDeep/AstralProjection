// Exercises shared mesh controls through the packaged shell and its current socket dispatcher.
// Local custody uses real browser keys; synthetic frames isolate response correlation and retirement.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { collectClientCoverage } from "./client-coverage-fixture.mjs";

collectClientCoverage(test, "mesh-enrollment");
const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT = await readFile(resolve(ROOT, "backend/webrender/static/client.js"), "utf8");
const CUSTODY = await readFile(resolve(ROOT, "backend/webrender/static/mesh-custody.js"), "utf8");

async function setup(page) {
  await page.addInitScript(() => {
    const claims = btoa(JSON.stringify({ iss: "https://iam.example/realm", sub: "owner" })).replace(/=/g, "");
    window.__ASTRAL_TOKEN__ = "synthetic." + claims + ".signature";
    window.__frames = []; window.__sockets = [];
    window.requestIdleCallback = () => 0;
    window.fetch = async () => new Response(JSON.stringify({ authenticated: true,
      access_token: window.__ASTRAL_TOKEN__, resumed: true, user_id: "owner" }), { headers: { "Content-Type": "application/json" } });
    class Socket {
      static OPEN = 1;
      constructor() {
        this.readyState = 0; window.__sockets.push(this);
        queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
      }
      send(raw) {
        const frame = JSON.parse(raw); window.__frames.push(frame);
        if (frame.type === "register_ui") queueMicrotask(() => this.receive({ type: "rote_config", device_profile: { device_type: "browser" } }));
      }
      receive(frame) { this.onmessage?.({ data: JSON.stringify(frame) }); }
      close() { this.readyState = 3; this.onclose?.(); }
    }
    window.WebSocket = Socket;
  });
  await page.route("https://mesh-controls.example/**", route => route.fulfill({ contentType: "text/html", body: `<!doctype html><html><body>
    <header id="astral-topbar"><button data-ui-action="chrome_open" data-ui-payload='{"surface":"mesh","params":{}}'>Open Mesh devices</button>
    <button data-ui-action="chrome_open" data-ui-payload='{"surface":"llm"}'>Open other surface</button></header>
    <div id="astral-history"></div><div id="astral-status"></div><section id="astral-canvas"></section><div id="astral-chat"></div>
    <form id="astral-form"><input id="astral-input"><button type="submit">Send</button></form><div id="astral-modal"></div></body></html>` }));
  await page.goto("https://mesh-controls.example/");
  await page.addScriptTag({ content: CUSTODY });
  await page.addScriptTag({ content: CLIENT });
  await page.waitForFunction(() => window.__frames.some(frame => frame.type === "register_ui"));
}

async function open(page) {
  await page.getByRole("button", { name: "Open Mesh devices", exact: true }).click();
  return page.evaluate(() => window.__frames.filter(frame => frame.action === "chrome_open" && frame.payload.surface === "mesh").at(-1));
}

async function receive(page, request, html) {
  await page.evaluate(({ request, html }) => window.__sockets.at(-1).receive({ type: "chrome_render", region: "modal", mode: "replace",
    surface_key: "mesh", request_generation: request.request_generation, html }), { request, html });
}

const FORM = `<div class="astral-modal-card" role="dialog" tabindex="-1">
  <div data-ui-form><label>Device label<input name="label" value="Tablet"></label><label>Other device identity<textarea name="device_key"></textarea></label>
  <button data-ui-action="chrome_mesh_create" data-ui-collect="true">Create request</button></div>
  <button data-ui-action="chrome_mesh_identity">Copy public identity</button>
  <div data-ui-form><label>Enrollment link<textarea name="link"></textarea></label><button data-ui-action="chrome_mesh_redeem" data-ui-collect="true">Complete enrollment</button></div>
  <button class="astral-modal-close">Close</button></div>`;

test("current mesh frame displays controls and create submits only this device public identity", async ({ page }) => {
  await setup(page);
  const request = await open(page);
  await receive(page, request, FORM);
  await expect(page.getByRole("button", { name: "Create request", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Create request", exact: true }).click();
  await page.waitForFunction(() => window.__frames.some(frame => frame.action === "chrome_mesh_create"));
  const submitted = await page.evaluate(() => window.__frames.find(frame => frame.action === "chrome_mesh_create"));
  const key = JSON.parse(submitted.payload.fields.device_key);
  expect(Object.keys(key).sort()).toEqual(["crv", "kty", "x"]);
  expect(key.crv).toBe("Ed25519"); expect(key.x).toHaveLength(43);
  expect(submitted.payload.fields).not.toHaveProperty("link");
  expect(Object.keys(submitted.payload)).toEqual(["fields"]);
  expect(submitted.submission_id).toMatch(/^[0-9a-f-]{36}$/);
  expect(submitted.session_id).toBeUndefined(); expect(submitted.request_generation).not.toBe(request.request_generation);
  await receive(page, request, "<p>Stale enrollment secret</p>");
  await expect(page.getByText("Stale enrollment secret")).toHaveCount(0);
  await receive(page, submitted, "<p>Current owner result</p>");
  await expect(page.getByText("Current owner result")).toBeVisible();
});

for (const [action, payload] of [
  ["chrome_mesh_confirm", { invite_id: "synthetic-invite" }],
  ["chrome_mesh_reject", { invite_id: "synthetic-invite" }],
  ["chrome_mesh_remove_invitation", { invite_id: "synthetic-invite" }],
  ["chrome_mesh_rename", { member_id: "synthetic-member", fields: { label: "Renamed" } }],
  ["chrome_mesh_revoke", { member_id: "synthetic-member" }],
]) {
  test(`${action} keeps correlation exclusively in the frame envelope`, async ({ page }) => {
    await setup(page);
    const request = await open(page);
    await receive(page, request, `<div class="astral-modal-card" role="dialog"><button data-ui-action="${action}" data-ui-payload='${JSON.stringify(payload)}'>Submit control</button></div>`);
    await page.getByRole("button", { name: "Submit control", exact: true }).click();
    const frame = await page.evaluate(name => window.__frames.find(value => value.action === name), action);
    expect(frame.payload).toEqual(payload);
    expect(frame.submission_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(frame.request_generation).toMatch(/^[0-9a-f-]{36}$/);
    expect(frame.request_generation).not.toBe(request.request_generation);
    expect(frame.session_id).toBeUndefined();
  });
}

for (const view of ["members", "invitations"]) {
  test(`Mesh ${view} tab navigation preserves its exact current envelope`, async ({ page }) => {
    await setup(page);
    const request = await open(page);
    const payload = { surface: "mesh", params: { view } };
    await receive(page, request, `<div class="astral-modal-card" role="dialog"><button data-ui-action="chrome_open" data-ui-payload='${JSON.stringify(payload)}'>Open tab</button></div>`);
    await page.getByRole("button", { name: "Open tab", exact: true }).click();
    const frame = await page.evaluate(() => window.__frames.filter(value => value.action === "chrome_open").at(-1));
    expect(frame.payload).toEqual(payload);
    expect(frame.submission_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(frame.request_generation).not.toBe(request.request_generation);
    expect(frame.session_id).toBeUndefined();
  });
}

test("private identities are refused and local public identity never becomes a socket event", async ({ page }) => {
  await setup(page); await receive(page, await open(page), FORM);
  await page.getByLabel("Other device identity").fill('{"kty":"OKP","crv":"Ed25519","x":"bad","d":"private"}');
  await page.getByRole("button", { name: "Create request", exact: true }).click();
  await expect(page.getByText(/Enrollment refused\./)).toBeVisible();
  expect(await page.evaluate(() => window.__frames.some(frame => frame.action === "chrome_mesh_create"))).toBe(false);
  await page.getByRole("button", { name: "Copy public identity", exact: true }).click();
  const output = page.getByLabel("This device public identity");
  await expect(output).toBeVisible();
  expect(Object.keys(JSON.parse(await output.inputValue())).sort()).toEqual(["crv", "kty", "x"]);
  expect(await page.evaluate(() => window.__frames.some(frame => frame.action === "chrome_mesh_identity"))).toBe(false);
});

test("closing the current surface fences asynchronous enrollment and never reports success", async ({ page }) => {
  await setup(page); await receive(page, await open(page), FORM);
  await page.evaluate(() => {
    window.AstralMeshCustody = { ...window.AstralMeshCustody, redeem: async (_identity, _link, current) => {
      await new Promise(resolve => { window.__meshFinish = resolve; });
      window.__meshStillCurrent = current(); return { member_id: "synthetic" };
    } };
  });
  await page.getByLabel("Enrollment link").fill("synthetic-link");
  await page.getByRole("button", { name: "Complete enrollment", exact: true }).click();
  await page.waitForFunction(() => !!window.__meshFinish);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await page.evaluate(() => window.__meshFinish());
  await page.waitForFunction(() => window.__meshStillCurrent === false);
  await expect(page.getByText("This device is enrolled.", { exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => window.__frames.some(frame => frame.action === "chrome_mesh_redeem"))).toBe(false);
});

test("obsolete mesh close replies cannot dismiss a reopened mesh or ordinary settings modal", async ({ page }) => {
  await setup(page);
  const old = await open(page);
  await receive(page, old, FORM);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  expect(await page.evaluate(() => window.__frames.some(frame => frame.action === "chrome_close"))).toBe(false);
  const current = await open(page);
  await receive(page, current, FORM);
  await receive(page, old, "");
  await expect(page.getByRole("button", { name: "Create request", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Open other surface", exact: true }).click();
  await page.evaluate(() => window.__sockets.at(-1).receive({ type: "chrome_render", region: "modal", mode: "replace", html: "<p>Current LLM settings</p>" }));
  await receive(page, old, "");
  await expect(page.getByText("Current LLM settings", { exact: true })).toBeVisible();
});
