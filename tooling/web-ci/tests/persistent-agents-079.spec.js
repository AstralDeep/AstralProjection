// Contract evidence for the actual shared Python view + shipped classic client.
// Controlled socket/DOM fixture; not live backend or release qualification.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { expect, test } from "@playwright/test";

const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT = resolve(ROOT, "backend/webrender/static/client.js");
const FIXTURE = resolve(import.meta.dirname, "../fixtures/persistent-agents-079.py");

function fixture(mode) {
  if (process.env.ASTRAL_ASSIGNMENT_FIXTURE_DIR) {
    return JSON.parse(readFileSync(resolve(process.env.ASTRAL_ASSIGNMENT_FIXTURE_DIR, `${mode}.json`), "utf8"));
  }
  const python = process.env.ASTRAL_PYTHON || (process.platform === "win32" ? "python" : "python3");
  return JSON.parse(execFileSync(python, [FIXTURE, mode], {
    encoding: "utf8", env: { ...process.env, PYTHONUTF8: "1" },
  }));
}

async function install(page, mode) {
  const rendered = fixture(mode);
  await page.addInitScript(() => {
    window.__ASTRAL_TOKEN__ = "fixture-owner-token";
    window.__ASTRAL_RESUMED__ = true;
    window.__frames = [];
    window.__sockets = [];
    window.requestIdleCallback = () => 0;
    window.fetch = async () => ({ json: async () => ({
      authenticated: true, access_token: "fixture-owner-token", resumed: true, user_id: "owner",
    }) });
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
  await page.route("https://assignment.example/**", (route) => route.fulfill({
    contentType: "text/html", body: `<!doctype html><html><body>
      <header id="astral-topbar"><a id="logout" href="/auth/logout">Sign out</a></header>
      <div id="astral-history"></div><div id="astral-status"></div>
      <section id="astral-canvas"></section><div id="astral-chat"></div>
      <form id="astral-form"><input id="astral-input"><button type="submit">Send</button></form>
      <div id="astral-modal"></div></body></html>`,
  }));
  await page.goto("https://assignment.example/");
  await page.addScriptTag({ content: await readFile(CLIENT, "utf8") });
  await page.waitForFunction(() => window.__frames.some((frame) => frame.type === "register_ui"));
  await page.evaluate((html) => window.__sockets.at(-1).receive({ type: "chrome_render", region: "modal", html }), rendered.html);
  return rendered;
}

for (const mode of ["create", "revise"]) {
  test(`${mode} form submits reviewed selections and consent using keyboard`, async ({ page }) => {
    const rendered = await install(page, mode);
    const consent = page.getByLabel("I approve these instructions, source, tools, limits and revocable unattended authorization");
    await expect(consent).not.toBeChecked();
    await expect(page.getByText("Unpriced/unknown", { exact: false })).toBeVisible();
    await page.getByLabel("Name", { exact: true }).fill("Updated release monitor");
    await page.getByRole("listbox", { name: "Permitted tools", exact: true }).selectOption(["web-research-1:fetch_page", "reader:read"]);
    await page.getByLabel("Daily tool calls", { exact: true }).fill("25");
    await consent.focus();
    await page.keyboard.press("Space");
    const submit = page.getByRole("button", { name: mode === "create" ? "Approve & create ongoing agent" : "Approve revision", exact: true });
    await submit.focus();
    await page.keyboard.press("Enter");
    const action = `chrome_assignment_${mode}`;
    await page.waitForFunction((name) => window.__frames.some((frame) => frame.action === name), action);
    const frame = await page.evaluate((name) => window.__frames.find((item) => item.action === name), action);
    expect(frame.payload.submission_id).toBe(rendered.submission_id);
    expect(frame.payload.fields.allowed_tools).toEqual(["web-research-1:fetch_page", "reader:read"]);
    expect(frame.payload.fields["limits.daily.tool_calls"]).toBe(25);
    expect(frame.payload.fields.consent).toBe(true);
    expect(frame.payload.fields.currency_cap_enabled).toBe(false);
    expect(frame.payload.fields.name).toBe("Updated release monitor");
    if (mode === "revise") {
      expect(frame.payload.assignment_id).toBe(rendered.assignment_id);
      expect(frame.payload.expected_instruction_revision).toBe(2);
      expect(frame.payload.expected_control_epoch).toBe(3);
    }
  });
}

test("an empty tool selection and unchecked consent remain explicit", async ({ page }) => {
  await install(page, "create");
  await page.getByRole("listbox", { name: "Permitted tools", exact: true }).selectOption([]);
  await page.getByRole("button", { name: "Approve & create ongoing agent", exact: true }).click();
  const action = await page.evaluate(() => window.__frames.find((item) => item.action === "chrome_assignment_create"));
  expect(action.payload.fields.allowed_tools).toEqual([]);
  expect(action.payload.fields.consent).toBe(false);
});

test("external result is escaped and approval sends only its exact receipt", async ({ page }) => {
  const rendered = await install(page, "detail");
  await expect(page.locator("#astral-modal img")).toHaveCount(0);
  await expect(page.getByText(/is untrusted external text/)).toBeVisible();
  expect(await page.evaluate(() => window.assignmentInjected)).toBeUndefined();
  const approve = page.getByRole("button", { name: "Approve exact action", exact: true });
  await approve.focus();
  await page.keyboard.press("Enter");
  const action = await page.evaluate(() => window.__frames.find((item) => item.action === "chrome_assignment_approval_decide"));
  expect(action.payload).toEqual({ assignment_id: rendered.assignment_id,
    submission_id: rendered.submission_id, expected_instruction_revision: 2, expected_control_epoch: 3,
    action_id: rendered.action_id, request_digest: "a".repeat(64), decision: "approve",
    request_generation: expect.stringMatching(/^[0-9a-f-]{36}$/u) });
});

test("stale and expired review re-renders remove decision controls", async ({ page }) => {
  await install(page, "detail");
  const expired = fixture("expired");
  await page.evaluate((html) => window.__sockets.at(-1).receive({ type: "chrome_render", region: "modal", html }), expired.html);
  await expect(page.getByRole("button", { name: "Approve exact action", exact: true })).toHaveCount(0);
  const error = fixture("error");
  await page.evaluate((html) => window.__sockets.at(-1).receive({ type: "chrome_render", region: "modal", html }), error.html);
  await expect(page.getByText("The instruction revision changed. Reload the current assignment.", { exact: true })).toBeVisible();
  await expect(page.locator("#astral-modal [data-ui-collect]")).toHaveCount(0);
});
