// Deterministic client reducer/continuity suite against a synthetic DOM, not the release proof:
// socket reconnect, operation-status precedence, transcript/canvas persistence, and draft
// preservation across viewport and auth changes.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { expect, test } from "@playwright/test";

import { collectClientCoverage } from "./client-coverage-fixture.mjs";

collectClientCoverage(test, "continuity-contract-060");


const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT_PATH = resolve(ROOT, "backend/webrender/static/client.js");
const CANVAS_EXPORT_PATH = resolve(ROOT, "backend/webrender/static/canvas-export.js");
const MANIFEST_PATH = resolve(ROOT, "contracts/ui_protocol.json");
const ISSUER = "https://identity.example/realms/astral";
const SUBJECT = "continuity-user";
const CHAT_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_CHAT_ID = "22222222-2222-4222-8222-222222222222";
const SNAPSHOT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const SNAPSHOT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OPERATION_A = "44444444-4444-4444-8444-444444444444";
const OPERATION_B = "55555555-5555-4555-8555-555555555555";
const OPERATION_C = "66666666-6666-4666-8666-666666666666";
const OPERATION_D = "77777777-7777-4777-8777-777777777777";
const OPERATION_E = "88888888-8888-4888-8888-888888888888";
const COMMITTED_AT = "2026-07-16T12:00:00Z";
const ADMISSION_REFUSAL_CODES = [
  "capacity_exceeded",
  "registration_required",
  "registration_timeout",
  "idempotency_conflict",
  "connection_closing",
  "service_draining",
  "invalid_input",
  "registration_queue_full",
  "operation_failed",
];


test("manifest pins the exact admission refusal contract", async () => {
  const manifest = JSON.parse(await readFile(MANIFEST_PATH, "utf8"));
  expect(manifest.frame_contracts?.admission_refusal).toEqual({
    type: "error",
    exact_fields: [
      "type",
      "submission_id",
      "accepted",
      "code",
      "message",
      "retryable",
      "retry_after_ms",
    ],
    submission_id: "canonical_lowercase_uuid4",
    accepted: false,
    additional_fields: false,
    codes: ADMISSION_REFUSAL_CODES,
  });
});


function base64url(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}


const TOKEN = `${base64url({ alg: "none" })}.${base64url({ iss: ISSUER, sub: SUBJECT })}.signature`;
const OTHER_TOKEN = `${base64url({ alg: "none" })}.${base64url({ iss: ISSUER, sub: "other-user" })}.signature`;
const LOCATOR_KEY = `astraldeep.active_chat.v1.${createHash("sha256")
  .update(ISSUER, "utf8")
  .update(Buffer.from([0]))
  .update(SUBJECT, "utf8")
  .digest("hex")}`;
const OTHER_LOCATOR_KEY = `astraldeep.active_chat.v1.${createHash("sha256")
  .update(ISSUER, "utf8")
  .update(Buffer.from([0]))
  .update("other-user", "utf8")
  .digest("hex")}`;


function htmlShell() {
  return `<!doctype html><html><body>
    <header id="astral-topbar"><a id="logout" href="/auth/logout">Sign out</a></header>
    <button id="astral-newchat-btn" type="button">New chat</button>
    <button id="astral-chats-btn" type="button"></button>
    <button id="astral-collapse-btn" type="button"></button>
    <button id="astral-chat-toggle" type="button"></button>
    <button id="astral-restore-chat-btn" type="button" hidden></button>
    <button id="astral-msgs-toggle" type="button"></button>
    <span id="astral-msgs-label"></span>
    <header id="astral-response-top-nav">
      <button type="button" id="astral-back-dash-btn">Dashboard Overview</button>
      <button type="button" id="astral-turns-chip" disabled>(0 turns)</button>
      <button type="button" id="astral-top-newchat-btn">Start new conversation</button>
    </header>
    <button type="button" id="astral-export-page-btn" class="astral-page-action" hidden>Export page</button>
    <button type="button" id="astral-share-page-btn" class="astral-page-action" hidden>Share page</button>
    <div id="astral-history"></div>
    <main>
      <div id="astral-start-intro"></div>
      <div id="astral-start-permission"></div>
      <div id="astral-status"></div>
      <form id="astral-form"><textarea id="astral-input" rows="2"></textarea><button type="button" id="astral-stop-btn" hidden>Stop response</button><button type="submit" id="astral-send-btn">Send</button></form>
      <div id="astral-start-examples"></div>
      <div id="astral-start-more"></div>
      <section id="astral-canvas">
        <div id="astral-canvas-empty">Empty</div>
        <div id="astral-chat" class="astral-feed"></div>
      </section>
      <div id="astral-attachments" class="hidden"></div>
      <button id="astral-attach-btn" type="button"></button>
      <input id="astral-attach-input" class="astral-file-upload" type="file" hidden>
      <div id="astral-voice-controls"></div>
      <div id="astral-voice-transcript"></div>
      <div id="astral-voice-turn-notice"><span id="astral-voice-turn-notice-title"></span><span id="astral-voice-turn-notice-message"></span></div>
      <button id="astral-bg-btn" type="button" aria-pressed="false"></button>
      <div id="astral-slash-menu" class="hidden"></div>
      <div id="astral-composer-controls"></div>
      <div id="astral-modal"></div>
    </main>
    <div id="astral-fullscreen" class="astral-fullscreen" role="dialog" aria-modal="true" aria-labelledby="astral-fs-title" hidden>
      <span id="astral-fs-title">Workspace</span>
      <span id="astral-fs-sub"></span>
      <div id="astral-fs-actions"></div>
      <button type="button" id="astral-fs-exit">Exit full screen</button>
      <div id="astral-fs-canvas" class="astral-fs-canvas"></div>
    </div>
  </body></html>`;
}


async function installHarness(page, { locator = true, url = "https://candidate.example/", steer = false } = {}) {
  await page.addInitScript(({ token, steerAck }) => {
    window.__steerAck = steerAck;
    window.__ASTRAL_TOKEN__ = token;
    window.__ASTRAL_RESUMED__ = true;
    window.__socketEvents = [];
    window.__sockets = [];
    window.requestIdleCallback = () => 0;
    window.__sessionToken = token;
    window.fetch = async () => ({
      json: async () => ({
        authenticated: true,
        access_token: window.__sessionToken,
        resumed: true,
        user_id: window.__sessionSubject || "continuity-user",
      }),
    });

    class FakeWebSocket {
      static OPEN = 1;

      constructor(socketUrl) {
        this.url = socketUrl;
        this.readyState = 0;
        this.sent = [];
        window.__sockets.push(this);
        queueMicrotask(() => {
          if (window.__serverDown) {
            this.readyState = 3;
            this.onclose?.();
            return;
          }
          this.readyState = FakeWebSocket.OPEN;
          this.onopen?.();
        });
      }

      send(raw) {
        const frame = JSON.parse(raw);
        this.sent.push(frame);
        window.__socketEvents.push({
          frame,
          locatorAtSend: localStorage.getItem(window.__locatorKey),
          viewAtSend: document.body.getAttribute("data-astral-view"),
        });


        if (frame.type === "register_ui") {
          queueMicrotask(() => {
            if (window.__dropAfterRegister) {
              this.close();
              return;
            }
            this.receive({
              type: "rote_config",
              device_profile: window.__steerAck
                ? { device_type: "browser", turn_steer: window.__steerAck }
                : { device_type: "browser" },
            });
          });
        }
      }

      close() {
        this.readyState = 3;
        this.onclose?.();
      }

      receive(frame) {
        this.onmessage?.({ data: JSON.stringify(frame) });
      }
    }

    window.WebSocket = FakeWebSocket;
  }, { token: TOKEN, steerAck: steer ? { version: 1, queue_capable: false } : null });

  await page.route("https://candidate.example/**", (route) => route.fulfill({
    contentType: "text/html",
    body: htmlShell(),
  }));
  await page.goto(url);
  await page.evaluate(({ key, chatId, shouldPersist }) => {
    window.__locatorKey = key;
    if (shouldPersist) {
      localStorage.setItem(key, JSON.stringify({
        schema_version: 1,
        chat_id: chatId,
        updated_at: "2026-07-16T11:59:00Z",
      }));
    }
  }, { key: LOCATOR_KEY, chatId: CHAT_ID, shouldPersist: locator });
  const exportSource = await readFile(CANVAS_EXPORT_PATH, "utf8");
  await page.addScriptTag({ content: `${exportSource}\n//# sourceURL=https://candidate.example/static/canvas-export.js` });
  const source = await readFile(CLIENT_PATH, "utf8");
  await page.addScriptTag({ content: source });
  await page.waitForFunction(() => window.__socketEvents.some((event) => event.frame.type === "register_ui"));
}


async function registration(page) {
  return page.evaluate(() => window.__socketEvents.find((event) => event.frame.type === "register_ui"));
}

test("custom appearance waits for accepted server state and survives rejection", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.evaluate(() => {
    document.documentElement.style.setProperty("--astral-primary", "17 34 51");
    const input = document.createElement("input");
    input.type = "color";
    input.className = "astral-color-picker";
    input.setAttribute("data-color-key", "primary");
    input.value = "#112233";
    document.body.append(input);
  });
  await page.locator(".astral-color-picker").fill("#2468ab");
  const acceptedColor = () => page.evaluate(() => document.documentElement.style.getPropertyValue("--astral-primary"));
  await expect.poll(acceptedColor).toBe("17 34 51");
  const events = await page.evaluate(() => window.__socketEvents.map((event) => event.frame));
  expect(events.filter((frame) => frame.type === "ui_event" && frame.action === "save_theme")).toHaveLength(1);
  expect(events.filter((frame) => frame.type === "chat_message")).toHaveLength(0);
  await receive(page, { type: "notification", level: "error", title: "Theme", body: "Save rejected" });
  await expect.poll(acceptedColor).toBe("17 34 51");
  await receive(page, { type: "user_preferences", preferences: { theme: { colors: { primary: "#2468ab" } } } });
  await expect.poll(acceptedColor).toBe("36 104 171");
});

test("a saved provider connection warning preserves the successful form outcome", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("Retain this draft");
  await receive(page, { type: "llm_config_ack", ok: true });
  await receive(page, {
    type: "notification", level: "warning", title: "Provider settings saved",
    body: "Connection test failed. Your saved settings remain available.",
  });
  const warning = page.locator("#astral-toasts .astral-toast").last();
  await expect(warning).toHaveClass("astral-toast astral-toast-warning");
  await expect(warning).toContainText("Provider settings saved");
  await expect(warning).toContainText("Your saved settings remain available.");
  await expect(warning).toHaveCSS("background-color", "rgb(120, 53, 15)");
  await expect(page.locator("#astral-input")).toHaveValue("Retain this draft");
  expect(await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.type === "chat_message"))).toHaveLength(0);
  await receive(page, { type: "notification", level: {}, body: "Ordinary notice" });
  await expect(page.locator("#astral-toasts .astral-toast").last()).toHaveClass("astral-toast astral-toast-info");
});

test("floating conversation restores to the right without losing its draft", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await installHarness(page);
  await page.locator("#astral-input").fill("Keep my draft");
  await page.locator("#astral-collapse-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-layout", "collapsed");
  await expect(page.locator("#astral-restore-chat-btn")).toBeVisible();
  await page.locator("#astral-chat-toggle").click();
  await expect(page.locator("body")).toHaveClass(/astral-chat-open/u);
  await expect(page.locator("#astral-restore-chat-btn")).toBeVisible();
  await page.locator("#astral-restore-chat-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-layout", "split");
  await expect(page.locator("#astral-input")).toHaveValue("Keep my draft");
  await expect(page.locator("#astral-input")).toBeFocused();
  await expect(page.locator("#astral-restore-chat-btn")).toBeHidden();
  await page.setViewportSize({ width: 768, height: 900 });
  await expect(page.locator("body")).toHaveAttribute("data-astral-layout", "collapsed");
  await expect(page.locator("#astral-restore-chat-btn")).toBeHidden();
  await page.setViewportSize({ width: 393, height: 852 });
  await expect(page.locator("body")).toHaveAttribute("data-astral-layout", "stacked");
  await expect(page.locator("#astral-restore-chat-btn")).toBeHidden();
});


test("a committed workspace lands in the visible feed, not an orphaned card", async ({ page }) => {


  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  const placed = await page.evaluate(() => {
    const node = document.querySelector('[data-component-id="rote-new"]');
    return {
      found: Boolean(node),
      connected: Boolean(node && node.isConnected),
      inFeed: Boolean(node && document.getElementById("astral-chat").contains(node)),
      inHiddenCard: Boolean(node && node.closest(".astral-turn")?.hidden),
    };
  });
  expect(placed).toEqual({ found: true, connected: true, inFeed: true, inHiddenCard: false });
  await expect(page.locator('[data-component-id="rote-new"]')).toBeVisible();
});


test("canvas source stays in the result and opens the unchanged Markdown URL", async ({ page }) => {
  const url = "https://en.wikipedia.org/wiki/Dog_grooming";
  const source = `Source: [${url}](${url})`;


  const html = execFileSync("python3", [
    "-c", "import runpy,sys; print(runpy.run_path(sys.argv[1])['block_md'](sys.argv[2]))",
    resolve(ROOT, "backend/webrender/sanitize.py"), source,
  ], { encoding: "utf8" }).trim();
  await installHarness(page);
  const component = presentation("wc-source", source);
  component._presentation.html = `<div class="astral-component" data-component-id="wc-source">${html}</div>`;
  await receive(page, snapshot((await registration(page)).frame, {
    canvas: { target: "canvas", components: [component] },
  }));
  for (const width of [1440, 393]) {
    await page.setViewportSize({ width, height: 900 });
    await expect(page.locator('#astral-chat [data-astral-live-turn="1"] a')).toHaveCount(1);
    await expect(page.locator('#astral-chat .astral-turn:not([data-astral-live-turn]) a')).toHaveCount(0);
    await expect(page.locator("#astral-chat")).toContainText("Committed answer");
    const link = page.getByRole("link", { name: url, exact: true });
    await expect(link).toBeVisible();
    await expect(link).toHaveAttribute("href", url);
    await expect(link).toHaveAttribute("target", "_blank");
    expect(await link.evaluate((node) => node.href)).toBe(url);
  }
  await page.context().route(url, (route) => route.fulfill({
    contentType: "text/html", body: "<title>Source destination</title>",
  }));
  const popupPromise = page.waitForEvent("popup");
  await page.getByRole("link", { name: url, exact: true }).click();
  const popup = await popupPromise;
  await expect(popup).toHaveURL(url);
  await popup.close();
});


test("full screen control stays reachable in the result header", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.addStyleTag({ path: resolve(ROOT, "backend/webrender/static/astral.css") });
  for (const width of [1440, 393]) {
    await page.setViewportSize({ width, height: 900 });
    const button = page.locator(".astral-card-head-right > .astral-expand-chip");
    await expect(button).toHaveAccessibleName("Open this result in full screen");
    await expect(button).toBeVisible();
    await expect(button).toHaveCSS("position", "static");
    await expect(button).toHaveCSS("opacity", "1");
    await expect(page.locator(".astral-response-card > .astral-expand-chip")).toHaveCount(0);
  }
});

test("dashboard navigation preserves the conversation and keyboard turns restores it", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame, {
    transcript: [{ message_id: "user-turn", role: "user", created_at: COMMITTED_AT, parts: [{ type: "text", text: "Keep this conversation" }], attachments: [] }],
  }));
  await expect(page.locator("#astral-turns-chip")).toHaveText("(1 turn)");
  await page.locator("#astral-back-dash-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await receive(page, { type: "task_completed", payload: { summary: "Background update" } });
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await expect(page.locator("#astral-chat")).toContainText("Keep this conversation");
  await page.locator("#astral-turns-chip").focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  await expect(page.locator('[data-component-id="rote-new"]')).toBeVisible();
  await page.locator("#astral-top-newchat-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await expect(page.locator("#astral-turns-chip")).toHaveText("(0 turns)");
  await expect(page.locator("#astral-turns-chip")).toBeDisabled();
  await expect(page.locator("#astral-chat")).not.toContainText("Keep this conversation");
});


test("snapshot preserves header export and share controls through repeated rebuilds", async ({ page }) => {
  await installHarness(page);
  const scope = (await registration(page)).frame;
  const canvas = { target: "canvas", components: [presentation("exportable", "Exportable result", { export: true, share: true })] };
  await receive(page, snapshot(scope, { canvas }));
  await page.evaluate(() => {
    window.__exportNode = document.getElementById("astral-export-page-btn");
    window.__shareNode = document.getElementById("astral-share-page-btn");
  });
  await receive(page, snapshot(scope, { snapshot_id: SNAPSHOT_B, render_revision: 1, canvas }));
  for (const id of ["astral-export-page-btn", "astral-share-page-btn"]) {
    await expect(page.locator(`#astral-chat .astral-card-head-right #${id}`)).toBeVisible();
    await expect(page.locator(`#${id}`)).toHaveCount(1);
  }
  await page.locator("#astral-newchat-btn").click();
  expect(await page.evaluate(() => ({
    export: document.getElementById("astral-export-page-btn") === window.__exportNode,
    share: document.getElementById("astral-share-page-btn") === window.__shareNode,
  }))).toEqual({ export: true, share: true });
  await expect(page.locator("#astral-export-page-btn")).toBeHidden();
  await expect(page.locator("#astral-share-page-btn")).toBeHidden();
});


test("full screen accepts non-string agent metadata without interrupting snapshot commit", async ({ page }) => {
  await installHarness(page);
  const scope = (await registration(page)).frame;
  await receive(page, snapshot(scope));
  await page.getByRole("button", { name: "Open this result in full screen" }).click();
  const component = { ...presentation("agent-metadata", "Valid workspace with structured metadata"), source_agent: { id: "agent-a" }, agent_id: 7, agent: true };
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    render_revision: 1,
    canvas: { target: "canvas", components: [component] },
  }));
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  await expect(page.locator('#astral-fs-canvas [data-component-id="agent-metadata"]')).toBeVisible();
  await page.locator("#astral-fs-exit").click();
  await expect(page.locator('#astral-chat [data-component-id="agent-metadata"]')).toBeVisible();
  await expect(page.getByRole("button", { name: "Open this result in full screen" })).toBeFocused();
});


for (const [agentId, expectedName] of [["renal-team", "Renal Specialist"], ["new_research-agent", "New Research Agent"]]) {
  test(`snapshot displays the originating agent ${agentId} in preview and full screen`, async ({ page }) => {
    await page.addInitScript(() => {
      window.__ASTRAL_LANDING__ = { agents: [{ id: "renal-team", name: "Renal Specialist" }], scenarios: [], categories: [] };
    });
    await installHarness(page);
    await receive(page, snapshot((await registration(page)).frame, {
      canvas: { target: "canvas", components: [{ ...presentation("named-result", "Result from the selected specialist"), source_agent: agentId }] },
    }));
    await expect(page.locator(".chat-agent-name-text")).toHaveText(expectedName);
    await expect(page.locator(".sdui-widget-title")).toHaveText(`${expectedName} Interface`);
    await page.getByRole("button", { name: "Open this result in full screen" }).click();
    await expect(page.locator("#astral-fs-title")).toHaveText(`${expectedName} Interface`);
    await expect(page.locator("#astral-fs-sub")).toHaveText("Active Specialist");
  });
}


test("legacy upsert retains the overflow control and keyed stream updates the visible full screen result", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: "<p>Preparing results</p>" });
  await page.evaluate(() => { window.__overflowControl = document.querySelector(".sdui-widget-overlay"); });
  await receive(page, { type: "ui_upsert", ops: [{
    op: "upsert", component_id: "legacy-result", html: '<div data-component-id="legacy-result">Prepared result</div>',
  }] });
  await expect(page.locator(".sdui-widget-body .dynamic-renderer")).toContainText("Prepared result");
  await expect(page.locator(".sdui-widget-body")).not.toContainText("Preparing results");
  expect(await page.evaluate(() => document.querySelector(".sdui-widget-overlay") === window.__overflowControl)).toBe(true);
  await expect(page.locator(".sdui-widget-overlay")).toHaveCount(1);
  await page.getByRole("button", { name: "Open this result in full screen" }).click();
  await receive(page, { type: "ui_stream_data", stream_id: "legacy-stream", component_id: "stream-result", seq: 1, html: '<div data-component-id="stream-result">Partial streamed result</div>' });
  await expect(page.locator('#astral-fs-canvas [data-component-id="stream-result"]')).toHaveText("Partial streamed result");
  await receive(page, { type: "ui_stream_data", stream_id: "legacy-stream", component_id: "stream-result", seq: 2, terminal: true, html: '<div data-component-id="stream-result">Final streamed result</div>' });
  await expect(page.locator('#astral-fs-canvas [data-component-id="stream-result"]')).toHaveText("Final streamed result");
  await expect(page.locator('[data-component-id="stream-result"]')).toHaveCount(1);
  await page.locator("#astral-fs-exit").click();
  await expect(page.locator('#astral-chat [data-component-id="stream-result"]')).toHaveText("Final streamed result");
  expect(await page.evaluate(() => document.querySelector(".sdui-widget-overlay") === window.__overflowControl)).toBe(true);
});


test("snapshot preserves distinct tables and cards with similar titles", async ({ page }) => {
  await installHarness(page);
  const components = [
    { ...presentation("table-a", "Current results"), type: "table", title: "Results" },
    { ...presentation("table-b", "Previous results"), type: "table", title: "Results" },
    { ...presentation("card-a", "Comparison A"), type: "card", title: "Comparison (current)" },
    { ...presentation("card-b", "Comparison B"), type: "card", title: "Comparison (previous)" },
  ];
  await receive(page, snapshot((await registration(page)).frame, {
    canvas: { target: "canvas", components },
  }));
  await expect(page.locator("#astral-chat [data-component-id]")).toHaveText([
    "Current results", "Previous results", "Comparison A", "Comparison B",
  ]);
});


test("snapshot validates every table before replacing committed content", async ({ page }) => {
  await installHarness(page);
  const scope = (await registration(page)).frame;
  await receive(page, snapshot(scope));
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    render_revision: 1,
    canvas: { target: "canvas", components: [
      { ...presentation("table-a", "Restricted table"), type: "table" },
      { ...presentation("table-b", "Conflicting table", { export: true, share: true }), type: "table" },
    ] },
  }));
  await expect(page.locator('[data-component-id="rote-new"]')).toBeVisible();
  await expect(page.locator('[data-component-id^="table-"]')).toHaveCount(0);
});


test("full screen restores the same interactive nodes and focus on Escape", async ({ page }) => {
  await installHarness(page);
  const component = presentation("editable", "Editable result");
  component._presentation.html = '<div class="astral-component" data-component-id="editable"><label>Result note<input aria-label="Result note"></label></div>';
  await receive(page, snapshot((await registration(page)).frame, {
    canvas: { target: "canvas", components: [component] },
  }));
  await page.getByRole("textbox", { name: "Result note" }).fill("Keep this note");
  await page.evaluate(() => { window.__resultNode = document.querySelector('[data-component-id="editable"]'); });
  const expand = page.getByRole("button", { name: "Open this result in full screen" });
  await expand.click();
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  await expect(page.locator('#astral-fs-canvas [data-component-id="editable"]')).toHaveCount(1);
  await expect(page.getByRole("textbox", { name: "Result note" })).toHaveValue("Keep this note");
  await page.keyboard.press("Escape");
  await expect(page.locator("#astral-fullscreen")).toBeHidden();
  await expect(page.locator('#astral-chat [data-component-id="editable"]')).toHaveCount(1);
  expect(await page.evaluate(() => document.querySelector('[data-component-id="editable"]') === window.__resultNode)).toBe(true);
  await expect(page.getByRole("textbox", { name: "Result note" })).toHaveValue("Keep this note");
  await expect(expand).toBeFocused();
});


test("full screen receives live renders and upserts and follows the committed snapshot", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-input").fill("Update the workspace");
  await page.locator("#astral-form").evaluate(form => form.requestSubmit());
  const scope = await page.evaluate(() => window.__socketEvents.findLast(event => event.frame.action === "chat_message").frame);
  const frame = {
    chat_id: CHAT_ID,
    connection_generation: scope.connection_generation,
    request_generation: scope.request_generation,
    base_render_revision: 0,
    frame_sequence: 1,
  };
  await receive(page, { ...frame, type: "ui_render", target: "canvas", html: '<div class="dynamic-renderer"><div data-component-id="preview-result">First preview</div></div>' });
  await page.locator('[data-astral-live-turn] .astral-expand-chip').click();
  await expect(page.locator("#astral-fs-canvas")).toContainText("First preview");
  await receive(page, { ...frame, frame_sequence: 2, type: "ui_update", html: '<div class="dynamic-renderer"><div data-component-id="preview-result">Rendered update</div></div>' });
  await expect(page.locator("#astral-fs-canvas")).toContainText("Rendered update");
  await receive(page, { ...frame, frame_sequence: 3, type: "ui_upsert", ops: [
    { op: "upsert", component_id: "preview-result", html: '<div data-component-id="preview-result">Upserted preview</div>' },
  ] });
  await expect(page.locator("#astral-fs-canvas")).toContainText("Upserted preview");
  await expect(page.locator('[data-component-id="preview-result"]')).toHaveCount(1);
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    snapshot_purpose: "commit",
    render_revision: 1,
    canvas: { target: "canvas", components: [presentation("final-result", "Final committed workspace")] },
  }));
  await expect(page.locator("#astral-fullscreen")).toBeVisible();
  await expect(page.locator("#astral-fs-canvas")).toContainText("Final committed workspace");
  await expect(page.locator('[data-component-id="preview-result"]')).toHaveCount(0);
  await page.locator("#astral-fs-exit").click();
  await expect(page.locator('#astral-chat [data-component-id="final-result"]')).toBeVisible();
  await expect(page.locator('[data-component-id="final-result"]')).toHaveCount(1);
});


for (const transition of ["new chat", "account switch", "sign out"]) {
  test(`full screen clears private content on ${transition}`, async ({ page }) => {
    await installHarness(page);
    await receive(page, snapshot((await registration(page)).frame));
    await page.getByRole("button", { name: "Open this result in full screen" }).click();
    await expect(page.locator("#astral-fs-canvas")).toContainText("ROTE-adapted canvas");
    if (transition === "new chat") {
      await page.locator("#astral-newchat-btn").evaluate(button => button.click());
    } else if (transition === "sign out") {
      await page.locator("#logout").evaluate(link => {
        link.addEventListener("click", event => event.preventDefault());
        link.click();
      });
    } else {
      await page.evaluate(token => {
        window.__sessionToken = token;
        window.__sessionSubject = "other-user";
      }, OTHER_TOKEN);
      await receive(page, { type: "auth_required" });
      await page.waitForFunction(() => window.__sockets.length === 2);
    }
    await expect(page.locator("#astral-fullscreen")).toBeHidden();
    await expect(page.locator("#astral-fs-canvas")).toBeEmpty();
    await expect(page.locator('[data-component-id="rote-new"]')).toHaveCount(0);
  });
}


test("turn numbering follows the transcript rather than every rebuild", async ({ page }) => {
  await installHarness(page);
  const scope = (await registration(page)).frame;
  const twoTurns = {
    transcript: [
      { message_id: "m1", role: "user", created_at: COMMITTED_AT, parts: [{ type: "text", text: "First" }], attachments: [] },
      { message_id: "m2", role: "assistant", created_at: COMMITTED_AT, parts: [{ type: "text", text: "Answer" }], attachments: [] },
      { message_id: "m3", role: "user", created_at: COMMITTED_AT, parts: [{ type: "text", text: "Second" }], attachments: [] },
    ],
  };
  await receive(page, snapshot(scope, twoTurns));
  await expect(page.locator(".astral-turn-pill")).toHaveText(["Turn 1", "Turn 2"]);

  await receive(page, snapshot(scope, {
    ...twoTurns,
    snapshot_id: SNAPSHOT_B,
    render_revision: 1,
    snapshot_purpose: "hydration",
  }));
  await expect(page.locator(".astral-turn-pill")).toHaveText(["Turn 1", "Turn 2"]);
});


test("the conversation feed stays reachable at every width and keeps the draft", async ({ page }) => {


  await page.setViewportSize({ width: 390, height: 900 });
  await installHarness(page);
  await page.addStyleTag({ path: resolve(ROOT, "backend/webrender/static/astral.css") });
  await receive(page, snapshot((await registration(page)).frame));
  const transcript = page.locator("#astral-chat");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  await expect(transcript).toBeVisible();
  await expect(transcript).toContainText("Committed answer");
  await page.locator("#astral-input").fill("Preserve this draft\nAcross breakpoints");

  for (const width of [900, 1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await expect(transcript).toBeVisible();
    await expect(transcript).toContainText("Committed answer");
    await expect(page.locator("#astral-input")).toHaveValue("Preserve this draft\nAcross breakpoints");
  }

  await page.getByRole("button", { name: "New chat" }).click();
  await expect(page.locator("#astral-chat .astral-turn:not([hidden])")).toHaveCount(0);
  await expect(page.locator("#astral-input")).toHaveValue("");
});


async function receive(page, frame) {
  await page.evaluate((value) => window.__sockets.at(-1).receive(value), frame);
}


function presentation(id, text, workspace = { export: false, share: false }) {
  return {
    type: "text",
    component_id: id,
    content: text,
    _presentation: {
      target: "web",
      html: `<div class="astral-component" data-component-id="${id}">${text}</div>`,
      workspace,
    },
  };
}


function snapshot(scope, overrides = {}) {
  return {
    type: "conversation_snapshot",
    schema_version: 1,
    snapshot_id: SNAPSHOT_A,
    chat_id: CHAT_ID,
    connection_generation: scope.connection_generation,
    request_generation: scope.request_generation || scope.resume.request_generation,
    snapshot_purpose: "hydration",
    render_revision: 0,
    committed_at: COMMITTED_AT,
    transcript: [{
      message_id: "message-1",
      role: "assistant",
      created_at: COMMITTED_AT,
      parts: [{ type: "text", text: "Committed answer" }],
      attachments: [],
    }],
    canvas: {
      target: "canvas",
      components: [presentation("rote-new", "ROTE-adapted canvas")],
    },
    ...overrides,
  };
}


function reasoningPresentation(id) {
  const component = presentation(id, "Supporting explanation");
  component.type = "collapsible";
  component.title = "Reasoning";
  component._presentation.html = `<div class="astral-component" data-component-id="${id}"><details class="astral-reasoning"><summary>Reasoning</summary><div>Supporting explanation</div></details></div>`;
  return component;
}

function messageWithParts(id, role, parts) {
  return { message_id: id, role, created_at: COMMITTED_AT, attachments: [], parts };
}

async function expectResultBeforeReasoning(page, id) {
  expect(await page.locator(`[data-component-id="${id}"]`).evaluate(node => {
    const card = document.querySelector('[data-astral-live-turn="1"]');
    return Boolean(card.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING);
  })).toBe(true);
}

for (const mixed of [true, false]) {
  test(`saved reasoning follows the UI result with a separate summary bubble (mixed=${mixed})`, async ({ page }) => {
    await installHarness(page);
    await page.addStyleTag({ path: resolve(ROOT, "backend/webrender/static/astral.css") });
    const scope = (await registration(page)).frame;
    const reasoningPart = { type: "components", components: [reasoningPresentation("saved-reasoning")] };
    const summaryPart = { type: "text", text: "Your grant workbooks are ready." };
    const transcript = [messageWithParts("question", "user", [{ type: "text", text: "Build a grant workbook" }])];
    transcript.push(messageWithParts("reasoning", "assistant", mixed ? [reasoningPart, summaryPart] : [reasoningPart]));
    if (!mixed) transcript.push(messageWithParts("summary", "assistant", [summaryPart]));
    const frame = snapshot(scope, { transcript });
    await receive(page, frame);
    await expectResultBeforeReasoning(page, "saved-reasoning");
    await expect(page.locator(".chat-text-summary")).toHaveCount(1);
    await expect(page.locator(".chat-text-summary")).toHaveText(summaryPart.text);
    await expect(page.locator(".chat-text-summary")).toHaveCSS("border-top-width", "1px");
    await expect(page.locator(".chat-text-summary")).toHaveCSS("padding-left", "16px");
    await expect(page.locator(".chat-text-summary .astral-reasoning")).toHaveCount(0);
    await page.locator(".astral-reasoning summary").click();
    await receive(page, frame);
    await expect(page.locator(".astral-reasoning")).toHaveAttribute("open", "");
    await expect(page.locator(".astral-reasoning")).toHaveCount(1);
    await receive(page, snapshot(scope, { snapshot_id: SNAPSHOT_B, render_revision: 1, transcript,
      canvas: { target: "canvas", components: [{ ...presentation("invalid", "Invalid"), _presentation: { target: "web", html: "<script>bad</script>", workspace: { export: false, share: false } } }] },
    }));
    await expect(page.locator(".astral-reasoning")).toHaveAttribute("open", "");
    await expectResultBeforeReasoning(page, "saved-reasoning");
    await page.getByRole("button", { name: "Open this result in full screen" }).click();
    await expect(page.locator("#astral-fs-canvas .astral-reasoning")).toHaveCount(0);
    await page.locator("#astral-fs-exit").click();
    await expectResultBeforeReasoning(page, "saved-reasoning");
  });
}

test("text-only reasoning stays visible and earlier turns retain their own disclosure", async ({ page }) => {
  await installHarness(page);
  const transcript = [
    messageWithParts("first-question", "user", [{ type: "text", text: "First question" }]),
    messageWithParts("first-reasoning", "assistant", [{ type: "components", components: [reasoningPresentation("earlier-reasoning")] }]),
    messageWithParts("second-question", "user", [{ type: "text", text: "Second question" }]),
    messageWithParts("second-reasoning", "assistant", [{ type: "components", components: [reasoningPresentation("latest-reasoning")] }]),
  ];
  await receive(page, snapshot((await registration(page)).frame, { transcript, canvas: { target: "canvas", components: [] } }));
  await expect(page.locator(".chat-text-summary")).toHaveCount(0);
  await expect(page.locator(".astral-reasoning summary")).toHaveCount(2);
  await expect(page.locator('[data-component-id="latest-reasoning"]')).toBeVisible();
  expect(await page.locator('[data-component-id="earlier-reasoning"]').evaluate(node =>
    Boolean(node.compareDocumentPosition(document.querySelectorAll(".astral-user-bubble")[1]) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true);
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator(".astral-reasoning")).toHaveCount(0);
});

test("live reasoning remains below result and summary through commit and cleanup", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-input").fill("Create a detailed comparison");
  await page.locator("#astral-form").evaluate(form => form.requestSubmit());
  const scope = await page.evaluate(() => window.__socketEvents.findLast(event => event.frame.action === "chat_message").frame);
  const base = { type: "ui_render", target: "chat", chat_id: CHAT_ID, connection_generation: scope.connection_generation,
    request_generation: scope.request_generation, base_render_revision: 0, frame_sequence: 1,
    html: `<div class="dynamic-renderer">${reasoningPresentation("live-reasoning")._presentation.html}</div>` };
  await receive(page, base);
  await receive(page, { ...base, target: "canvas", frame_sequence: 2, html: "<p>Live comparison</p>" });
  await receive(page, { ...base, frame_sequence: 3, html: "<p>The comparison is ready.</p>" });
  await expectResultBeforeReasoning(page, "live-reasoning");
  const overlay = page.locator('[data-astral-transient-overlay="chat"]');
  await expect(overlay.locator(".chat-text-summary")).toHaveCount(1);
  await expect(overlay.locator(".chat-text-summary")).toHaveText("The comparison is ready.");
  expect(await overlay.evaluate(node => node.lastElementChild.classList.contains("astral-reasoning-turn"))).toBe(true);
  await receive(page, operationStatus(scope, OPERATION_A, 0, "completed"));
  await expect(page.locator('[data-component-id="live-reasoning"]')).toBeVisible();
  await receive(page, snapshot(scope, { snapshot_id: SNAPSHOT_B, snapshot_purpose: "commit", render_revision: 1,
    transcript: [messageWithParts("final", "assistant", [
      { type: "components", components: [reasoningPresentation("saved-reasoning")] }, { type: "text", text: "The comparison is ready." },
    ])],
  }));
  await expect(page.locator('[data-component-id="live-reasoning"]')).toHaveCount(0);
  await expect(page.locator('[data-astral-transient-overlay="chat"]')).toHaveCount(0);
  await expectResultBeforeReasoning(page, "saved-reasoning");
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator(".astral-reasoning")).toHaveCount(0);
});

test("legacy mixed response separates bare reasoning and preserves summary content", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: "<p>Legacy result</p>" });
  await receive(page, { type: "ui_render", target: "chat", html: '<details class="astral-reasoning"><summary>Reasoning</summary><div>Working detail</div></details><p>Result summary</p>' });
  await expect(page.locator(".chat-text-summary")).toHaveText("Result summary");
  await expect(page.locator(".astral-reasoning-turn")).toHaveText("ReasoningWorking detail");
  await expect(page.locator(".chat-text-summary .astral-reasoning")).toHaveCount(0);
});


function operationStatus(scope, operationId, sequence, state, overrides = {}) {
  const terminal = ["completed", "failed", "cancelled", "retryable"].includes(state);
  const isError = ["failed", "cancelled", "retryable"].includes(state);
  return {
    type: "operation_status",
    operation_id: operationId,
    action: "chat_message",
    surface: "chat",
    chat_id: CHAT_ID,
    connection_generation: scope.connection_generation,
    request_generation: scope.request_generation || scope.resume.request_generation,
    sequence,
    state,
    phase: state,
    label: state === "completed" ? "Completed" : `Active ${operationId.slice(0, 1)}`,
    terminal,
    retryable: state === "retryable",
    error: isError ? { code: "operation_failed", message: "Visible terminal failure" } : null,
    retry_after_ms: state === "retryable" ? 500 : null,
    updated_at: `2026-07-16T12:00:0${sequence}Z`,
    ...overrides,
  };
}


test("locator is present before registration and equal hydration replaces atomically", async ({ page }) => {
  await installHarness(page);
  const event = await registration(page);
  expect(JSON.parse(event.locatorAtSend).chat_id).toBe(CHAT_ID);
  expect(event.frame.connection_generation).toMatch(/^[0-9a-f-]{36}$/u);
  expect(event.frame.resume).toEqual(expect.objectContaining({
    schema_version: 1,
    active_chat_id: CHAT_ID,
  }));

  await page.evaluate(() => {


    document.querySelector("#astral-chat")
      .insertAdjacentHTML("afterbegin", '<div id="old-transcript">Old transcript</div>');
    document.querySelector(".astral-card-body").innerHTML = '<div id="old-canvas">Old canvas</div>';
  });
  await receive(page, snapshot(event.frame));

  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  await expect(page.locator("#astral-chat #old-transcript")).toHaveCount(0);
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas #old-canvas")).toHaveCount(0);


  await receive(page, {type: "chat_loaded", chat: {id: CHAT_ID}});
  await expect(page.locator("#astral-status")).toHaveText("");
  await expect(page.locator("#astral-status")).toHaveAttribute("aria-busy", "false");
});


test("interactive hydration snapshot settles load activity and ignores late progress", async ({ page }) => {
  await installHarness(page);
  const { frame: registrationFrame } = await registration(page);
  await page.evaluate((chatId) => {
    const button = document.createElement("button");
    button.className = "astral-action";
    button.dataset.action = "load_chat";
    button.dataset.payload = JSON.stringify({ chat_id: chatId });
    document.body.appendChild(button);
    button.click();
  }, CHAT_ID);
  const load = await page.evaluate(() => window.__socketEvents.findLast((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "load_chat"
  )).frame);
  const loadScope = {
    connection_generation: registrationFrame.connection_generation,
    request_generation: load.request_generation,
  };
  const status = page.locator("#astral-status");
  await expect(status).toHaveText("Submitting…");
  await receive(page, operationStatus(loadScope, OPERATION_A, 0, "accepted", {
    action: "load_chat",
    surface: "history",
    label: "Restoring conversation…",
  }));
  await expect(status).toHaveText("Restoring conversation…");

  await receive(page, snapshot(loadScope));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");

  await receive(page, operationStatus(loadScope, OPERATION_A, 1, "running", {
    action: "load_chat",
    surface: "history",
    label: "Late restore must stay hidden",
  }));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
  await receive(page, operationStatus(loadScope, OPERATION_A, 2, "completed", {
    action: "load_chat",
    surface: "history",
  }));
  await expect(status).toHaveText("");
});


test("hydration completion preserves a newer local submission", async ({ page }) => {
  await installHarness(page);
  const { frame: registrationFrame } = await registration(page);
  await page.evaluate((chatId) => {
    for (const [action, payload] of [
      ["load_chat", { chat_id: chatId }],
      ["get_dashboard", {}],
    ]) {
      const button = document.createElement("button");
      button.className = "astral-action";
      button.dataset.action = action;
      button.dataset.payload = JSON.stringify(payload);
      document.body.appendChild(button);
      button.click();
    }
  }, CHAT_ID);
  const load = await page.evaluate(() => window.__socketEvents.find((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "load_chat"
  )).frame);
  const newer = await page.evaluate(() => window.__socketEvents.findLast((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "get_dashboard"
  )).frame);
  const status = page.locator("#astral-status");
  await expect(status).toHaveText("Submitting…");

  await receive(page, snapshot({
    connection_generation: registrationFrame.connection_generation,
    request_generation: load.request_generation,
  }));
  await expect(status).toHaveText("Submitting…");
  await expect(status).toHaveAttribute("aria-busy", "true");

  await receive(page, operationStatus({
    connection_generation: registrationFrame.connection_generation,
    request_generation: newer.request_generation,
  }, OPERATION_B, 0, "completed", {
    action: "get_dashboard",
    surface: "dashboard",
  }));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
});


test("operation status is visible only while active and terminal failures stay settled", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  const status = page.locator("#astral-status");

  const bootstrap = await page.evaluate(() => window.__socketEvents.find((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "get_history"
  )).frame);

  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
  await receive(page, operationStatus({
    connection_generation: scope.connection_generation,
    request_generation: bootstrap.request_generation,
  }, OPERATION_D, 0, "accepted", {
    action: "get_history",
    surface: "history",
    chat_id: null,
  }));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
  await receive(page, operationStatus({
    connection_generation: scope.connection_generation,
    request_generation: bootstrap.request_generation,
  }, OPERATION_D, 1, "completed", {
    action: "get_history",
    surface: "history",
    chat_id: null,
  }));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");

  await receive(page, operationStatus(scope, OPERATION_A, 0, "accepted", {
    label: "Preparing first operation…",
  }));
  await receive(page, operationStatus(scope, OPERATION_B, 0, "running", {
    label: "Working on second operation…",
  }));
  await expect(status).toHaveText("Working on second operation…");
  await expect(status).toHaveAttribute("aria-busy", "true");


  await receive(page, snapshot(scope));
  await expect(status).toHaveText("Working on second operation…");
  await expect(status).toHaveAttribute("aria-busy", "true");


  await receive(page, operationStatus(scope, OPERATION_B, 1, "completed"));
  await expect(status).toHaveText("Preparing first operation…");
  await expect(status).toHaveAttribute("aria-busy", "true");

  await receive(page, operationStatus(scope, OPERATION_C, 0, "failed"));
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");


  await receive(page, {
    type: "chat_status",
    status: "done",
    chat_id: CHAT_ID,
    connection_generation: scope.connection_generation,
    request_generation: scope.request_generation,
  });
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");


  await receive(page, operationStatus(scope, OPERATION_A, 1, "completed"));
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");


  await page.locator("#astral-input").fill("Next request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const nextScope = await page.evaluate(() => {
    const event = window.__socketEvents.findLast((candidate) => (
      candidate.frame.type === "ui_event" && candidate.frame.action === "chat_message"
    ));
    return {
      connection_generation: event.frame.connection_generation,
      request_generation: event.frame.request_generation,
    };
  });
  await expect(status).toHaveText("Submitting…");
  await expect(status).toHaveAttribute("aria-busy", "true");
  await receive(page, operationStatus(nextScope, OPERATION_E, 0, "completed"));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
  await expect(status).toHaveAttribute("data-status-state", "idle");

  await receive(page, {
    type: "chat_status",
    status: "thinking",
    chat_id: CHAT_ID,
    connection_generation: nextScope.connection_generation,
    request_generation: nextScope.request_generation,
  });
  await expect(status).toHaveText("Thinking…");
  await expect(status).toHaveAttribute("aria-busy", "true");
  await receive(page, {
    type: "chat_status",
    status: "done",
    chat_id: CHAT_ID,
    connection_generation: nextScope.connection_generation,
    request_generation: nextScope.request_generation,
  });
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
});


const EARLIER_TURN = [
  messageWithParts("earlier-question", "user", [{ type: "text", text: "Earlier question" }]),
  messageWithParts("earlier-answer", "assistant", [{ type: "text", text: "Earlier answer" }]),
];
const FAILED_QUESTION = "Summarize the discharge plan";
const SAVED_FAILURE = [
  ...EARLIER_TURN,
  messageWithParts("failed-question", "user", [{ type: "text", text: FAILED_QUESTION }]),
  messageWithParts("failed-answer", "assistant", [{ type: "text", text: "Something went wrong while processing your request." }]),
];

async function submitAfterEarlierTurn(page) {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame, {
    transcript: EARLIER_TURN, canvas: { target: "canvas", components: [] },
  }));
  await page.locator("#astral-input").fill(FAILED_QUESTION);
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  return page.evaluate(() => window.__socketEvents.findLast((event) => event.frame.action === "chat_message").frame);
}

function failedTurnCommit(scope, transcript) {
  return snapshot(scope, {
    snapshot_id: SNAPSHOT_B, snapshot_purpose: "commit", render_revision: 1, transcript,
    canvas: { target: "canvas", components: [] },
  });
}

for (const order of ["snapshot_first", "failure_first"]) {
  test(`a failed turn whose message was saved shows it once without a local retry (${order})`, async ({ page }) => {
    const scope = await submitAfterEarlierTurn(page);
    const commit = failedTurnCommit(scope, SAVED_FAILURE);
    const failed = operationStatus(scope, OPERATION_A, 0, "failed");
    for (const frame of order === "snapshot_first" ? [commit, failed] : [failed, commit]) await receive(page, frame);
    const users = page.locator(".astral-user-bubble");
    await expect(users).toHaveCount(2);
    await expect(users.nth(1)).toHaveText(FAILED_QUESTION);
    await expect(page.locator("#astral-chat")).toContainText("Something went wrong while processing your request.");
    await expect(page.locator(".astral-chat-error")).toHaveCount(0);
    await expect(page.locator(".astral-retry-btn")).toHaveCount(0);
    await expect(page.locator("#astral-status")).toHaveText("Visible terminal failure");
  });
}

for (const committed of [null, EARLIER_TURN]) {
  test(`a failed turn that saved no message restores it once with a retry (commit=${Boolean(committed)})`, async ({ page }) => {
    const scope = await submitAfterEarlierTurn(page);
    if (committed) await receive(page, failedTurnCommit(scope, committed));
    await receive(page, operationStatus(scope, OPERATION_A, 0, "failed"));
    const users = page.locator(".astral-user-bubble");
    await expect(users).toHaveCount(2);
    await expect(users.nth(1)).toContainText(FAILED_QUESTION);
    await expect(page.locator('[data-astral-transient-overlay="chat"]')).toHaveCount(0);
    const notice = page.locator(".astral-chat-error");
    await expect(notice).toHaveCount(1);
    await expect(notice).toContainText("Visible terminal failure");
    await notice.locator(".astral-retry-btn").click();
    const resent = await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.action === "chat_message")
      .map((event) => event.frame));
    expect(resent).toHaveLength(2);
    expect(resent[1].payload.message).toBe(FAILED_QUESTION);
    expect(resent[1].request_generation).not.toBe(scope.request_generation);
  });
}


test("accepted completion restores a newer unacknowledged local submission", async ({ page }) => {
  await installHarness(page);
  const { frame: registrationFrame } = await registration(page);
  const status = page.locator("#astral-status");

  await page.locator("#astral-newchat-btn").click();
  const first = await page.evaluate(() => window.__socketEvents.findLast((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "new_chat"
  )).frame);
  const firstScope = {
    connection_generation: registrationFrame.connection_generation,
    request_generation: first.request_generation,
  };
  await receive(page, operationStatus(firstScope, OPERATION_A, 0, "accepted", {
    action: "new_chat",
    surface: "operation",
    chat_id: null,
    label: "Starting first operation…",
  }));
  await expect(status).toHaveText("Starting first operation…");

  await page.locator("#astral-newchat-btn").click();
  const second = await page.evaluate(() => window.__socketEvents.findLast((candidate) => (
    candidate.frame.type === "ui_event" && candidate.frame.action === "new_chat"
  )).frame);
  await expect(status).toHaveText("Submitting…");


  await receive(page, operationStatus(firstScope, OPERATION_A, 1, "running", {
    action: "new_chat",
    surface: "operation",
    chat_id: null,
    label: "Finishing first operation…",
  }));
  await expect(status).toHaveText("Finishing first operation…");

  await receive(page, operationStatus(firstScope, OPERATION_A, 2, "completed", {
    action: "new_chat",
    surface: "operation",
    chat_id: null,
  }));
  await expect(status).toHaveText("Submitting…");
  await expect(status).toHaveAttribute("aria-busy", "true");

  await receive(page, operationStatus({
    connection_generation: registrationFrame.connection_generation,
    request_generation: second.request_generation,
  }, OPERATION_B, 0, "completed", {
    action: "new_chat",
    surface: "operation",
    chat_id: null,
  }));
  await expect(status).toHaveText("");
  await expect(status).toHaveAttribute("aria-busy", "false");
});


test("same-ID replay is inert while equal conflicts, commits, and old scope are rejected", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  const accepted = snapshot(scope);
  await receive(page, accepted);

  await receive(page, accepted);
  await receive(page, snapshot(scope, {
    canvas: { target: "canvas", components: [presentation("unsafe-replay", "Changed replay must not win")] },
  }));
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    canvas: { target: "canvas", components: [presentation("conflict", "Must not win")] },
  }));
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    snapshot_purpose: "commit",
    canvas: { target: "canvas", components: [presentation("equal-commit", "Must not win") ] },
  }));
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    connection_generation: "33333333-3333-4333-8333-333333333333",
    render_revision: 2,
    canvas: { target: "canvas", components: [presentation("old-generation", "Must not win")] },
  }));

  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas")).not.toContainText("Must not win");
  await expect(page.locator("#astral-canvas")).not.toContainText("Changed replay must not win");
});


test("normal new-turn equal is rejected, next commit wins, and lower or old request stays stale", async ({ page }) => {
  await installHarness(page);
  const { frame: hydrationScope } = await registration(page);
  await receive(page, snapshot(hydrationScope));

  await page.locator("#astral-input").fill("Next turn");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const commitScope = await page.evaluate(() => {
    const event = window.__socketEvents.findLast((candidate) => (
      candidate.frame.type === "ui_event" && candidate.frame.action === "chat_message"
    ));
    return {
      connection_generation: event.frame.connection_generation,
      request_generation: event.frame.request_generation,
    };
  });
  await receive(page, snapshot(commitScope, {
    snapshot_id: SNAPSHOT_B,
    snapshot_purpose: "commit",
    canvas: { target: "canvas", components: [presentation("equal-new-turn", "Equal must not win")] },
  }));
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas")).not.toContainText("Equal must not win");

  await receive(page, snapshot(commitScope, {
    snapshot_id: SNAPSHOT_B,
    snapshot_purpose: "commit",
    render_revision: 1,
    transcript: [{
      message_id: "message-2",
      role: "assistant",
      created_at: COMMITTED_AT,
      parts: [{ type: "text", text: "Committed next turn" }],
      attachments: [],
    }],
    canvas: { target: "canvas", components: [presentation("commit-next", "Revision one canvas")] },
  }));
  await expect(page.locator("#astral-chat")).toContainText("Committed next turn");
  await expect(page.locator("[data-astral-transient-overlay=\"chat\"]")).toHaveCount(0);
  await expect(page.locator("#astral-canvas")).toContainText("Revision one canvas");

  await receive(page, snapshot(commitScope, {
    snapshot_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    snapshot_purpose: "commit",
    render_revision: 0,
    canvas: { target: "canvas", components: [presentation("lower", "Lower must not win")] },
  }));
  await receive(page, snapshot(hydrationScope, {
    snapshot_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    render_revision: 2,
    canvas: { target: "canvas", components: [presentation("old-request", "Old request must not win")] },
  }));
  await expect(page.locator("#astral-canvas")).toContainText("Revision one canvas");
  await expect(page.locator("#astral-canvas")).not.toContainText("must not win");
});


test("semantic decoder renders structured, component, recovery, and attachment content", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  await receive(page, snapshot(scope, {
    transcript: [{
      message_id: "semantic",
      role: "assistant",
      created_at: COMMITTED_AT,
      parts: [
        { type: "text", text: "Unicode: 雪" },
        { type: "components", components: [presentation("inline", "Interactive semantic component")] },
        { type: "structured", value: { rolls: [6, 5] }, plain_text: "rolls: 6, 5" },
        { type: "recovery", code: "saved_content_unrenderable", message: "Saved content needs recovery." },
      ],
      attachments: [{ filename: "result.json" }],
    }],
  }));

  const transcript = page.locator("#astral-chat");
  await expect(transcript).toContainText("Unicode: 雪");
  await expect(transcript).toContainText("Interactive semantic component");
  await expect(transcript).toContainText("rolls: 6, 5");
  await expect(transcript).toContainText("Saved content needs recovery.");
  await expect(transcript).toContainText("result.json");
  await expect(transcript.locator("[data-structured-value]")).toHaveAttribute(
    "data-structured-value",
    '{"rolls":[6,5]}',
  );
});


test("sequenced transient overlay never mutates committed transcript or canvas", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  await receive(page, snapshot(scope));
  await page.locator("#astral-input").fill("Preview this turn");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const previewScope = await page.evaluate(() => {
    const event = window.__socketEvents.findLast((candidate) => (
      candidate.frame.type === "ui_event" && candidate.frame.action === "chat_message"
    ));
    return {
      connection_generation: event.frame.connection_generation,
      request_generation: event.frame.request_generation,
    };
  });
  const transient = {
    type: "ui_render",
    target: "canvas",
    html: '<div id="preview">Disposable preview</div>',
    chat_id: CHAT_ID,
    connection_generation: previewScope.connection_generation,
    request_generation: previewScope.request_generation,
    base_render_revision: 0,
    frame_sequence: 1,
  };
  await receive(page, transient);
  await receive(page, { ...transient, frame_sequence: 1, html: '<div>Duplicate must not win</div>' });
  await receive(page, { ...transient, frame_sequence: 2, base_render_revision: 9, html: '<div>Wrong base</div>' });
  await receive(page, {
    ...transient,
    target: "chat",
    frame_sequence: 2,
    html: '<div id="transient-answer">Transient answer</div>',
  });

  await expect(page.locator("[data-astral-transient-overlay=\"canvas\"]")).toContainText("Disposable preview");
  await expect(page.locator("[data-astral-transient-overlay=\"chat\"]")).toContainText("Transient answer");
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas")).not.toContainText("Duplicate must not win");
  await expect(page.locator("#astral-canvas")).not.toContainText("Wrong base");
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");


  await receive(page, operationStatus(previewScope, OPERATION_A, 0, "completed"));
  await expect(page.locator("#astral-status")).toHaveText("");
  await expect(page.locator("#astral-status")).toHaveAttribute("aria-busy", "false");
  await expect(page.locator("[data-astral-transient-overlay=\"chat\"]")).toContainText("Transient answer");
  await expect(page.locator("[data-astral-transient-overlay=\"canvas\"]")).toContainText("Disposable preview");
});


test("web presentation flags replace the ROTE canvas and explicit empty clears it", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  await receive(page, snapshot(scope, {
    canvas: {
      target: "canvas",
      components: [presentation("flagged", "Flagged canvas", { export: true, share: true })],
    },
  }));
  await expect(page.locator("#astral-canvas .dynamic-renderer")).toHaveAttribute("data-astral-export", "true");
  await expect(page.locator("#astral-canvas .dynamic-renderer")).toHaveAttribute("data-astral-share", "true");

  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    render_revision: 1,
    transcript: [{
      message_id: "empty-canvas",
      role: "assistant",
      created_at: COMMITTED_AT,
      parts: [{ type: "text", text: "Canvas intentionally empty" }],
      attachments: [],
    }],
    canvas: { target: "canvas", components: [] },
  }));
  await expect(page.locator("#astral-canvas .dynamic-renderer")).toHaveCount(0);
  await expect(page.locator("#astral-canvas-empty")).toContainText("Empty");
  await expect(page.locator("#astral-chat")).toContainText("Canvas intentionally empty");
});


test("invalid mixed presentation retains both committed surfaces", async ({ page }) => {
  await installHarness(page);
  const { frame: scope } = await registration(page);
  await receive(page, snapshot(scope));
  await receive(page, snapshot(scope, {
    snapshot_id: SNAPSHOT_B,
    render_revision: 1,
    transcript: [{
      message_id: "must-not-replace",
      role: "assistant",
      created_at: COMMITTED_AT,
      parts: [{ type: "text", text: "Transcript must not replace" }],
      attachments: [],
    }],
    canvas: {
      target: "canvas",
      components: [
        presentation("one", "One", { export: false, share: false }),
        presentation("two", "Two", { export: true, share: false }),
      ],
    },
  }));
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  await expect(page.locator("#astral-chat")).not.toContainText("Transcript must not replace");
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
});


test("only exact canonical admission refusals settle local submissions", async ({ page }) => {
  await installHarness(page, { locator: false });

  async function submit() {
    await page.locator("#astral-input").fill("Refusal contract probe");
    await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
    return page.evaluate(() => window.__socketEvents.findLast((candidate) => (
      candidate.frame.type === "ui_event" && candidate.frame.action === "chat_message"
    )).frame);
  }

  function refusal(frame, overrides = {}) {
    return {
      type: "error",
      submission_id: frame.submission_id,
      accepted: false,
      code: "capacity_exceeded",
      message: "Canonical refusal",
      retryable: true,
      retry_after_ms: 1000,
      ...overrides,
    };
  }

  const malformed = [
    (value) => ({ ...value, unexpected: true }),
    (value) => { const copy = { ...value }; delete copy.retry_after_ms; return copy; },
    (value) => ({ ...value, submission_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" }),
    (value) => ({ ...value, code: "toString" }),
    (value) => ({ ...value, message: "  " }),
    (value) => ({ ...value, accepted: true }),
    (value) => ({ ...value, retryable: "true" }),
    (value) => ({ ...value, retryable: false, retry_after_ms: 1 }),
    (value) => ({ ...value, retry_after_ms: -1 }),
    (value) => ({ ...value, retry_after_ms: 1.5 }),
    (value) => ({ ...value, retry_after_ms: "1000" }),
  ];
  for (const mutate of malformed) {
    const frame = await submit();
    const canonical = refusal(frame);
    await receive(page, mutate(canonical));
    await receive(page, canonical);
    await expect(page.locator("#astral-status")).toContainText("Canonical refusal");
  }

  const firstPending = await submit();
  const secondPending = await submit();
  await receive(page, refusal(firstPending, {
    submission_id: null,
    message: "Null identity must not settle",
  }));
  await receive(page, refusal(firstPending, {
    submission_id: OTHER_CHAT_ID,
    message: "Foreign identity must not settle",
  }));
  await receive(page, refusal(firstPending, { message: "First matching refusal" }));
  await expect(page.locator("#astral-status")).toContainText("First matching refusal");
  await receive(page, refusal(secondPending, { message: "Second matching refusal" }));
  await expect(page.locator("#astral-status")).toContainText("Second matching refusal");

  for (const code of ADMISSION_REFUSAL_CODES) {
    const frame = await submit();
    await receive(page, refusal(frame, { code, retry_after_ms: null }));
    await expect(page.locator("#astral-status")).toContainText("Canonical refusal");
  }

  const nonRetryable = await submit();
  await receive(page, refusal(nonRetryable, {
    code: "registration_required",
    retryable: false,
    retry_after_ms: null,
  }));
  await expect(page.locator("#astral-status")).toContainText("Canonical refusal");

  await receive(page, { type: "error", code: "forbidden", message: "Legacy error remains visible" });
  await expect(page.locator("#astral-toasts .astral-toast").last()).toHaveText(
    "Legacy error remains visible (forbidden)",
  );
});


test("located chat suppresses unscoped welcome and hydration failure retains the locator", async ({ page }) => {
  await installHarness(page);
  await receive(page, {
    type: "ui_render",
    target: "canvas",
    html: '<div id="unintended-welcome">Welcome to a new chat</div>',
  });
  await expect(page.locator("#unintended-welcome")).toHaveCount(0);
  await receive(page, { type: "error", code: "hydration_failed", message: "Retry resume", chat_id: CHAT_ID });
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).not.toBeNull();
});


test("explicit new chat clears the locator while socket loss does not", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(() => window.__sockets[0].onclose());
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).not.toBeNull();

  await page.getByRole("button", { name: "New chat" }).click();
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).toBeNull();
});


async function stageExistingFile(page, id = "old-draft-file", name = "old-draft.txt") {
  await page.evaluate(({ attachmentId, filename }) => {
    const button = document.createElement("button");
    button.className = "astral-attach-existing";
    button.dataset.attachmentId = attachmentId;
    button.dataset.filename = filename;
    document.body.append(button);
    button.click();
    button.remove();
  }, { attachmentId: id, filename: name });
}


test("new chat clears its multiline draft and attachments while accepted background work survives", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  const draft = "Unsent 088 draft\nKeep this second line.";
  await page.locator("#astral-input").fill(draft);
  await stageExistingFile(page);
  await page.locator("#astral-bg-btn").click();
  await receive(page, { type: "task_started", payload: {
    task_id: OPERATION_A, chat_id: CHAT_ID, title: "Already accepted work",
  } });

  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui").length >= 2);
  await expect(page.locator("#astral-input")).toHaveValue(draft);
  await expect(page.locator("#astral-attachments")).toContainText("old-draft.txt");
  await expect(page.locator("#astral-bg-btn")).toHaveAttribute("aria-pressed", "true");
  await page.locator("#astral-attach-btn").click();
  await expect(page.locator(".astral-attach-menu")).toHaveCount(1);

  await page.getByRole("button", { name: "New chat" }).click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("#astral-input")).toBeFocused();
  await expect(page.locator("#astral-attachments")).toBeEmpty();
  await expect(page.locator("#astral-attach-input")).toHaveValue("");
  await expect(page.locator(".astral-attach-menu")).toHaveCount(0);
  await expect(page.locator("#astral-bg-btn")).toHaveAttribute("aria-pressed", "false");
  await expect(page.locator("#astral-bgtasks")).toContainText("Already accepted work");
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID } });
  await page.locator("#astral-input").fill("Fresh request");
  await page.locator("#astral-input").press("Enter");
  const sent = await page.evaluate(() => window.__socketEvents.findLast((event) => event.frame.action === "chat_message").frame);
  expect(sent.session_id).toBe(OTHER_CHAT_ID);
  expect(sent.payload.message).toBe("Fresh request");
  expect(sent.payload.attachments).toBeUndefined();
  expect(sent.payload.async_mode).toBeUndefined();
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_A, chat_id: CHAT_ID, status: "completed", summary: "Earlier work completed",
  } });
  await expect(page.locator("#astral-bgtasks")).toBeEmpty();
  await expect(page.locator("#astral-toasts")).toContainText("Earlier work completed");
});


for (const locator of [true, false]) {
  test(`new chat cancels offline messages without dropping queued settings (locator=${locator})`, async ({ page }) => {
    await installHarness(page, { locator });
    await page.clock.install({ time: new Date("2026-09-11T12:00:00Z") });
    await page.clock.pauseAt(new Date("2026-09-11T12:00:01Z"));
    await page.evaluate(() => window.__sockets.at(-1).close());
    await stageExistingFile(page);
    await page.locator("#astral-bg-btn").click();
    await page.locator("#astral-input").fill("Old queued message");
    await page.locator("#astral-input").press("Enter");
    await expect(page.locator(".astral-bubble-queued")).toContainText("Old queued message");
    await page.evaluate(() => {
      const button = document.createElement("button");
      button.className = "astral-action";
      button.dataset.action = "chrome_open";
      button.dataset.payload = JSON.stringify({ surface: "settings" });
      document.body.append(button);
      button.click();
      button.remove();
    });
    await page.getByRole("button", { name: "New chat" }).click();
    await expect(page.locator("#astral-toasts")).toContainText("Queued messages cleared for the new chat.");
    await page.clock.runFor(5000);
    const actions = await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.type === "ui_event").map((event) => event.frame));
    expect(actions.filter((frame) => frame.action === "chat_message")).toEqual([]);
    expect(actions.filter((frame) => frame.action === "chrome_open")).toHaveLength(1);
    expect(actions.filter((frame) => frame.action === "new_chat")).toHaveLength(1);
    await expect(page.locator("#astral-chat")).not.toContainText("Old queued message");
    await expect(page.locator("#astral-attachments")).toBeEmpty();
    await expect(page.locator("#astral-bg-btn")).toHaveAttribute("aria-pressed", "false");
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  });
}


test("new chat cancels the offline expiry callback without restoring the discarded draft", async ({ page }) => {
  await installHarness(page);
  await page.clock.install({ time: new Date("2026-09-11T12:00:00Z") });
  await page.clock.pauseAt(new Date("2026-09-11T12:00:01Z"));
  await page.evaluate(() => {
    window.fetch = () => new Promise(() => {});
    window.__sockets.at(-1).close();
  });
  await page.locator("#astral-input").fill("Discarded offline draft");
  await page.locator("#astral-input").press("Enter");
  await page.getByRole("button", { name: "New chat" }).click();
  await page.clock.runFor(46000);
  await expect(page.locator("#astral-input")).toHaveValue("");


  await expect(page.locator("#astral-chat .astral-turn:not([hidden])")).toHaveCount(0);
  await expect(page.locator("#astral-status")).not.toContainText("your message was not sent");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
});


test("ordinary same-owner reconnect still sends the queued text, attachment and background choice", async ({ page }) => {
  await installHarness(page);
  await page.clock.install({ time: new Date("2026-09-11T12:00:00Z") });
  await page.clock.pauseAt(new Date("2026-09-11T12:00:01Z"));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await stageExistingFile(page);
  await page.locator("#astral-bg-btn").click();
  await page.locator("#astral-input").fill("Intended queued message");
  await page.locator("#astral-input").press("Enter");
  await page.clock.runFor(5000);
  const sent = await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.action === "chat_message").map((event) => event.frame));
  expect(sent).toHaveLength(1);
  expect(sent[0].session_id).toBe(CHAT_ID);
  expect(sent[0].payload.message).toBe("Intended queued message");
  expect(sent[0].payload.attachments).toEqual([{ attachment_id: "old-draft-file", filename: "old-draft.txt", category: "file" }]);
  expect(sent[0].payload.async_mode).toBe(true);
  await expect(page.locator(".astral-bubble-queued")).toHaveCount(0);
});


for (const outcome of ["success", "denial", "network_failure"]) {
  test(`late upload ${outcome} cannot change the new chat composer`, async ({ page }) => {
    await installHarness(page);
    await page.evaluate(() => {
      const original = window.fetch;
      window.fetch = (url, options) => {
        if (!String(url).endsWith("/api/upload")) return original(url, options);
        return new Promise((resolve, reject) => {
          window.__finishUpload = (result) => {
            if (result === "network_failure") { reject(new Error("test failure")); return; }
            resolve({ ok: result === "success", status: result === "success" ? 200 : 403,
              json: async () => result === "success"
                ? { attachment_id: "discarded-upload", parser_status: "preparing" }
                : { detail: "Discarded upload denial" } });
          };
        });
      };
    });
    await page.locator("#astral-attach-input").setInputFiles({
      name: "discarded-upload.txt", mimeType: "text/plain", buffer: Buffer.from("synthetic fixture"),
    });
    await expect(page.locator("#astral-attachments")).toContainText("discarded-upload.txt");
    await page.getByRole("button", { name: "New chat" }).click();
    await page.locator("#astral-input").fill("Fresh draft\nSecond line");
    await stageExistingFile(page, "fresh-file", "fresh-file.txt");
    const currentStatus = await page.locator("#astral-status").textContent();
    await page.evaluate((result) => window.__finishUpload(result), outcome);
    await expect(page.locator("#astral-input")).toHaveValue("Fresh draft\nSecond line");
    await expect(page.locator("#astral-attachments .astral-chip")).toHaveCount(1);
    await expect(page.locator("#astral-attachments")).toContainText("fresh-file.txt");
    await expect(page.locator("#astral-attachments")).not.toContainText("discarded-upload");
    await expect(page.locator("#astral-status")).toHaveText(currentStatus);
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  });
}


test("sign-out and confirmed deletion are definitive locator clears", async ({ page }) => {
  await installHarness(page);
  await receive(page, { type: "chat_deleted", chat_id: OTHER_CHAT_ID });
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).not.toBeNull();
  await receive(page, { type: "chat_deleted", chat_id: CHAT_ID });
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).toBeNull();

  await page.evaluate(({ key, chatId }) => localStorage.setItem(key, JSON.stringify({
    schema_version: 1,
    chat_id: chatId,
    updated_at: "2026-07-16T12:01:00Z",
  })), { key: LOCATOR_KEY, chatId: CHAT_ID });
  await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
  await page.locator("#logout").click();
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).toBeNull();
});


test("authenticated account switch clears only the previous account locator", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ key, chatId, token }) => {
    localStorage.setItem(key, JSON.stringify({
      schema_version: 1,
      chat_id: chatId,
      updated_at: "2026-07-16T12:02:00Z",
    }));
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { key: OTHER_LOCATOR_KEY, chatId: OTHER_CHAT_ID, token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction((chatId) => window.__socketEvents.some((event) => (
    event.frame.type === "register_ui" && event.frame.resume?.active_chat_id === chatId
  )), OTHER_CHAT_ID);
  expect(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).toBeNull();
  expect(await page.evaluate((key) => localStorage.getItem(key), OTHER_LOCATOR_KEY)).not.toBeNull();
});


test("sign-out erases private drafts and staged files even when navigation fails", async ({ page }) => {
  await installHarness(page);
  await receive(page, { type: "task_completed", payload: { summary: "Private task result" } });
  await page.locator("#astral-input").fill("Private draft for the first owner");
  await page.evaluate(() => {
    document.querySelector("#astral-history").textContent = "Private history";
    document.querySelector("#astral-voice-transcript").textContent = "Private spoken request";
    document.querySelector("#astral-voice-turn-notice-message").textContent = "Private voice error";
    const tour = document.createElement("div");
    tour.id = "astral-tour-card";
    tour.textContent = "Private tour detail";
    document.body.append(tour);
    const button = document.createElement("button");
    button.className = "astral-attach-existing";
    button.setAttribute("data-attachment-id", "owner-a-file");
    button.setAttribute("data-filename", "owner-a-private.txt");
    document.body.append(button);
    button.click();
    button.remove();
  });
  await page.locator("#astral-bg-btn").click();
  await expect(page.locator("#astral-attachments")).toContainText("owner-a-private.txt");
  await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
  await page.locator("#logout").click();
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("#astral-attachments")).toBeEmpty();
  await expect(page.locator("#astral-history")).toBeEmpty();
  await expect(page.locator("#astral-bg-btn")).toHaveAttribute("aria-pressed", "false");
  await expect(page.locator("#astral-voice-transcript")).toBeEmpty();
  await expect(page.locator("#astral-voice-turn-notice-message")).toBeEmpty();
  await expect(page.locator("#astral-tour-card")).toHaveCount(0);
  await expect(page.locator("#astral-toasts")).toBeEmpty();
  await receive(page, { type: "task_completed", payload: { summary: "Late private result" } });
  await receive(page, { type: "auth_required" });
  await expect(page.locator("#astral-toasts")).toBeEmpty();
  expect(await page.evaluate(() => window.__sockets.length)).toBe(1);
});


test("replaced sockets cannot deliver old-owner content or disconnect the current socket", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ token }) => {
    window.__sockets.at(-1).close();
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await page.waitForFunction(() => window.__sockets.length === 2 && window.__sockets.at(-1).readyState === 1);
  await page.evaluate(() => {
    window.__sockets[0].receive({ type: "task_completed", payload: { summary: "Old owner late result" } });
    window.__sockets[0].onerror();
  });
  await expect(page.locator("body")).not.toContainText("Old owner late result");
  expect(await page.evaluate(() => window.__sockets.at(-1).readyState)).toBe(1);
});


test("owner change erases a draft while same-owner authentication recovery retains it", async ({ page }) => {
  await installHarness(page);
  await page.locator("#astral-input").fill("Private draft for owner A");
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui").length >= 2);
  await expect(page.locator("#astral-input")).toHaveValue("Private draft for owner A");
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });

  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.waitForFunction(() => window.__socketEvents.some((event) => (
    event.frame.type === "register_ui" && event.frame.token === window.__sessionToken
  )));
  await expect(page.locator("#astral-input")).toHaveValue("");
});


test("queued owner-A work is discarded before owner-B registration can flush it", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ token }) => {
    window.__sockets.at(-1).close();
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await page.locator("#astral-input").fill("Owner A queued private request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await page.waitForFunction(() => window.__socketEvents.some((event) => (
    event.frame.type === "register_ui" && event.frame.token === window.__sessionToken
  )));
  const leaked = await page.evaluate(() => window.__socketEvents.filter((event) => (
    event.frame.type === "ui_event" && event.frame.action === "chat_message"
  )));
  expect(leaked).toEqual([]);
  await expect(page.locator("#astral-chat")).not.toContainText("Owner A queued private request");
});


for (const outcome of ["success", "denial", "network_failure"]) {
  test(`late owner-A upload ${outcome} cannot restore private UI after sign-out`, async ({ page }) => {
    await installHarness(page);
    await page.evaluate(() => {
      const original = window.fetch;
      window.fetch = (url, options) => {
        if (!String(url).endsWith("/api/upload")) return original(url, options);
        return new Promise((resolve, reject) => {
          window.__finishUpload = (result) => {
            if (result === "network_failure") { reject(new Error("test failure")); return; }
            resolve({ ok: result === "success", status: result === "success" ? 200 : 403,
              json: async () => result === "success"
                ? { attachment_id: "owner-a-upload", parser_status: "preparing" }
                : { detail: "Private upload denial" } });
          };
        });
      };
    });
    await page.locator("#astral-attach-input").setInputFiles({
      name: "owner-a-private.txt", mimeType: "text/plain", buffer: Buffer.from("synthetic fixture"),
    });
    await expect(page.locator("#astral-attachments")).toContainText("owner-a-private.txt");
    await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
    await page.locator("#logout").click();
    await page.evaluate((result) => window.__finishUpload(result), outcome);
    await expect(page.locator("#astral-attachments")).toBeEmpty();
    await expect(page.locator("#astral-status")).toBeEmpty();
    await expect(page.locator("#astral-attach-input")).toHaveValue("");
  });
}


test("late old-owner command discovery cannot replace the new owner's commands", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ oldToken, newToken }) => {
    const original = window.fetch;
    window.fetch = (url, options) => {
      if (!String(url).endsWith("/api/chrome/commands")) return original(url, options);
      if (options.headers.Authorization === `Bearer ${oldToken}`) {
        return new Promise((resolve) => {
          window.__finishOldCommands = () => resolve({ ok: true, json: async () => ({
            commands: [{ name: "/private-a", desc: "Owner A private guidance", mine: true }],
          }) });
        });
      }
      return Promise.resolve({ ok: true, json: async () => ({
        commands: [{ name: "/private-b", desc: "Owner B guidance", mine: true }],
      }) });
    };
    window.__astralResetCommands(oldToken);
    window.__sessionToken = newToken;
    window.__sessionSubject = "other-user";
  }, { oldToken: TOKEN, newToken: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__socketEvents.some((event) => (
    event.frame.type === "register_ui" && event.frame.token === window.__sessionToken
  )));
  await page.evaluate(() => window.__finishOldCommands());
  await page.locator("#astral-input").fill("/private");
  await expect(page.locator("#astral-slash-menu")).toContainText("/private-b");
  await expect(page.locator("#astral-slash-menu")).not.toContainText("/private-a");
});


test("unknown locator schema is retained but never interpreted", async ({ page }) => {
  await page.addInitScript(({ key, chatId }) => {
    localStorage.setItem(key, JSON.stringify({
      schema_version: 2,
      chat_id: chatId,
      updated_at: "2026-07-16T12:03:00Z",
    }));
  }, { key: LOCATOR_KEY, chatId: CHAT_ID });
  await installHarness(page, { locator: false });
  const event = await registration(page);
  expect(event.frame.resume).toBeUndefined();
  expect(JSON.parse(await page.evaluate((key) => localStorage.getItem(key), LOCATOR_KEY)).schema_version).toBe(2);
});


test("URL-selected chat is persisted before its first registration", async ({ page }) => {
  await installHarness(page, {
    locator: false,
    url: `https://candidate.example/?chat=${OTHER_CHAT_ID}`,
  });
  const event = await registration(page);
  expect(event.frame.resume.active_chat_id).toBe(OTHER_CHAT_ID);
  expect(JSON.parse(event.locatorAtSend).chat_id).toBe(OTHER_CHAT_ID);
});


test("authentication recovery to a different owner replaces the socket before accepting more content", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__socketEvents.some((event) => (
    event.frame.type === "register_ui" && event.frame.token === window.__sessionToken
  )));
  await page.evaluate(() => {
    window.__sockets[0].receive({ type: "notification", title: "Owner A private title", body: "Private detail" });
    window.__sockets[0].receive({ type: "chrome_render", region: "modal", html: "Owner A private modal" });
  });
  await expect(page.locator("body")).not.toContainText("Owner A private");
  expect(await page.evaluate(() => window.__sockets.length)).toBe(2);
  expect(await page.evaluate(() => window.__sockets[0].readyState)).toBe(3);
  const registrations = await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui"));
  expect(registrations).toHaveLength(2);
  expect(registrations[1].frame.connection_generation).not.toBe(registrations[0].frame.connection_generation);
});


async function installDeferredAccountEffect(page, effect) {
  const fonts = {};
  if (effect === "export") {
    const { frame } = await registration(page);
    await receive(page, snapshot(frame));
    for (const name of ["open-sans-latin.woff2"]) {
      fonts[name] = (await readFile(resolve(ROOT, "backend/webrender/static/fonts", name))).toString("base64");
    }
  }
  await page.evaluate(({ kind, fonts }) => {
    window.__effectDownloads = [];
    window.__effectClipboard = [];
    const click = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () {
      if (this.download) { window.__effectDownloads.push(this.download); return; }
      click.call(this);
    };
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
      writeText: async (text) => { window.__effectClipboard.push(text); },
    } });
    const original = window.fetch;
    window.fetch = (url, options) => {
      if (String(url).includes("/static/fonts/")) {
        const name = String(url).split("/").at(-1);
        return Promise.resolve(new Response(Uint8Array.from(atob(fonts[name]), char => char.charCodeAt(0))));
      }
      if (!String(url).includes(kind === "export" ? "/api/export/" : "/api/share")) return original(url, options);
      window.__effectAuthorization = options.headers.Authorization;
      return new Promise((resolve, reject) => {
        window.__finishAccountEffect = (result) => {
          if (result === "network_failure") { reject(new Error("Private effect error")); return; }
          resolve({ ok: result === "success", status: result === "success" ? 200 : 403,
            headers: new Headers({ "X-Astral-Render-Revision": new URL(url).searchParams.get("render_revision") || "0" }),
            blob: async () => new Blob(["Private export content"]),
            json: async () => result === "success"
              ? { share_url: "https://candidate.example/s/private-owner-a" }
              : { detail: "Private share denial" },
          });
        };
      });
    };
    const button = document.createElement("button");
    button.className = kind === "export" ? "astral-export-canvas" : "astral-share-btn";
    button.setAttribute("data-share-scope", "canvas");
    document.body.append(button);
    button.click();
    button.remove();
  }, { kind: effect, fonts });
  expect(await page.evaluate(() => window.__effectAuthorization)).toBe(`Bearer ${TOKEN}`);
}


for (const effect of ["export", "share"]) {
  for (const outcome of ["success", "denial", "network_failure"]) {
    test(`late owner-A ${effect} ${outcome} cannot download, copy or report private content after sign-out`, async ({ page }) => {
      await installHarness(page);
      await installDeferredAccountEffect(page, effect);
      await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
      await page.locator("#logout").click();
      await page.evaluate(async (result) => {
        window.__finishAccountEffect(result);
        await new Promise((resolve) => setTimeout(resolve, 0));
      }, outcome);
      expect(await page.evaluate(() => window.__effectDownloads)).toEqual([]);
      expect(await page.evaluate(() => window.__effectClipboard)).toEqual([]);
      await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
    });
  }

  test(`same-owner ${effect} completion remains available`, async ({ page }) => {
    await installHarness(page);
    await installDeferredAccountEffect(page, effect);
    await page.evaluate(async () => {
      window.__finishAccountEffect("success");
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await expect.poll(() => page.evaluate((kind) => (
      kind === "export" ? window.__effectDownloads.length : window.__effectClipboard.length
    ), effect)).toBe(1);
  });
}


for (const outcome of ["success", "failure"]) {
  test(`a share clipboard ${outcome} after sign-out cannot restore a private toast`, async ({ page }) => {
    await installHarness(page);
    await installDeferredAccountEffect(page, "share");
    await page.evaluate(() => {
      navigator.clipboard.writeText = () => new Promise((resolve, reject) => {
        window.__finishClipboard = (result) => result === "success" ? resolve() : reject(new Error("Clipboard denied"));
      });
      window.__finishAccountEffect("success");
    });
    await page.waitForFunction(() => typeof window.__finishClipboard === "function");
    await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
    await page.locator("#logout").click();
    await page.evaluate(async (result) => {
      window.__finishClipboard(result);
      await new Promise((resolve) => setTimeout(resolve, 0));
    }, outcome);
    await expect(page.locator("#astral-toasts .astral-toast")).toHaveCount(0);
  });
}


test("a late session refresh cannot restore credentials or reconnect after sign-out", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ token }) => {
    const original = window.fetch;
    window.fetch = (url, options) => {
      if (!String(url).endsWith("/auth/session")) return original(url, options);
      return new Promise((resolve) => {
        window.__finishSession = () => resolve({ json: async () => ({ authenticated: true, access_token: token }) });
      });
    };
  }, { token: TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => typeof window.__finishSession === "function");
  await page.locator("#logout").evaluate((link) => link.addEventListener("click", (event) => event.preventDefault()));
  await page.locator("#logout").click();
  await page.evaluate(async () => {
    window.__finishSession();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(await page.evaluate(() => window.__ASTRAL_TOKEN__)).toBe("");
  expect(await page.evaluate(() => window.__sockets.length)).toBe(1);
  expect(await page.evaluate(() => window.__sockets[0].readyState)).toBe(3);
  expect(await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui").length)).toBe(1);
});


test("a fresh empty conversation stays centered through welcome rendering and same-owner recovery", async ({ page }) => {
  await installHarness(page, { locator: false });
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await receive(page, { type: "ui_render", target: "canvas", html:
    '<div class="dynamic-renderer"><section data-welcome="intro">How can I help?</section>'
    + '<div data-welcome="examples"><button>Research brief</button></div>'
    + '<div data-welcome="permission"><button>Enable recommended agents</button></div></div>' });
  await page.locator("#astral-input").fill("A draft that has not been sent");
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui").length === 2);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await expect(page.locator("#astral-input")).toHaveValue("A draft that has not been sent");
});


test("an existing conversation selects work before its first registration", async ({ page }) => {
  await installHarness(page);
  expect((await registration(page)).viewAtSend).toBe("work");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
});


test("ordinary first Send reveals work immediately and new chat returns to start", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("A normal first request");
  await page.locator("#astral-input").press("Enter");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  const sent = await page.evaluate(() => window.__socketEvents.filter((event) => (
    event.frame.type === "ui_event" && event.frame.action === "chat_message"
  )));
  expect(sent).toHaveLength(1);
  expect(sent[0].viewAtSend).toBe("work");
  expect(sent[0].frame.payload.message).toBe("A normal first request");
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID } });
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
});


test("a first offline Send reveals its queued conversation immediately", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.locator("#astral-input").fill("Queued first request");
  await page.locator("#astral-input").press("Enter");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  await expect(page.locator("#astral-chat")).toContainText("Queued first request");
});


for (const target of ["canvas", "chat"]) {
  test(`actual ${target} content reveals work without a welcome identifier or local Send`, async ({ page }) => {
    await installHarness(page, { locator: false });
    await receive(page, { type: "ui_render", target: "canvas", html: '<div class="dynamic-renderer"></div>', components: [] });
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
    await receive(page, { type: "ui_render", target, html: "<p>A real response</p>" });
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
    await receive(page, { type: "ui_render", target: "canvas", html: "", components: [] });
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  });
}


for (const width of [1280, 850, 390]) {
  test(`history remains reachable from the centered start view at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await installHarness(page, { locator: false });
    await receive(page, { type: "ui_render", target: "history", html: "<button>Previous conversation</button>" });
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
    await page.locator("#astral-chats-btn").click();
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
    await expect(page.locator("body")).toHaveClass(/astral-history-open/);
    if (width === 850) await expect(page.locator("body")).toHaveClass(/astral-chat-open/);
    await expect(page.locator("#astral-history")).toContainText("Previous conversation");
  });
}


test("owner change returns to start when the new owner has no saved conversation", async ({ page }) => {
  await installHarness(page);
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
});


test("textarea Shift+Enter creates a newline and Enter submits the full prompt", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("First line");
  await page.locator("#astral-input").press("Shift+Enter");
  await page.locator("#astral-input").pressSequentially("Second line");
  await expect(page.locator("#astral-input")).toHaveValue("First line\nSecond line");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await page.locator("#astral-input").press("Enter");
  await expect(page.locator("#astral-input")).toHaveValue("");
  const messages = await page.evaluate(() => window.__socketEvents.filter((event) => (
    event.frame.type === "ui_event" && event.frame.action === "chat_message"
  )).map((event) => event.frame.payload.message));
  expect(messages).toEqual(["First line\nSecond line"]);
});


test("IME Enter and Enter in another textarea never send the composer", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("Still composing");
  await page.locator("#astral-input").dispatchEvent("keydown", { key: "Enter", isComposing: true });
  await page.locator("#astral-input").dispatchEvent("keydown", { key: "Enter", keyCode: 229 });
  await page.evaluate(() => {
    const field = document.createElement("textarea");
    field.id = "other-field";
    document.body.append(field);
  });
  await page.locator("#other-field").fill("Other form");
  await page.locator("#other-field").press("Enter");
  await expect(page.locator("#astral-input")).toHaveValue("Still composing");
  expect(await page.evaluate(() => window.__socketEvents.filter((event) => (
    event.frame.type === "ui_event" && event.frame.action === "chat_message"
  )).length)).toBe(0);
});


test("textarea slash discovery selection, Escape and New chat remain usable", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("/help");
  await expect(page.locator("#astral-slash-menu")).not.toHaveClass(/hidden/);
  await page.locator("#astral-slash-menu button").first().dispatchEvent("mousedown");
  await expect(page.locator("#astral-input")).toHaveValue("/help ");
  await page.locator("#astral-input").fill("/help");
  await page.locator("#astral-input").press("Escape");
  await expect(page.locator("#astral-slash-menu")).toHaveClass(/hidden/);
  await page.locator("#astral-input").fill("/help");
  await expect(page.locator("#astral-slash-menu")).not.toHaveClass(/hidden/);

  await page.locator("#astral-newchat-btn").evaluate((button) => button.click());
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("#astral-slash-menu")).toBeEmpty();
  await expect(page.locator("#astral-slash-menu")).toHaveClass(/hidden/);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
});


function welcomeHtml({ wrapped = true, permission = true, title = "How can I help?" } = {}) {
  const content = [
    ["intro", `<h2 data-welcome="intro">${title}</h2>`],
    ...(permission ? [["permission", '<section data-welcome="permission"><button>Enable recommended agents</button></section>']] : []),
    ["examples", '<div data-welcome="examples"><button id="welcome-example" class="astral-action" data-action="chat_message" data-payload=\'{"message":"A welcome example"}\'>Research brief</button></div>'],
    ["more", '<details data-welcome="more"><summary>More examples</summary><button>Another example</button></details>'],
  ];
  return wrapped
    ? '<div class="dynamic-renderer">' + content.map(([role, html]) => (
      `<section class="astral-component" data-component-id="wel_${role}">${html}</section>`
    )).join("") + "</div>"
    : content.map(([, html]) => html).join("");
}


test("welcome slots adopt exact server nodes and preserve the mounted composer and voice controls", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("Unsent draft");
  await page.evaluate((html) => {
    window.__composerNode = document.getElementById("astral-form");
    window.__inputNode = document.getElementById("astral-input");
    window.__voiceNode = document.getElementById("astral-voice-controls");
    window.__voiceControlNode = window.__voiceNode.firstElementChild;
    window.__sockets.at(-1).receive({ type: "ui_render", target: "canvas", html });
    window.__welcomeIntroNode = document.querySelector('#astral-canvas [data-component-id="wel_intro"]');
  }, welcomeHtml());
  await expect(page.locator("#astral-start-intro")).toContainText("How can I help?");
  expect(await page.evaluate(() => (
    document.getElementById("astral-start-intro").firstElementChild === window.__welcomeIntroNode
    && document.getElementById("astral-form") === window.__composerNode
    && document.getElementById("astral-input") === window.__inputNode
    && document.getElementById("astral-voice-controls") === window.__voiceNode
    && window.__voiceNode.firstElementChild === window.__voiceControlNode
  ))).toBe(true);
  await expect(page.locator("#astral-input")).toHaveValue("Unsent draft");
  await expect(page.locator("#astral-canvas [data-welcome]")).toHaveCount(0);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await page.locator("#astral-input").focus();
  await page.keyboard.press("Tab");
  await expect(page.locator('#astral-form button[type="submit"]')).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.locator("#welcome-example")).toBeFocused();
});


test("a repeated legacy welcome replaces each slot and removes obsolete permission content", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml() });
  await expect(page.locator("#astral-start-permission")).toContainText("Enable recommended agents");
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml({ wrapped: false, permission: false, title: "Welcome again" }) });
  await expect(page.locator("#astral-start-intro")).toHaveText("Welcome again");
  await expect(page.locator("#astral-start-permission")).toBeEmpty();
  await expect(page.locator('[data-welcome="examples"]')).toHaveCount(1);
  await expect(page.locator('[data-welcome="more"]')).toHaveCount(1);
  await page.locator("#welcome-example").click();
  expect(await page.evaluate(() => window.__socketEvents.filter((event) => (
    event.frame.type === "ui_event" && event.frame.action === "chat_message"
  )).map((event) => event.frame.payload.message))).toEqual(["A welcome example"]);
  await expect(page.locator('[id^="astral-start-"] [data-welcome]')).toHaveCount(0);
});


test("new chat receives a fresh welcome in the same slots and account change clears them", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml() });
  await page.locator("#welcome-example").click();
  await page.locator("#astral-newchat-btn").click();
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml({ title: "A new start" }) });

  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID } });
  await expect(page.locator("#astral-start-intro")).toHaveText("A new start");
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2);
  await expect(page.locator('[id^="astral-start-"]')).toHaveCount(4);
  await expect(page.locator('[id^="astral-start-"] [data-welcome]')).toHaveCount(0);
});


for (const rendering of ["workspace", "legacy"]) {
  test(`mobile New chat retains every welcome slot before tablet re-adaptation (${rendering})`, async ({ page }) => {


    const frames = JSON.parse(await readFile(resolve(ROOT, "tooling/web-ci/fixtures/welcome-rendering-088.json"), "utf8"));
    await page.setViewportSize({ width: 390, height: 900 });
    await installHarness(page);
    await receive(page, snapshot((await registration(page)).frame, {
      canvas: { target: "canvas", components: [] },
    }));
    await page.locator("#astral-msgs-toggle").click();
    await expect(page.locator("#astral-chat")).toContainText("Committed answer");
    await page.locator("#astral-newchat-btn").click();
    await receive(page, { type: "ui_render", target: "canvas", html: frames.mobile[rendering] });
    await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID } });

    async function expectCompleteWelcome() {
      await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
      await expect(page.locator("#astral-start-intro")).toContainText("How can I help?");
      await expect(page.locator("#astral-start-permission")).toContainText("Agents are off for this account");
      await expect(page.locator('#astral-start-examples [data-action="chat_message"]')).toHaveCount(3);
      await expect(page.locator("#astral-start-more")).toContainText("More examples");
      await expect(page.locator('#astral-start-more [data-action="chat_message"]')).toHaveCount(3);
      await expect(page.locator('#astral-canvas [data-action="chat_message"]')).toHaveCount(0);
      await expect(page.locator("#astral-input")).toHaveValue("");
    }
    await expectCompleteWelcome();


    await page.setViewportSize({ width: 694, height: 900 });
    await receive(page, { type: "rote_config", device_profile: { device_type: "tablet" } });
    await receive(page, { type: "ui_update", html: frames.tablet.legacy });
    await expectCompleteWelcome();
    await page.locator("#astral-newchat-btn").click();
    await receive(page, { type: "ui_render", target: "canvas", html: frames.tablet[rendering] });
    await receive(page, { type: "chat_created", payload: { chat_id: CHAT_ID } });
    await expectCompleteWelcome();
  });
}


test("late welcome cannot replace work content or repopulate the start slots", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: "<p>Current work result</p>" });
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml() });


  await expect(page.locator("#astral-canvas")).toContainText("Current work result");
  await expect(page.locator("#astral-canvas [data-welcome]")).toHaveCount(0);
  await expect(page.locator('[id^="astral-start-"] [data-welcome]')).toHaveCount(0);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
});


test("unknown or nested welcome-like markers remain ordinary canvas content", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html:
    '<div class="dynamic-renderer"><section class="astral-component" data-component-id="saved-widget">'
    + '<div data-welcome="intro">Saved component content</div></section>'
    + '<p data-welcome="unrecognized">Ordinary output</p></div>' });
  await expect(page.locator("#astral-canvas")).toContainText("Saved component content");
  await expect(page.locator("#astral-canvas")).toContainText("Ordinary output");
  await expect(page.locator('[id^="astral-start-"] [data-welcome]')).toHaveCount(0);
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
});


for (const update of ["append", "upsert"]) {
  test(`a partial welcome ${update} preserves the other slots and identity removal works`, async ({ page }) => {
    await installHarness(page, { locator: false });
    await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml() });
    const html = '<section class="astral-component" data-component-id="wel_intro"><h2 data-welcome="intro">Updated heading</h2></section>';
    await receive(page, update === "append"
      ? { type: "ui_append", html }
      : { type: "ui_upsert", ops: [{ op: "replace", component_id: "wel_intro", html }] });
    await expect(page.locator("#astral-start-intro")).toHaveText("Updated heading");
    await expect(page.locator("#astral-start-permission")).toContainText("Enable recommended agents");
    await expect(page.locator("#astral-start-examples")).toContainText("Research brief");
    await expect(page.locator("#astral-start-more")).toContainText("More examples");
    await receive(page, { type: "ui_upsert", ops: [{ op: "remove", component_id: "wel_permission" }] });
    await expect(page.locator("#astral-start-permission")).toBeEmpty();
    await expect(page.locator("#astral-start-intro")).toHaveText("Updated heading");
    await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  });
}

function chromeConversationButton(payload) {
  return execFileSync("python3", ["-c", [
    "import json,sys",
    "sys.path.insert(0,sys.argv[1])",
    "from astralprojection.chrome import render_html",
    "from astralprojection.models import ChromeViewModel,ComponentView",
    'button=ComponentView("button",{"label":"Open conversation","action":"load_chat","payload":json.loads(sys.argv[2])})',
    'print(render_html(ChromeViewModel("search","Search",(button,))))',
  ].join("\n"), resolve(ROOT, "src"), JSON.stringify(payload)], {cwd: ROOT, encoding: "utf8"});
}

async function offerChromeConversation(page, payload) {
  await receive(page, {type: "chrome_render", region: "modal", mode: "replace",
    html: `<div class="astral-modal-card" role="dialog" tabindex="-1">${chromeConversationButton(payload)}</div>`});
}

test("shared chrome conversation navigation selects and hydrates the target before the next explicit send", async ({page}) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await offerChromeConversation(page, {chat_id: OTHER_CHAT_ID});
  const before = await page.evaluate(() => window.__socketEvents.length);
  await page.getByRole("button", {name: "Open conversation", exact: true}).click();
  const frames = await page.evaluate(index => window.__socketEvents.slice(index).map(event => event.frame), before);
  const load = frames.find(frame => frame.action === "load_chat");
  expect(load.session_id).toBe(OTHER_CHAT_ID);
  expect(load.payload.chat_id).toBe(OTHER_CHAT_ID);
  expect(load.payload.snapshot_purpose).toBe("hydration");
  expect(load.payload.request_generation).toBe(load.request_generation);
  expect(frames.filter(frame => frame.action === "load_chat")).toHaveLength(1);
  expect(frames.some(frame => frame.action === "chat_message")).toBe(false);
  await expect(page.getByRole("button", {name: "Open conversation", exact: true})).toHaveCount(0);
  await receive(page, snapshot(load, {chat_id: OTHER_CHAT_ID, snapshot_id: SNAPSHOT_B,
    transcript: [{message_id: "target-message", role: "assistant", created_at: COMMITTED_AT,
      parts: [{type: "text", text: "Target conversation hydrated"}], attachments: []}],
    canvas: {target: "canvas", components: [presentation("target-canvas", "Target source result")]},
  }));
  await expect(page.locator("#astral-chat")).toContainText("Target conversation hydrated");
  await expect(page.locator('[data-component-id="target-canvas"]')).toBeVisible();
  await expect(page.locator("#astral-chat")).not.toContainText("Committed answer");
  expect(await page.evaluate(key => JSON.parse(localStorage.getItem(key)).chat_id, LOCATOR_KEY)).toBe(OTHER_CHAT_ID);
  await page.locator("#astral-input").fill("Explicit next message");
  await page.getByRole("button", {name: "Send", exact: true}).click();
  const sends = await page.evaluate(() => window.__socketEvents.map(event => event.frame).filter(frame => frame.action === "chat_message"));
  expect(sends).toHaveLength(1);
  expect(sends[0].session_id).toBe(OTHER_CHAT_ID);
  expect(sends[0].payload.chat_id).not.toBe(CHAT_ID);
});

for (const target of [null, "", "not-a-chat", 42]) {
  test(`shared chrome refuses malformed conversation target ${JSON.stringify(target)}`, async ({page}) => {
    await installHarness(page);
    await offerChromeConversation(page, {chat_id: target});
    const before = await page.evaluate(() => window.__socketEvents.length);
    await page.getByRole("button", {name: "Open conversation", exact: true}).click();
    expect(await page.evaluate(index => window.__socketEvents.slice(index), before)).toEqual([]);
    expect(await page.evaluate(key => JSON.parse(localStorage.getItem(key)).chat_id, LOCATOR_KEY)).toBe(CHAT_ID);
  });
}

for (const retirement of ["disconnected", "mandatory", "removed"]) {
  test(`shared chrome conversation navigation rejects ${retirement} offers`, async ({page}) => {
    await installHarness(page);
    await offerChromeConversation(page, {chat_id: OTHER_CHAT_ID});
    const button = await page.getByRole("button", {name: "Open conversation", exact: true}).elementHandle();
    await page.evaluate(change => {
      if (change === "disconnected") window.__sockets.at(-1).readyState = 3;
      if (change === "mandatory") document.querySelector(".astral-modal-card").setAttribute("data-mandatory", "true");
      if (change === "removed") document.querySelector("#astral-modal").replaceChildren();
    }, retirement);
    const before = await page.evaluate(() => window.__socketEvents.length);
    await button.evaluate(element => element.click());
    expect(await page.evaluate(index => window.__socketEvents.slice(index), before)).toEqual([]);
    expect(await page.evaluate(key => JSON.parse(localStorage.getItem(key)).chat_id, LOCATOR_KEY)).toBe(CHAT_ID);
  });
}


const THIRD_CHAT_ID = "33333333-3333-4333-8333-333333333333";
const EARLIER_TURN_WAIT = "Finishing the previous reply. This chat will open when it ends.";

async function startTurnInChat(page, options = {}) {
  await installHarness(page, options);
  const { frame: registrationFrame } = await registration(page);
  await receive(page, snapshot(registrationFrame));
  await page.locator("#astral-input").fill("A long request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  const turnScope = {
    connection_generation: registrationFrame.connection_generation,
    request_generation: message.request_generation,
  };
  await receive(page, operationStatus(turnScope, OPERATION_A, 0, "accepted"));
  await receive(page, operationStatus(turnScope, OPERATION_A, 1, "running"));
  return { registrationFrame, turnScope };
}

async function openChatFromHistory(page, chatId) {
  await page.evaluate((id) => {
    const button = document.createElement("button");
    button.className = "astral-action";
    button.dataset.action = "load_chat";
    button.dataset.payload = JSON.stringify({ chat_id: id });
    document.body.appendChild(button);
    button.click();
    button.remove();
  }, chatId);
}

async function sentLoads(page) {
  return page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.type === "ui_event" && event.frame.action === "load_chat")
    .map((event) => event.frame));
}

test("opening another chat during a running turn holds the load until the turn ends", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);

  expect(await sentLoads(page)).toHaveLength(0);
  const status = page.locator("#astral-status");
  await expect(status).toHaveText(EARLIER_TURN_WAIT);
  await expect(page.locator("#astral-chat")).not.toContainText("Committed answer");
  await expect(page.locator("#astral-canvas")).not.toContainText("ROTE-adapted canvas");
  await expect(page.locator("body")).toHaveClass(/astral-chat-active/u);
  expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key)).chat_id, LOCATOR_KEY))
    .toBe(OTHER_CHAT_ID);

  await receive(page, { type: "chat_status", status: "thinking", message: "Left turn status" });
  await receive(page, { type: "chat_step", step: { name: "left_tool", status: "in_progress" } });
  await receive(page, { type: "tool_progress", tool_name: "left_tool", message: "Left progress" });
  await expect(status).toHaveText(EARLIER_TURN_WAIT);
  expect(await sentLoads(page)).toHaveLength(0);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload).toEqual(expect.objectContaining({
    chat_id: OTHER_CHAT_ID,
    connection_generation: turnScope.connection_generation,
    snapshot_purpose: "hydration",
  }));
  await expect(status).not.toHaveText(EARLIER_TURN_WAIT);

  await receive(page, snapshot({
    connection_generation: turnScope.connection_generation,
    request_generation: loads[0].request_generation,
  }, { chat_id: OTHER_CHAT_ID, snapshot_id: SNAPSHOT_B }));
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  await expect(status).toHaveText("");
});

test("only the last chat opened during the wait loads and reopening it changes nothing", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await openChatFromHistory(page, THIRD_CHAT_ID);
  await openChatFromHistory(page, THIRD_CHAT_ID);
  expect(await sentLoads(page)).toHaveLength(0);

  await receive(page, { type: "chat_status", status: "done", message: "" });
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(THIRD_CHAT_ID);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentLoads(page)).toHaveLength(1);
});

test("an immediate cancel keeps the wait until the left turn finishes unwinding", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);

  await receive(page, { type: "chat_status", status: "done", message: "Cancelled" });
  expect(await sentLoads(page)).toHaveLength(0);
  await expect(page.locator("#astral-status")).toHaveText(EARLIER_TURN_WAIT);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "cancelled", {
    error: { code: "cancelled_by_user", message: "Cancelled" },
  }));
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(OTHER_CHAT_ID);
});

test("a disconnect drops the held load and reconnecting hydrates the chat being opened", async ({ page }) => {
  await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.waitForFunction(() => window.__sockets.length === 2
    && window.__sockets[1].sent.some((frame) => frame.type === "register_ui"), null, { timeout: 10000 });

  const reconnect = await page.evaluate(() => window.__sockets[1].sent.find((frame) => frame.type === "register_ui"));
  expect(reconnect.resume.active_chat_id).toBe(OTHER_CHAT_ID);
  await receive(page, { type: "chat_status", status: "done", message: "" });
  expect(await sentLoads(page)).toHaveLength(0);
  await expect(page.locator("#astral-status")).not.toHaveText(EARLIER_TURN_WAIT);
});

test("a left turn's completion ends its submission so the next switch loads at once", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentLoads(page)).toHaveLength(1);

  await openChatFromHistory(page, CHAT_ID);
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(2);
  expect(loads[1].payload.chat_id).toBe(CHAT_ID);
  await expect(page.locator("#astral-status")).not.toHaveText(EARLIER_TURN_WAIT);
});

test("new chat during a running turn shows none of the left turn's output or status", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "start");
  const leftFrame = {
    chat_id: CHAT_ID,
    connection_generation: turnScope.connection_generation,
    request_generation: turnScope.request_generation,
    base_render_revision: 0,
  };

  await receive(page, { ...leftFrame, type: "ui_stream_data", stream_id: "left-stream", session_id: CHAT_ID,
    seq: 0, components: [], html: "<p>Left streamed text</p>", raw: "", terminal: false, error: null, frame_sequence: 1 });
  await receive(page, { ...leftFrame, type: "ui_upsert", frame_sequence: 2,
    ops: [{ op: "upsert", component_id: "left-card", html: '<div data-component-id="left-card">Left card</div>' }] });
  await receive(page, { ...leftFrame, type: "ui_render", target: "chat", html: "<p>Left reply</p>", frame_sequence: 3 });
  await receive(page, { ...leftFrame, type: "ui_update", html: "<p>Left update</p>", frame_sequence: 4 });
  await receive(page, { ...leftFrame, type: "ui_append", html: "<p>Left append</p>", frame_sequence: 5 });
  await receive(page, { type: "chat_step", chat_id: CHAT_ID, step: { name: "left_tool", status: "completed" } });
  await receive(page, { type: "chat_status", status: "thinking", message: "Left turn status" });
  await receive(page, { type: "tool_progress", chat_id: CHAT_ID, tool_name: "left_tool", message: "Left progress" });

  for (const text of ["Left streamed text", "Left card", "Left reply", "Left update", "Left append"]) {
    await expect(page.locator("body")).not.toContainText(text);
  }
  await expect(page.locator("#astral-status")).not.toContainText("Left");

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  await receive(page, { type: "chat_status", status: "thinking", message: "New chat status" });
  await expect(page.locator("#astral-status")).toHaveText("New chat status");
});

test("an owner change drops a held load so the new owner's status is shown", async ({ page }) => {
  await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2
    && window.__sockets[1].sent.some((frame) => frame.type === "register_ui"));

  await receive(page, { type: "chat_status", status: "thinking", message: "New owner status" });
  await expect(page.locator("#astral-status")).toHaveText("New owner status");
  expect(await sentLoads(page)).toHaveLength(0);
});

test("an admission refusal of the left message ends the wait", async ({ page }) => {
  await installHarness(page);
  const { frame: registrationFrame } = await registration(page);
  await receive(page, snapshot(registrationFrame));
  await page.locator("#astral-input").fill("A long request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  expect(await sentLoads(page)).toHaveLength(0);

  await receive(page, { type: "error", accepted: false, code: "capacity_exceeded", message: "Busy right now",
    retry_after_ms: null, retryable: false, submission_id: message.submission_id });
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(OTHER_CHAT_ID);
});

test("a queued first message's chat creation cannot take over the chat being opened", async ({ page }) => {
  await installHarness(page, { locator: false });
  const { frame: registrationFrame } = await registration(page);
  await page.locator("#astral-input").fill("First message");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await expect(page.locator("#astral-status")).toHaveText(EARLIER_TURN_WAIT);

  await receive(page, { type: "chat_created", payload: { chat_id: THIRD_CHAT_ID } });
  expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key)).chat_id, LOCATOR_KEY))
    .toBe(OTHER_CHAT_ID);
  await receive(page, operationStatus({
    connection_generation: registrationFrame.connection_generation,
    request_generation: message.request_generation,
  }, OPERATION_B, 0, "completed", { chat_id: THIRD_CHAT_ID }));
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(OTHER_CHAT_ID);
});

test("returning to the running chat while waiting keeps its status, steps and failure out of view", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await openChatFromHistory(page, CHAT_ID);
  const status = page.locator("#astral-status");
  await expect(status).toHaveText(EARLIER_TURN_WAIT);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "running", { label: "Left running label" }));
  await receive(page, { type: "chat_step", chat_id: CHAT_ID, step: { name: "left_tool", status: "in_progress" } });
  await receive(page, { type: "tool_progress", chat_id: CHAT_ID, tool_name: "left_tool", message: "Left progress" });
  await expect(status).toHaveText(EARLIER_TURN_WAIT);
  expect(await sentLoads(page)).toHaveLength(0);

  await receive(page, operationStatus(turnScope, OPERATION_A, 3, "failed"));
  await expect(page.locator("body")).not.toContainText("Visible terminal failure");
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(CHAT_ID);
});

async function sentCancels(page) {
  return page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.type === "ui_event" && event.frame.action === "cancel_task")
    .map((event) => event.frame));
}

test("Stop shows only while this chat's turn runs and keeps the typed draft", async ({ page }) => {
  await installHarness(page);
  const { frame: registrationFrame } = await registration(page);
  await receive(page, snapshot(registrationFrame));
  const stop = page.locator("#astral-stop-btn");
  const sendButton = page.locator("#astral-send-btn");
  await expect(stop).toBeHidden();
  await expect(sendButton).toBeVisible();

  await page.locator("#astral-input").fill("A long request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await expect(stop).toBeVisible();
  await expect(sendButton).toBeVisible();
  await page.locator("#astral-input").fill("Draft still being written");

  await stop.click();
  const cancels = await sentCancels(page);
  expect(cancels).toHaveLength(1);
  expect(cancels[0]).toEqual(expect.objectContaining({ session_id: CHAT_ID }));
  expect(cancels[0].payload).toEqual({
    submission_id: cancels[0].submission_id,
    request_generation: cancels[0].request_generation,
  });
  expect(cancels[0].submission_id).toMatch(/^[0-9a-f-]{36}$/u);
  await expect(page.locator("#astral-input")).toHaveValue("Draft still being written");
});

test("Stop hides when the turn ends and while disconnected", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  const stop = page.locator("#astral-stop-btn");
  await expect(stop).toBeVisible();
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  await expect(stop).toBeHidden();

  await page.locator("#astral-input").fill("Second request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await expect(stop).toBeVisible();
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(stop).toBeHidden();
  await stop.evaluate((button) => button.click());
  expect(await sentCancels(page)).toHaveLength(0);
});

test("Escape in the composer stops the turn unless the slash menu is open", async ({ page }) => {
  await startTurnInChat(page);
  const composer = page.locator("#astral-input");
  await page.evaluate(() => document.querySelector("#astral-slash-menu").classList.remove("hidden"));
  await composer.press("Escape");
  expect(await sentCancels(page)).toHaveLength(0);

  await page.evaluate(() => document.querySelector("#astral-slash-menu").classList.add("hidden"));
  await composer.fill("Keep this text");
  await composer.press("Escape");
  expect(await sentCancels(page)).toHaveLength(1);
  await expect(composer).toHaveValue("Keep this text");
});

test("Escape with no turn running sends nothing", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-input").press("Escape");
  expect(await sentCancels(page)).toHaveLength(0);
});

test("Stop stays available while a chat waits to open but not in a new chat beside a left turn", async ({ page }) => {
  await startTurnInChat(page);
  const stop = page.locator("#astral-stop-btn");
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await expect(stop).toBeVisible();
  await stop.click();
  const cancels = await sentCancels(page);
  expect(cancels).toHaveLength(1);
  expect(cancels[0].session_id).toBe(OTHER_CHAT_ID);

  await page.locator("#astral-newchat-btn").click();
  await expect(stop).toBeHidden();
});

test("Stop sends one cancel per turn and returns for the next turn", async ({ page }) => {
  const { registrationFrame, turnScope } = await startTurnInChat(page);
  const stop = page.locator("#astral-stop-btn");
  await stop.click();
  await expect(stop).toBeHidden();
  await receive(page, { type: "chat_status", status: "done", message: "Cancelled" });
  await page.locator("#astral-input").press("Escape");
  await page.locator("#astral-input").evaluate((composer) => composer.dispatchEvent(
    new KeyboardEvent("keydown", { key: "Escape", repeat: true, bubbles: true, cancelable: true })));
  expect(await sentCancels(page)).toHaveLength(1);
  await expect(stop).toBeHidden();

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  await page.locator("#astral-input").fill("Next request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const next = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  await receive(page, operationStatus({
    connection_generation: registrationFrame.connection_generation,
    request_generation: next.request_generation,
  }, OPERATION_B, 0, "running"));
  await expect(stop).toBeVisible();
  await page.locator("#astral-input").press("Escape");
  expect(await sentCancels(page)).toHaveLength(2);
});

test("Escape closes an open modal without cancelling the turn", async ({ page }) => {
  await startTurnInChat(page);
  await receive(page, { type: "chrome_render", region: "modal", html: "<div>Settings</div>" });
  await page.locator("#astral-input").focus();
  await page.locator("#astral-input").press("Escape");
  expect(await sentCancels(page)).toHaveLength(0);
  await expect(page.locator("#astral-stop-btn")).toBeVisible();
});

test("Stop stays hidden in a new chat whose first message queues behind a left turn", async ({ page }) => {
  await startTurnInChat(page);
  await page.locator("#astral-newchat-btn").click();
  await page.locator("#astral-input").fill("First message in the new chat");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await expect(page.locator("#astral-stop-btn")).toBeHidden();
  await page.locator("#astral-input").press("Escape");
  expect(await sentCancels(page)).toHaveLength(0);
});

test("Stop covers a turn resumed by an approval", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const stop = page.locator("#astral-stop-btn");
  await expect(stop).toBeHidden();
  await receive(page, operationStatus({
    connection_generation: turnScope.connection_generation,
    request_generation: "99999999-9999-4999-8999-999999999999",
  }, OPERATION_C, 0, "running", { action: "authorize_action", surface: "chat" }));
  await expect(stop).toBeVisible();
  await stop.click();
  expect(await sentCancels(page)).toHaveLength(1);
});

test("focus returns to the composer when a focused Stop hides", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await page.locator("#astral-stop-btn").focus();
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  await expect(page.locator("#astral-input")).toBeFocused();
});

test("opening another chat during an approval-resumed turn holds the load", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const approvalScope = {
    connection_generation: turnScope.connection_generation,
    request_generation: "99999999-9999-4999-8999-999999999999",
  };
  await receive(page, operationStatus(approvalScope, OPERATION_C, 0, "running", { action: "authorize_action", surface: "chat" }));
  await openChatFromHistory(page, OTHER_CHAT_ID);
  expect(await sentLoads(page)).toHaveLength(0);
  await expect(page.locator("#astral-status")).toHaveText(EARLIER_TURN_WAIT);
  await receive(page, operationStatus(approvalScope, OPERATION_C, 1, "completed", { action: "authorize_action", surface: "chat" }));
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(OTHER_CHAT_ID);
});

test("a background task ending during a live turn in the open chat does not reload it", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_C, chat_id: CHAT_ID, status: "completed", summary: "Report ready",
  } });
  await expect(page.locator("#astral-toasts")).toContainText("Report ready");
  expect(await sentLoads(page)).toHaveLength(0);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentLoads(page)).toHaveLength(1);
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_D, chat_id: CHAT_ID, status: "completed", summary: "Second report",
  } });
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(2);
  expect(loads.map((load) => load.payload.chat_id)).toEqual([CHAT_ID, CHAT_ID]);
});

test("a background task ending while its chat waits to open loads it once when the turn ends", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_C, chat_id: OTHER_CHAT_ID, status: "completed", summary: "Done",
  } });
  expect(await sentLoads(page)).toHaveLength(0);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const loads = await sentLoads(page);
  expect(loads).toHaveLength(1);
  expect(loads[0].payload.chat_id).toBe(OTHER_CHAT_ID);
});

for (const ending of ["commit_then_task", "failed", "cancelled"]) {
  test(`a reload skipped during a live turn runs when the turn ends (${ending})`, async ({ page }) => {
    const { turnScope } = await startTurnInChat(page);
    if (ending === "commit_then_task") {
      await receive(page, snapshot(turnScope, { snapshot_purpose: "commit", render_revision: 1, snapshot_id: SNAPSHOT_B }));
    }
    await receive(page, { type: "task_completed", payload: {
      task_id: OPERATION_C, chat_id: CHAT_ID, status: "completed", summary: "Report ready",
    } });
    expect(await sentLoads(page)).toHaveLength(0);
    const terminal = ending === "cancelled"
      ? operationStatus(turnScope, OPERATION_A, 2, "cancelled", { error: { code: "cancelled_by_user", message: "Cancelled" } })
      : operationStatus(turnScope, OPERATION_A, 2, ending === "failed" ? "failed" : "completed");
    await receive(page, terminal);
    const loads = await sentLoads(page);
    expect(loads).toHaveLength(1);
    expect(loads[0].payload.chat_id).toBe(CHAT_ID);
  });
}

test("a reload skipped for an unaccepted message runs when the message is refused", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-input").fill("A request");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_C, chat_id: CHAT_ID, status: "completed", summary: "Report ready",
  } });
  expect(await sentLoads(page)).toHaveLength(0);
  await receive(page, { type: "error", accepted: false, code: "capacity_exceeded", message: "Busy right now",
    retry_after_ms: null, retryable: false, submission_id: message.submission_id });
  expect(await sentLoads(page)).toHaveLength(1);
});

test("a retryable background task that did not finish shows as an error", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await receive(page, { type: "task_completed", payload: { task_id: OPERATION_E, chat_id: OTHER_CHAT_ID, status: "retryable" } });
  await expect(page.locator("#astral-toasts .astral-toast").last()).toHaveClass(/astral-toast-error/u);
});

for (const [status, summary, expected] of [
  ["failed", "   ", "The background task did not finish."],
  ["retryable", "", "The background task did not finish."],
  ["completed", " \n ", "Background task completed"],
  ["failed", "  Quota exceeded  ", "Quota exceeded"],
]) {
  test(`a background task summary of ${JSON.stringify(summary)} with status ${status} is never blank`, async ({ page }) => {
    await installHarness(page);
    await receive(page, snapshot((await registration(page)).frame));
    await receive(page, { type: "task_completed", payload: {
      task_id: OPERATION_E, chat_id: OTHER_CHAT_ID, status, summary,
    } });
    await expect(page.locator("#astral-toasts .astral-toast").last()).toContainText(expected);
  });
}

async function failReconnects(page) {
  await page.evaluate(() => {
    const Recorded = window.WebSocket;
    window.__socketTimes = [];
    window.WebSocket = class extends Recorded {
      constructor(url) {
        super(url);
        window.__socketTimes.push(Date.now());
      }
    };
    window.__serverDown = true;
    window.__closedAt = Date.now();
    window.__sockets.at(-1).close();
  });
}

async function reconnectGaps(page) {
  return page.evaluate(() => window.__socketTimes.map((time, index) => (
    time - (index === 0 ? window.__closedAt : window.__socketTimes[index - 1]))));
}

test("reconnect keeps retrying through a long outage with capped backoff and recovers", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await failReconnects(page);
  await page.clock.runFor(30 * 60000);

  const gaps = await reconnectGaps(page);
  expect(gaps.length).toBeGreaterThan(25);
  for (const gap of gaps) {
    expect(gap).toBeGreaterThanOrEqual(1000);
    expect(gap).toBeLessThanOrEqual(60000);
  }
  for (const gap of gaps.slice(-10)) expect(gap).toBeGreaterThanOrEqual(30000);
  await expect(page.locator("#astral-status")).toHaveText("Disconnected");

  await page.evaluate(() => { window.__serverDown = false; });
  await page.clock.runFor(60000);
  await expect.poll(() => page.evaluate(() => window.__sockets.at(-1).sent
    .some((frame) => frame.type === "register_ui"))).toBe(true);
  const registration = await page.evaluate(() => window.__sockets.at(-1).sent.find((frame) => frame.type === "register_ui"));
  expect(registration.resume.active_chat_id).toBe(CHAT_ID);
});

test("reconnect starts within two seconds and restarts the backoff after a success", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await failReconnects(page);
  await page.clock.runFor(10 * 60000);
  const first = (await reconnectGaps(page))[0];
  expect(first).toBeGreaterThanOrEqual(1000);
  expect(first).toBeLessThanOrEqual(2000);

  await page.evaluate(() => { window.__serverDown = false; });
  await page.clock.runFor(60000);
  await expect.poll(() => page.evaluate(() => window.__sockets.at(-1).readyState)).toBe(1);
  await page.evaluate(() => {
    window.__serverDown = true;
    window.__closedAt = Date.now();
    window.__socketTimes = [];
    window.__sockets.at(-1).close();
  });
  await page.clock.runFor(2000);
  const restarted = await page.evaluate(() => window.__socketTimes.map((time) => time - window.__closedAt));
  expect(restarted.length).toBeGreaterThanOrEqual(1);
  expect(restarted[0]).toBeLessThanOrEqual(2000);
});

test("a server that accepts and then drops the socket still gets backed-off retries", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await page.evaluate(() => { window.__dropAfterRegister = true; });
  await failReconnects(page);
  await page.evaluate(() => { window.__serverDown = false; });
  await page.clock.runFor(10 * 60000);
  const gaps = await reconnectGaps(page);
  expect(gaps.length).toBeLessThan(30);
  for (const gap of gaps.slice(-5)) expect(gap).toBeGreaterThanOrEqual(30000);
});

test("a refresh racing an auth recovery leaves exactly one open socket", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await page.evaluate(() => {
    window.__pending = [];
    window.fetch = () => new Promise((resolve) => window.__pending.push(() => resolve({
      json: async () => ({ authenticated: true, access_token: window.__sessionToken, resumed: true, user_id: "continuity-user" }),
    })));
    window.__sockets.at(-1).receive({ type: "auth_required" });
    window.__sockets.at(-1).close();
  });
  await page.clock.runFor(2500);
  const pending = await page.evaluate(() => window.__pending.length);
  for (let index = 0; index < pending; index += 1) {
    await page.evaluate(() => window.__pending.shift()());
    await page.clock.runFor(100);
  }
  expect(await page.evaluate(() => window.__sockets.filter((socket) => socket.readyState === 1).length)).toBe(1);
});

test("a signed-out answer during an outage goes to sign-in instead of retrying", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await failReconnects(page);
  await page.evaluate(() => {
    window.fetch = async () => ({ json: async () => ({ authenticated: false }) });
  });
  await page.clock.runFor(5000);
  await page.waitForURL(/\/auth\/login/u);
});

test("coming back online retries at once instead of waiting out the backoff", async ({ page }) => {
  await page.clock.install();
  await installHarness(page);
  await failReconnects(page);
  await page.clock.runFor(10 * 60000);
  await page.evaluate(() => { window.__serverDown = false; });
  const before = await page.evaluate(() => window.__sockets.length);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await page.clock.runFor(100);
  await expect.poll(() => page.evaluate(() => window.__sockets.length)).toBe(before + 1);
  await expect.poll(() => page.evaluate(() => window.__sockets.at(-1).sent
    .some((frame) => frame.type === "register_ui"))).toBe(true);
});

async function sendInOpenChat(page, text) {
  const { frame: registrationFrame } = await registration(page);
  await page.locator("#astral-input").fill(text);
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  return { connection_generation: registrationFrame.connection_generation, request_generation: message.request_generation };
}

const DROP_NOTICE = "The connection dropped before your message was saved. It is back in the composer.";

test("a dropped connection puts an unsaved message and its files back ahead of the new draft", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await stageExistingFile(page, "file-1", "notes.txt");
  await sendInOpenChat(page, "Summarize my notes");
  await expect(page.locator("#astral-attachments")).not.toContainText("notes.txt");
  await page.locator("#astral-input").fill("Also add dates");
  await page.evaluate(() => window.__sockets.at(-1).close());

  await expect(page.locator("#astral-input")).toHaveValue("Summarize my notes\n\nAlso add dates");
  await expect(page.locator("#astral-attachments")).toContainText("notes.txt");
  await expect(page.locator("#astral-toasts")).toContainText(DROP_NOTICE);
});

test("a message whose commit arrived is not restored after a drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  const scope = await sendInOpenChat(page, "Saved request");
  await receive(page, snapshot(scope, { snapshot_purpose: "commit", render_revision: 1, snapshot_id: SNAPSHOT_B }));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

test("a message whose turn already ended is not restored after a drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  const scope = await sendInOpenChat(page, "Finished request");
  await receive(page, operationStatus(scope, OPERATION_A, 0, "completed"));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("");
});

test("an unsaved message is not restored into another chat", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await sendInOpenChat(page, "Request for chat one");
  await page.locator("#astral-newchat-btn").click();
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

test("a first message in a new chat is restored into that chat after a drop", async ({ page }) => {
  await installHarness(page, { locator: false });
  await sendInOpenChat(page, "First question");
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID } });
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("First question");
});

test("an owner change never restores the previous owner's unsaved message", async ({ page }) => {
  await installHarness(page, { locator: false });
  await sendInOpenChat(page, "Owner A private request");
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2
    && window.__sockets[1].sent.some((frame) => frame.type === "register_ui"));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).not.toHaveValue(/Owner A private request/u);
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

async function clickUiAction(page, payload, { example = false } = {}) {
  await page.evaluate(({ value, insideExample }) => {
    const host = document.createElement("div");
    if (insideExample) host.className = "astral-agent-example";
    const button = document.createElement("button");
    button.dataset.uiAction = "chat_message";
    button.dataset.uiPayload = JSON.stringify(value);
    host.append(button);
    document.body.append(host);
    button.click();
    host.remove();
  }, { value: payload, insideExample: example });
}

test("a background send is never restored after a drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-bg-btn").click();
  await sendInOpenChat(page, "Background job");
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

test("an example prompt comes back once after a drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await clickUiAction(page, { message: "Example prompt" }, { example: true });
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("Example prompt");
});

test("a message from a server button is restored after a drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await clickUiAction(page, { message: "From a button" });
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("From a button");
});

test("a first message abandoned with New chat is not restored", async ({ page }) => {
  await installHarness(page, { locator: false });
  await sendInOpenChat(page, "Abandoned question");
  await page.locator("#astral-newchat-btn").click();
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

test("a refused message is not restored by a later drop", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await sendInOpenChat(page, "Refused request");
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  await receive(page, { type: "error", accepted: false, code: "capacity_exceeded", message: "Busy right now",
    retry_after_ms: null, retryable: false, submission_id: message.submission_id });
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("body")).not.toContainText(DROP_NOTICE);
});

test("restored files go ahead of files staged since", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await stageExistingFile(page, "file-1", "first.txt");
  await sendInOpenChat(page, "With a file");
  await stageExistingFile(page, "file-2", "second.txt");
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-attachments")).toContainText(/first\.txt[\s\S]*second\.txt/u);
});

async function submitComposer(page, text) {
  await page.locator("#astral-input").fill(text);
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
}

async function sentActions(page, name) {
  return page.evaluate((actionName) => window.__socketEvents
    .filter((event) => event.frame.type === "ui_event" && event.frame.action === actionName)
    .map((event) => event.frame), name);
}

function nextTurnScope(turnScope, message) {
  return { connection_generation: turnScope.connection_generation, request_generation: message.request_generation };
}

const QUEUED_ROWS = "#astral-queue .astral-queued";

test("registration asks for steering and the legacy composer stays without the acknowledgment", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  const { frame } = await registration(page);
  expect(frame.capabilities).toContain("turn_steer_v1");
  expect(frame.device.turn_steer_v1).toBe(true);

  await submitComposer(page, "Sent the old way");
  expect((await sentActions(page, "chat_message")).map((sent) => sent.payload.message))
    .toEqual(["A long request", "Sent the old way"]);
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator("#astral-side-question-btn")).toHaveCount(0);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentActions(page, "chat_steer")).toHaveLength(0);
});

test("while an answer runs, Enter queues and the finished answer sends one message at a time", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await expect(page.locator("#astral-input")).toHaveAttribute("placeholder", /Queue a follow-up/u);
  await submitComposer(page, "First follow-up");
  await submitComposer(page, "Second follow-up");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(2);
  await expect(page.locator(QUEUED_ROWS).first()).toContainText("First follow-up");
  await expect(page.locator("#astral-input")).toHaveValue("");
  expect(await sentActions(page, "chat_message")).toHaveLength(1);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  let messages = await sentActions(page, "chat_message");
  expect(messages.map((sent) => sent.payload.message)).toEqual(["A long request", "First follow-up"]);
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);

  const secondScope = nextTurnScope(turnScope, messages.at(-1));
  await receive(page, operationStatus(secondScope, OPERATION_B, 0, "running"));
  await receive(page, operationStatus(secondScope, OPERATION_B, 1, "completed"));
  messages = await sentActions(page, "chat_message");
  expect(messages.map((sent) => sent.payload.message).at(-1)).toBe("Second follow-up");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);

  await receive(page, operationStatus(nextTurnScope(turnScope, messages.at(-1)), OPERATION_C, 0, "completed"));
  await expect(page.locator("#astral-input")).not.toHaveAttribute("placeholder", /Queue a follow-up/u);
  await submitComposer(page, "Sent right away");
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("Sent right away");
});

for (const state of ["failed", "retryable", "cancelled"]) {
  test(`a ${state} answer puts the queue back in the composer ahead of the draft`, async ({ page }) => {
    const { turnScope } = await startTurnInChat(page, { steer: true });
    await submitComposer(page, "Queued one");
    await submitComposer(page, "Queued two");
    await page.locator("#astral-input").fill("Draft in progress");
    await receive(page, operationStatus(turnScope, OPERATION_A, 2, state));
    await expect(page.locator("#astral-input")).toHaveValue("Queued one\n\nQueued two\n\nDraft in progress");
    await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
    await expect(page.locator("body")).toContainText("queued messages are back in the composer");
    expect(await sentActions(page, "chat_message")).toHaveLength(1);
  });
}

test("Stop sends one cancel and puts the queue back in the composer right away", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Queued before Stop");
  await page.locator("#astral-input").fill("Still typing");
  await page.locator("#astral-stop-btn").click();
  expect(await sentActions(page, "cancel_task")).toHaveLength(1);
  await expect(page.locator("#astral-input")).toHaveValue("Queued before Stop\n\nStill typing");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
});

test("Interrupt steers with the queued text and a refusal returns it to the composer", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Use metric units");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  const [steer] = await sentActions(page, "chat_steer");
  expect(steer.session_id).toBe(CHAT_ID);
  expect(Object.keys(steer.payload).sort()).toEqual(["client_message_id", "message", "request_generation", "submission_id"]);
  expect(steer.payload).toEqual(expect.objectContaining({
    message: "Use metric units", submission_id: steer.submission_id, request_generation: steer.request_generation,
  }));
  expect(steer.payload.client_message_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u);
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator(".astral-bubble-steer.is-pending")).toContainText("Use metric units");
  await expect(page.locator(".astral-bubble-steer .astral-turn-pill")).toHaveText(
    await page.locator(".astral-turn-user:not(.astral-bubble-steer) .astral-turn-pill").last().textContent());

  await receive(page, { type: "chat_steer_refused", chat_id: CHAT_ID, client_message_id: steer.payload.client_message_id,
    code: "approval_pending", message: "Answer the approval first; a steer cannot answer it." });
  await expect(page.locator(".astral-bubble-steer")).toHaveCount(0);
  await expect(page.locator("#astral-input")).toHaveValue("Use metric units");
  await expect(page.locator("body")).toContainText("Decide the approval first; an interruption cannot answer it.");
});

test("an interruption the answer outran is sent next, ahead of later queued messages", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "First: use metric");
  await submitComposer(page, "Second: then summarize");
  await page.locator(QUEUED_ROWS).first().getByRole("button", { name: "Interrupt" }).click();
  const [steer] = await sentActions(page, "chat_steer");
  await receive(page, { type: "chat_steer_refused", chat_id: CHAT_ID, client_message_id: steer.payload.client_message_id,
    code: "stale_turn", message: "The turn ended before this steer could be applied." });
  await expect(page.locator(QUEUED_ROWS).first()).toContainText("First: use metric");
  await expect(page.locator("body")).toContainText("so it will be sent next");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("First: use metric");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await expect(page.locator("#astral-input")).toHaveValue("");
});

test("a recorded interruption stays in the feed and unknown receipts change nothing", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Only the last week");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  const [steer] = await sentActions(page, "chat_steer");
  await receive(page, { type: "chat_steer_refused", chat_id: CHAT_ID,
    client_message_id: "99999999-9999-4999-8999-999999999999", code: "stale_turn", message: "Not ours." });
  await receive(page, { type: "chat_steer_refused", chat_id: CHAT_ID, client_message_id: steer.payload.client_message_id,
    code: "made_up", message: "Unknown code." });
  await expect(page.locator(".astral-bubble-steer.is-pending")).toHaveCount(1);
  await receive(page, { type: "chat_steer_recorded", chat_id: CHAT_ID,
    client_message_id: steer.payload.client_message_id, skipped_calls: [] });
  await expect(page.locator(".astral-bubble-steer")).toContainText("Only the last week");
  await expect(page.locator(".astral-bubble-steer.is-pending")).toHaveCount(0);
  await receive(page, { type: "chat_steer_refused", chat_id: CHAT_ID, client_message_id: steer.payload.client_message_id,
    code: "stale_turn", message: "Too late." });
  await expect(page.locator("#astral-input")).toHaveValue("");
});

test("a queued message with files cannot interrupt and is sent with its files", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await stageExistingFile(page, "queued-file", "notes.txt");
  await submitComposer(page, "Read this file");
  const row = page.locator(QUEUED_ROWS);
  await expect(row).toContainText("(1 file)");
  await expect(row.getByRole("button", { name: "Interrupt" })).toBeDisabled();
  await expect(page.locator("#astral-attachments")).not.toContainText("notes.txt");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const sent = (await sentActions(page, "chat_message")).at(-1);
  expect(sent.payload.message).toBe("Read this file");
  expect(sent.payload.attachments).toEqual([expect.objectContaining({ attachment_id: "queued-file", filename: "notes.txt" })]);
});

test("queued messages can be edited, cancelled and deleted", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Frist draft");
  await submitComposer(page, "Delete me");
  const first = page.locator(QUEUED_ROWS).first();
  await first.getByRole("button", { name: "Edit" }).click();
  const field = first.getByRole("textbox", { name: "Edit queued message" });
  await expect(field).toBeFocused();
  await field.fill("Throwaway change");
  await field.press("Escape");
  await expect(first).toContainText("Frist draft");
  expect(await sentActions(page, "cancel_task")).toHaveLength(0);

  await first.getByRole("button", { name: "Edit" }).click();
  await first.getByRole("textbox", { name: "Edit queued message" }).fill("First draft");
  await first.getByRole("textbox", { name: "Edit queued message" }).press("Enter");
  await expect(first).toContainText("First draft");
  await page.locator(QUEUED_ROWS).nth(1).getByRole("button", { name: "Delete" }).click();
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);

  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("First draft");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
});

test("saving an empty edit deletes the queued message", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Gone soon");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Edit" }).click();
  await page.locator(QUEUED_ROWS).getByRole("textbox").fill("   ");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Save" }).click();
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
});

test("a message being edited when the answer finishes waits and is sent as saved", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Before edit");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Edit" }).click();
  await page.locator(QUEUED_ROWS).getByRole("textbox").fill("After edit");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentActions(page, "chat_message")).toHaveLength(1);
  await expect(page.locator(QUEUED_ROWS).getByRole("textbox")).toHaveValue("After edit");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Save" }).click();
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("After edit");
});

test("a dropped connection returns queued and unconfirmed interruptions to the composer", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Steer text");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  await submitComposer(page, "Queued text");
  await page.evaluate(() => window.__sockets.at(-1).close());
  // The turn's own message was never saved, so it comes back first
  await expect(page.locator("#astral-input")).toHaveValue("A long request\n\nSteer text\n\nQueued text");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator(".astral-bubble-steer")).toHaveCount(0);
  await expect(page.locator("body")).toContainText("The connection dropped, so your queued messages are back in the composer.");
});

test("an owner change erases the queue and pending interruptions", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Private steer");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  await submitComposer(page, "Private queued");
  await page.evaluate(({ otherToken }) => {
    window.__sessionToken = otherToken;
    window.__sessionSubject = "other-user";
  }, { otherToken: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2
    && window.__sockets[1].sent.some((frame) => frame.type === "register_ui"));
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText("Private steer");
  await expect(page.locator("body")).not.toContainText("Private queued");
});

test("a queue stays with its chat and returns to the composer when reopened after the answer", async ({ page }) => {
  const { registrationFrame, turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "For the first chat");
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await submitComposer(page, "Typed while the other chat waits");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  const waiting = (await sentActions(page, "chat_message")).at(-1);
  expect(waiting.payload.message).toBe("Typed while the other chat waits");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect((await sentActions(page, "chat_message")).map((sent) => sent.payload.message)).not.toContain("For the first chat");
  const waitingScope = nextTurnScope(turnScope, waiting);
  await receive(page, operationStatus(waitingScope, OPERATION_B, 0, "running", { chat_id: OTHER_CHAT_ID }));
  await receive(page, operationStatus(waitingScope, OPERATION_B, 1, "completed", { chat_id: OTHER_CHAT_ID }));
  await expect(page.locator("#astral-input")).toHaveValue("");

  await openChatFromHistory(page, CHAT_ID);
  await expect(page.locator("#astral-input")).toHaveValue("For the first chat");
  await expect(page.locator("body")).toContainText("finished while you were in another chat");
  expect(registrationFrame.capabilities).toContain("turn_steer_v1");
});

test("New chat clears a queue that belongs to an unsaved chat", async ({ page }) => {
  await installHarness(page, { locator: false, steer: true });
  const { frame: registrationFrame } = await registration(page);
  await submitComposer(page, "First question");
  const message = (await sentActions(page, "chat_message"))[0];
  const turnScope = { connection_generation: registrationFrame.connection_generation, request_generation: message.request_generation };
  await receive(page, operationStatus(turnScope, OPERATION_A, 0, "running", { chat_id: null }));
  await submitComposer(page, "Queued in the unsaved chat");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator("body")).toContainText("Queued messages cleared for the new chat.");
  await expect(page.locator("#astral-input")).toHaveValue("");
});

test("a new chat's queue follows it when the server names the chat", async ({ page }) => {
  await installHarness(page, { locator: false, steer: true });
  const { frame: registrationFrame } = await registration(page);
  await submitComposer(page, "First question");
  const message = (await sentActions(page, "chat_message"))[0];
  const turnScope = { connection_generation: registrationFrame.connection_generation, request_generation: message.request_generation };
  await receive(page, operationStatus(turnScope, OPERATION_A, 0, "running", { chat_id: null }));
  await submitComposer(page, "Follows the new chat");
  await receive(page, { type: "chat_created", payload: { chat_id: CHAT_ID } });
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await receive(page, operationStatus(turnScope, OPERATION_A, 1, "completed"));
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("Follows the new chat");
});

test("the queue holds sixteen messages and keeps the seventeenth in the composer", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  for (let index = 1; index <= 16; index += 1) await submitComposer(page, `Queued ${index}`);
  await submitComposer(page, "One too many");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(16);
  await expect(page.locator("#astral-input")).toHaveValue("One too many");
  await expect(page.locator("body")).toContainText("Up to 16 messages can wait at once.");
});

test("a side question is asked in its own dialog and its answer is shown as text", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await page.locator("#astral-side-question-btn").click();
  const dialog = page.getByRole("dialog", { name: "Side question" });
  await expect(dialog).toBeVisible();
  const question = dialog.getByRole("textbox", { name: "Side question" });
  await expect(question).toBeFocused();
  await question.fill("What does eGFR mean?");
  await question.press("Enter");
  const [asked] = await sentActions(page, "side_question");
  expect(Object.keys(asked.payload).sort()).toEqual(["client_message_id", "question", "request_generation", "submission_id"]);
  expect(asked.payload.question).toBe("What does eGFR mean?");
  await expect(dialog.getByRole("button", { name: "Ask" })).toBeDisabled();

  await receive(page, { type: "side_question_result", client_message_id: "99999999-9999-4999-8999-999999999999", answer: "Not ours" });
  await expect(dialog).not.toContainText("Not ours");
  await receive(page, { type: "side_question_result", client_message_id: asked.payload.client_message_id,
    answer: "<img src=x onerror=window.__pwned=1>Estimated glomerular filtration rate." });
  await expect(dialog.locator(".astral-side-question-answer")).toHaveText(
    "<img src=x onerror=window.__pwned=1>Estimated glomerular filtration rate.");
  expect(await page.evaluate(() => window.__pwned)).toBeUndefined();
  await expect(page.locator("#astral-chat")).not.toContainText("glomerular");

  await question.press("Escape");
  await expect(dialog).toHaveCount(0);
  expect(await sentActions(page, "cancel_task")).toHaveLength(0);
  await expect(page.locator("#astral-stop-btn")).toBeVisible();
});

test("the side question control appears only with the acknowledgment", async ({ page }) => {
  await installHarness(page);
  await expect(page.locator("#astral-side-question-btn")).toHaveCount(0);
});

test("returning to a chat while its answer still runs does not strand the queue", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Queued in the first chat");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await openChatFromHistory(page, CHAT_ID);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const sent = (await sentActions(page, "chat_message")).map((frame) => frame.payload.message);
  const composer = await page.locator("#astral-input").inputValue();
  // The answer is over: the queued text must have been sent or handed back, not left as a chip
  expect(sent.includes("Queued in the first chat") || composer.includes("Queued in the first chat")).toBe(true);
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
});

test("a queue typed during an approval-resumed turn is settled when that turn completes", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const approvalScope = {
    connection_generation: turnScope.connection_generation,
    request_generation: "99999999-9999-4999-8999-999999999999",
  };
  await receive(page, operationStatus(approvalScope, OPERATION_C, 0, "running", { action: "authorize_action", surface: "chat" }));
  await submitComposer(page, "After the approval");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await receive(page, operationStatus(approvalScope, OPERATION_C, 1, "completed", { action: "authorize_action", surface: "chat" }));
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("After the approval");
});

test("saving an unchanged edit of a files-only queued message keeps the message and its file", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await stageExistingFile(page, "queued-file", "notes.txt");
  await submitComposer(page, "");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Edit" }).click();
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Save" }).click();
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const sent = (await sentActions(page, "chat_message")).at(-1);
  expect(sent.payload.attachments).toEqual([expect.objectContaining({ attachment_id: "queued-file" })]);
});

test("Stop names the queued files that do not fit back in the composer", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  for (let index = 1; index <= 6; index += 1) await stageExistingFile(page, `first-${index}`, `first-${index}.txt`);
  await submitComposer(page, "First with files");
  for (let index = 1; index <= 6; index += 1) await stageExistingFile(page, `second-${index}`, `second-${index}.txt`);
  await submitComposer(page, "Second with files");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(2);
  await page.locator("#astral-stop-btn").click();
  await expect(page.locator("#astral-input")).toHaveValue("First with files\n\nSecond with files");
  await expect(page.locator("#astral-attachments .astral-chip")).toHaveCount(10);
  await expect(page.locator("body")).toContainText("Only 10 files fit in the composer. Attach these again: second-5.txt, second-6.txt");
});

test("a message typed while a queued edit holds the queue waits behind it", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Queued A");
  await submitComposer(page, "Queued B");
  await page.locator(QUEUED_ROWS).first().getByRole("button", { name: "Edit" }).click();
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  expect(await sentActions(page, "chat_message")).toHaveLength(1);
  await submitComposer(page, "Typed C");
  expect((await sentActions(page, "chat_message")).map((frame) => frame.payload.message)).not.toContain("Typed C");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(3);
  await page.locator(QUEUED_ROWS).first().getByRole("button", { name: "Save" }).click();
  expect((await sentActions(page, "chat_message")).at(-1).payload.message).toBe("Queued A");
});

test("an unsaved chat's refused interruption does not land in the next new chat's composer", async ({ page }) => {
  await installHarness(page, { locator: false, steer: true });
  const { frame: registrationFrame } = await registration(page);
  await submitComposer(page, "First question");
  const message = (await sentActions(page, "chat_message"))[0];
  const turnScope = { connection_generation: registrationFrame.connection_generation, request_generation: message.request_generation };
  await receive(page, operationStatus(turnScope, OPERATION_A, 0, "running", { chat_id: null }));
  await submitComposer(page, "Steer for the old chat");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  const [steer] = await sentActions(page, "chat_steer");
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator("#astral-input")).toHaveValue("");
  await receive(page, { type: "chat_steer_refused", client_message_id: steer.payload.client_message_id,
    code: "stale_turn", message: "The turn ended before this steer could be applied." });
  await expect(page.locator("#astral-input")).toHaveValue("");
});

test("a side question closed before its answer is picked back up when reopened", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await page.locator("#astral-side-question-btn").click();
  const dialog = page.getByRole("dialog", { name: "Side question" });
  await dialog.getByRole("textbox", { name: "Side question" }).fill("First question");
  await dialog.getByRole("button", { name: "Ask" }).click();
  const [asked] = await sentActions(page, "side_question");
  await dialog.getByRole("button", { name: "Close side question" }).click();
  await expect(page.locator("#astral-side-question-btn")).toBeFocused();
  await page.locator("#astral-side-question-btn").click();
  await expect(dialog.getByRole("textbox", { name: "Side question" })).toHaveValue("First question");
  await expect(dialog.getByRole("button", { name: "Ask" })).toBeDisabled();
  await receive(page, { type: "side_question_result", client_message_id: asked.payload.client_message_id, answer: "First answer" });
  await expect(dialog.locator(".astral-side-question-answer")).toHaveText("First answer");
  expect(await sentActions(page, "side_question")).toHaveLength(1);
});

test("the side question dialog keeps Tab inside and returns focus when its menu item is hidden", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await page.evaluate(() => document.querySelector("#astral-side-question-btn").addEventListener("click", () => {
    document.querySelector("#astral-composer-controls").style.display = "none";
  }));
  await page.locator("#astral-side-question-btn").click();
  const dialog = page.getByRole("dialog", { name: "Side question" });
  const question = dialog.getByRole("textbox", { name: "Side question" });
  await expect(question).toBeFocused();
  for (let index = 0; index < 4; index += 1) {
    await page.keyboard.press("Tab");
    expect(await page.evaluate(() => !!document.activeElement.closest(".astral-side-question"))).toBe(true);
  }
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(page.locator("#astral-input")).toBeFocused();
  expect(await sentActions(page, "cancel_task")).toHaveLength(0);
});

test("a tiny web window registers and resizes as mobile, never as a watch", async ({ page }) => {
  await page.setViewportSize({ width: 180, height: 700 });
  await installHarness(page);
  const { frame } = await registration(page);
  expect(frame.device.device_type).toBe("mobile");
  await page.setViewportSize({ width: 150, height: 700 });
  await page.waitForFunction(() => window.__socketEvents.some((event) => event.frame.action === "update_device"));
  const updates = await page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.action === "update_device").map((event) => event.frame.payload.device.device_type));
  expect(updates.length).toBeGreaterThan(0);
  expect(updates).not.toContain("watch");
  expect(updates.at(-1)).toBe("mobile");
});

test("a browser on a watch registers as mobile", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "userAgent", { get: () => "Mozilla/5.0 (Watch; watchOS 26) AppleWebKit/605" });
  });
  await page.setViewportSize({ width: 320, height: 700 });
  await installHarness(page);
  expect((await registration(page)).frame.device.device_type).toBe("mobile");
});

test("widths that flap across the breakpoints never report a watch", async ({ page }) => {
  await page.setViewportSize({ width: 150, height: 700 });
  await installHarness(page);
  expect((await registration(page)).frame.device.device_type).toBe("mobile");
  const updates = () => page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.action === "update_device").map((event) => event.frame.payload.device.device_type));
  for (const [width, kind] of [[1440, "browser"], [199, "mobile"], [700, "tablet"], [201, "mobile"], [1440, "browser"]]) {
    await page.setViewportSize({ width, height: 700 });
    await expect.poll(async () => (await updates()).at(-1)).toBe(kind);
  }
  expect(await updates()).not.toContain("watch");
});

test("a page hidden at load and shown before the server replies reports itself as a desktop browser", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(() => {
    const original = Object.getOwnPropertyDescriptor(window, "innerWidth");
    window.__hidden = true;
    Object.defineProperty(window, "innerWidth", { configurable: true,
      get() { return window.__hidden ? 0 : original.get.call(window); } });
    let Impl;
    Object.defineProperty(window, "WebSocket", { configurable: true, get() { return Impl; }, set(Base) {
      Impl = class extends Base {
        receive(frame) {
          if (frame.type === "rote_config" && !window.__roteReleased) { window.__releaseRote = () => { window.__roteReleased = true; super.receive(frame); }; return; }
          super.receive(frame);
        }
      };
    } });
  });
  await installHarness(page);
  expect((await registration(page)).frame.device.device_type).toBe("mobile");
  // The tab becomes visible at desktop width before the server's rote_config arrives
  await page.evaluate(() => { window.__hidden = false; window.dispatchEvent(new Event("resize")); });
  await page.waitForTimeout(400);
  await page.evaluate(() => window.__releaseRote());
  await page.waitForTimeout(600);
  const updates = await page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.action === "update_device").map((event) => event.frame.payload.device.device_type));
  expect(updates.at(-1)).toBe("browser");
});

test("reconnecting with an unchanged window sends no extra device report", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await installHarness(page);
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.action === "update_device").length)).toBe(0);
});

async function newChatThenType(page, text) {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-newchat-btn").click();
  await page.locator("#astral-input").fill(text);
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  return page.evaluate(() => window.__socketEvents.findLast((event) => event.frame.action === "new_chat").frame);
}

async function sentChatMessages(page) {
  return page.evaluate(() => window.__socketEvents
    .filter((event) => event.frame.action === "chat_message").map((event) => event.frame));
}

test("a message sent before the new chat exists waits and goes into that chat", async ({ page }) => {
  const newChat = await newChatThenType(page, "First question");
  expect(await sentChatMessages(page)).toHaveLength(0);
  await expect(page.locator("#astral-status")).toContainText("Starting the new chat");
  await page.locator("#astral-input").fill("And a second thought");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await receive(page, { type: "chat_created", submission_id: newChat.submission_id,
    payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  const messages = await sentChatMessages(page);
  expect(messages).toHaveLength(1);
  expect(messages[0].payload.message).toBe("First question\n\nAnd a second thought");
  expect(messages[0].payload.chat_id).toBe(OTHER_CHAT_ID);
  expect(messages[0].session_id).toBe(OTHER_CHAT_ID);
  await page.locator("#astral-input").fill("Sent right away");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  expect((await sentChatMessages(page)).at(-1).payload.message).toBe("Sent right away");
});

test("a refused new chat puts the waiting message back in the composer", async ({ page }) => {
  const newChat = await newChatThenType(page, "Held question");
  await receive(page, { type: "error", accepted: false, code: "capacity_exceeded", message: "Busy right now",
    retry_after_ms: null, retryable: false, submission_id: newChat.submission_id });
  await expect(page.locator("#astral-input")).toHaveValue("Held question");
  await expect(page.locator("body")).toContainText("The new chat did not start, so your message is back in the composer.");
  expect(await sentChatMessages(page)).toHaveLength(0);
});

test("a failed new chat puts the waiting message back in the composer", async ({ page }) => {
  const newChat = await newChatThenType(page, "Held question");
  const scope = { connection_generation: newChat.connection_generation, request_generation: newChat.request_generation };
  await receive(page, operationStatus(scope, OPERATION_A, 0, "failed", { action: "new_chat", chat_id: null }));
  await expect(page.locator("#astral-input")).toHaveValue("Held question");
  expect(await sentChatMessages(page)).toHaveLength(0);
});

test("a dropped connection puts a message waiting for the new chat back in the composer", async ({ page }) => {
  await newChatThenType(page, "Held question");
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("Held question");
  expect(await sentChatMessages(page)).toHaveLength(0);
});

test("an owner change drops a message waiting for the new chat", async ({ page }) => {
  const newChat = await newChatThenType(page, "Private held question");
  await page.evaluate(({ token }) => {
    window.__sessionToken = token;
    window.__sessionSubject = "other-user";
  }, { token: OTHER_TOKEN });
  await receive(page, { type: "auth_required" });
  await page.waitForFunction(() => window.__sockets.length === 2
    && window.__sockets[1].sent.some((frame) => frame.type === "register_ui"));
  await receive(page, { type: "chat_created", submission_id: newChat.submission_id,
    payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  expect(await sentChatMessages(page)).toHaveLength(0);
  await expect(page.locator("#astral-input")).toHaveValue("");
  await expect(page.locator("body")).not.toContainText("Private held question");
});

test("a message waiting for an unanswered new chat is sent after ten seconds", async ({ page }) => {
  await page.clock.install();
  await newChatThenType(page, "Eventually sent");
  expect(await sentChatMessages(page)).toHaveLength(0);
  await page.clock.runFor(9000);
  expect(await sentChatMessages(page)).toHaveLength(0);
  await page.clock.runFor(1500);
  const messages = await sentChatMessages(page);
  expect(messages.map((frame) => frame.payload.message)).toEqual(["Eventually sent"]);
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  expect(await sentChatMessages(page)).toHaveLength(1);
});

const activeLocator = (page) => page.evaluate((key) => JSON.parse(localStorage.getItem(key) || "null")?.chat_id ?? null, LOCATOR_KEY);

test("two New chat clicks send the waiting message into the chat the user ends up in", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-newchat-btn").click();
  await page.locator("#astral-newchat-btn").click();
  await page.locator("#astral-input").fill("Typed after a double click");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  // The real server answers a plain new_chat with an uncorrelated chat_created, one per new_chat
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  await receive(page, { type: "chat_created", payload: { chat_id: THIRD_CHAT_ID, from_message: false } });
  const messages = await sentChatMessages(page);
  expect(messages).toHaveLength(1);
  expect(messages[0].payload.chat_id).toBe(await activeLocator(page));
});

test("a chat_created for another request does not take the waiting message", async ({ page }) => {
  const newChat = await newChatThenType(page, "Held question");
  const foreign = "99999999-9999-4999-8999-999999999999";
  const generation = "12345678-1234-4234-8234-123456789abc";
  await receive(page, { type: "chat_created", schema_version: "1", connection_generation: newChat.connection_generation,
    submission_id: foreign, request_generation: generation,
    payload: { schema_version: "1", chat_id: THIRD_CHAT_ID, from_message: false,
      connection_generation: newChat.connection_generation, submission_id: foreign, request_generation: generation } });
  expect(await sentChatMessages(page)).toHaveLength(0);
});

test("an offline New chat holds a message typed before the new chat exists", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.clock.install({ time: new Date("2026-09-11T12:00:00Z") });
  await page.clock.pauseAt(new Date("2026-09-11T12:00:01Z"));
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.locator("#astral-newchat-btn").click();
  await page.locator("#astral-input").fill("Typed offline after New chat");
  await page.locator("#astral-input").press("Enter");
  await page.clock.runFor(5000);
  const frames = await page.evaluate(() => window.__socketEvents.filter((event) => event.frame.type === "ui_event").map((event) => event.frame.action));
  expect(frames).toContain("new_chat");
  // Before chat_created arrives, nothing should have been sent without a chat id
  const early = await sentChatMessages(page);
  expect(early.map((frame) => frame.payload.chat_id)).toEqual([]);
});

test("merged waiting messages keep to ten files and leave the rest in the composer", async ({ page }) => {
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame));
  await page.locator("#astral-newchat-btn").click();
  for (const batch of [0, 1]) {
    for (let i = 0; i < 6; i += 1) await stageExistingFile(page, `file-${batch}-${i}`, `f${batch}${i}.txt`);
    await page.locator("#astral-input").fill(`Batch ${batch}`);
    await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  }
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  const messages = await sentChatMessages(page);
  expect(messages).toHaveLength(1);
  expect(messages[0].payload.attachments).toHaveLength(10);
  await expect(page.locator("#astral-attachments .astral-chip")).toHaveCount(2);
});

test("a second New chat click keeps saying a message is waiting", async ({ page }) => {
  await newChatThenType(page, "Held question");
  await page.locator("#astral-newchat-btn").click();
  await expect(page.locator("#astral-status")).toContainText("Starting the new chat");
});

test("a new chat completed before chat_created still releases on chat_created", async ({ page }) => {
  const newChat = await newChatThenType(page, "Held question");
  const scope = { connection_generation: newChat.connection_generation, request_generation: newChat.request_generation };
  await receive(page, operationStatus(scope, OPERATION_A, 0, "accepted", { action: "new_chat", chat_id: null }));
  await receive(page, operationStatus(scope, OPERATION_A, 1, "completed", { action: "new_chat", chat_id: null }));
  expect(await sentChatMessages(page)).toHaveLength(0);
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  const messages = await sentChatMessages(page);
  expect(messages).toHaveLength(1);
  expect(messages[0].payload.chat_id).toBe(OTHER_CHAT_ID);
  await expect(page.locator("#astral-status")).not.toContainText("Starting the new chat");
});

test("a chat_created from a message does not release the waiting message", async ({ page }) => {
  await newChatThenType(page, "Held question");
  await receive(page, { type: "chat_created", payload: { chat_id: THIRD_CHAT_ID, from_message: true } });
  expect(await sentChatMessages(page)).toHaveLength(0);
  await receive(page, { type: "chat_created", payload: { chat_id: OTHER_CHAT_ID, from_message: false } });
  expect((await sentChatMessages(page)).map((frame) => frame.payload.chat_id)).toEqual([OTHER_CHAT_ID]);
});

test("a reloaded chat shows when each message was sent, while a new message shows now", async ({ page }) => {
  await page.clock.setFixedTime(new Date("2026-07-16T15:42:00Z"));
  await installHarness(page);
  await receive(page, snapshot((await registration(page)).frame, {
    transcript: [
      { message_id: "user-1", role: "user", created_at: "2026-07-16T09:05:00Z",
        parts: [{ type: "text", text: "Morning question" }], attachments: [] },
      { message_id: "assistant-1", role: "assistant", created_at: "2026-07-16T09:06:00Z",
        parts: [{ type: "text", text: "Morning answer" }], attachments: [] },
    ],
  }));
  const label = (iso) => page.evaluate((value) => {
    const stamp = new Date(value);
    return ("0" + stamp.getHours()).slice(-2) + ":" + ("0" + stamp.getMinutes()).slice(-2);
  }, iso);
  await expect(page.locator(".astral-turn-time").first()).toHaveText(await label("2026-07-16T09:05:00Z"));
  await page.locator("#astral-input").fill("Afternoon question");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await expect(page.locator(".astral-turn-time").last()).toHaveText(await label("2026-07-16T15:42:00Z"));
});

async function lastNewChatFrame(page) {
  return page.evaluate(() => window.__socketEvents.findLast((event) => event.frame.action === "new_chat").frame);
}

test("a New chat answered while another chat waits to open does not hold that chat's messages", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page);
  await page.locator("#astral-newchat-btn").click();
  const newChat = await lastNewChatFrame(page);
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await receive(page, { type: "chat_created", submission_id: newChat.submission_id,
    payload: { chat_id: THIRD_CHAT_ID, from_message: false } });
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const loads = await sentLoads(page);
  expect(loads.at(-1).payload.chat_id).toBe(OTHER_CHAT_ID);
  await receive(page, snapshot({ connection_generation: turnScope.connection_generation,
    request_generation: loads.at(-1).request_generation }, { chat_id: OTHER_CHAT_ID, snapshot_id: SNAPSHOT_B }));
  await submitComposer(page, "Question for the other chat");
  await expect(page.locator("#astral-status")).not.toContainText("Starting the new chat");
  const messages = await sentChatMessages(page);
  expect(messages.at(-1).payload.message).toBe("Question for the other chat");
  expect(messages.at(-1).payload.chat_id).toBe(OTHER_CHAT_ID);
});

test("a message typed for a New chat comes back instead of going into a chat opened afterwards", async ({ page }) => {
  await page.clock.install();
  const { turnScope } = await startTurnInChat(page);
  await page.locator("#astral-newchat-btn").click();
  await submitComposer(page, "Meant for the new chat");
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await expect(page.locator("#astral-input")).toHaveValue("Meant for the new chat");
  await expect(page.locator("#astral-toasts")).toContainText("You opened another chat");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  await page.clock.runFor(11000);
  const messages = await sentChatMessages(page);
  expect(messages.filter((frame) => frame.payload.message === "Meant for the new chat")).toHaveLength(0);
});

test("a queued message equal to the unsaved one both come back after a drop", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "A long request");
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(1);
  await page.evaluate(() => window.__sockets.at(-1).close());
  await expect(page.locator("#astral-input")).toHaveValue("A long request\n\nA long request");
});

test("a background reload waits behind a queued follow-up and then runs once", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Queued follow-up");
  await receive(page, { type: "task_completed", payload: {
    task_id: OPERATION_C, chat_id: CHAT_ID, status: "completed", summary: "Report ready" } });
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const messages = await sentActions(page, "chat_message");
  expect(messages.at(-1).payload.message).toBe("Queued follow-up");
  expect(await sentLoads(page)).toHaveLength(0);
  const second = nextTurnScope(turnScope, messages.at(-1));
  await receive(page, operationStatus(second, OPERATION_B, 0, "running"));
  await receive(page, operationStatus(second, OPERATION_B, 1, "completed"));
  expect(await sentLoads(page)).toHaveLength(1);
});

test("a first message left for a New chat cannot make its chat the open one", async ({ page }) => {
  await installHarness(page, { locator: false });
  await registration(page);
  await page.locator("#astral-input").fill("First message");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  await page.locator("#astral-newchat-btn").click();
  await receive(page, { type: "chat_created", payload: { chat_id: THIRD_CHAT_ID, from_message: true } });
  expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key) || "null")?.chat_id ?? null, LOCATOR_KEY))
    .toBeNull();
  await page.locator("#astral-input").fill("For the new chat");
  await page.locator("#astral-form").evaluate((form) => form.requestSubmit());
  const message = await page.evaluate(() => window.__socketEvents.findLast((event) => (
    event.frame.action === "chat_message")).frame);
  expect(message.payload.message).toBe("For the new chat");
  expect(message.payload.chat_id ?? null).not.toBe(THIRD_CHAT_ID);
});

test("a refused queued message returns the rest of the queue to the composer", async ({ page }) => {
  const { turnScope } = await startTurnInChat(page, { steer: true });
  await submitComposer(page, "First follow-up");
  await submitComposer(page, "Second follow-up");
  await receive(page, operationStatus(turnScope, OPERATION_A, 2, "completed"));
  const sent = (await sentActions(page, "chat_message")).at(-1);
  expect(sent.payload.message).toBe("First follow-up");
  await receive(page, { type: "error", accepted: false, code: "capacity_exceeded", message: "Busy right now",
    retry_after_ms: null, retryable: false, submission_id: sent.submission_id });
  await expect(page.locator(QUEUED_ROWS)).toHaveCount(0);
  await expect(page.locator("#astral-input")).toHaveValue("Second follow-up");
  await expect(page.locator("#astral-toasts")).toContainText("Your message was not accepted");
});

test("an unconfirmed interruption for a chat left behind survives a drop ahead of its queue", async ({ page }) => {
  await startTurnInChat(page, { steer: true });
  await submitComposer(page, "Steer text");
  await page.locator(QUEUED_ROWS).getByRole("button", { name: "Interrupt" }).click();
  await submitComposer(page, "Queued text");
  await openChatFromHistory(page, OTHER_CHAT_ID);
  await page.evaluate(() => window.__sockets.at(-1).close());
  await page.waitForFunction(() => window.__socketEvents.filter((event) => event.frame.type === "register_ui").length >= 2,
    null, { timeout: 15000 });
  await openChatFromHistory(page, CHAT_ID);
  await expect(page.locator("#astral-input")).toHaveValue(/Steer text[\s\S]*Queued text/u);
});
