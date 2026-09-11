// Deterministic client reducer/continuity contract suite. This intentionally
// uses a synthetic DOM and is never the feature-060 qualifying release proof.
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { expect, test } from "@playwright/test";


const ROOT = resolve(import.meta.dirname, "../../..");
const CLIENT_PATH = resolve(ROOT, "backend/webrender/static/client.js");
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
    <div id="astral-history"></div>
    <main>
      <div id="astral-start-intro"></div>
      <div id="astral-start-permission"></div>
      <div id="astral-chat"></div>
      <div id="astral-status"></div>
      <form id="astral-form"><textarea id="astral-input" rows="2"></textarea><button type="submit">Send</button></form>
      <div id="astral-start-examples"></div>
      <div id="astral-start-more"></div>
      <section id="astral-canvas"><div id="astral-canvas-empty">Empty</div></section>
      <div id="astral-attachments" class="hidden"></div>
      <button id="astral-attach-btn" type="button"></button>
      <input id="astral-attach-input" class="astral-file-upload" type="file" hidden>
      <div id="astral-voice-controls"></div>
      <div id="astral-voice-transcript"></div>
      <div id="astral-voice-turn-notice"><span id="astral-voice-turn-notice-title"></span><span id="astral-voice-turn-notice-message"></span></div>
      <button id="astral-bg-btn" type="button" aria-pressed="false"></button>
      <div id="astral-slash-menu" class="hidden"></div>
      <div id="astral-modal"></div>
    </main>
  </body></html>`;
}


async function installHarness(page, { locator = true, url = "https://candidate.example/" } = {}) {
  await page.addInitScript(({ token }) => {
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
        // 066: the client gates action() sends behind the post-registration
        // rote_config verdict (socketReady + queue flush). Mirror the real
        // server so ui_events dispatch immediately instead of queueing.
        if (frame.type === "register_ui") {
          queueMicrotask(() => {
            this.receive({
              type: "rote_config",
              device_profile: { device_type: "browser" },
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
  }, { token: TOKEN });

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
  const source = await readFile(CLIENT_PATH, "utf8");
  await page.addScriptTag({ content: `${source}\n//# sourceURL=https://candidate.example/static/client.js` });
  await page.waitForFunction(() => window.__socketEvents.some((event) => event.frame.type === "register_ui"));
}


async function registration(page) {
  return page.evaluate(() => window.__socketEvents.find((event) => event.frame.type === "register_ui"));
}

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
    document.querySelector("#astral-chat").innerHTML = '<div id="old-transcript">Old transcript</div>';
    document.querySelector("#astral-canvas").innerHTML = '<div id="old-canvas">Old canvas</div>';
  });
  await receive(page, snapshot(event.frame));

  await expect(page.locator("#astral-chat")).toContainText("Committed answer");
  await expect(page.locator("#astral-chat #old-transcript")).toHaveCount(0);
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas #old-canvas")).toHaveCount(0);

  // The bounded legacy acknowledgement may race behind the authoritative
  // snapshot. It must not resurrect a completed hydration indicator.
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
  // Startup metadata is protocol-visible but never presented as user work.
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

  // Content commit is not a terminal operation and cannot clear progress.
  await receive(page, snapshot(scope));
  await expect(status).toHaveText("Working on second operation…");
  await expect(status).toHaveAttribute("aria-busy", "true");

  // Completing the visible operation restores another genuinely active one;
  // the terminal success label itself is never rendered.
  await receive(page, operationStatus(scope, OPERATION_B, 1, "completed"));
  await expect(status).toHaveText("Preparing first operation…");
  await expect(status).toHaveAttribute("aria-busy", "true");

  await receive(page, operationStatus(scope, OPERATION_C, 0, "failed"));
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");

  // A late generic chat terminal cannot erase another operation's error.
  await receive(page, {
    type: "chat_status",
    status: "done",
    chat_id: CHAT_ID,
    connection_generation: scope.connection_generation,
    request_generation: scope.request_generation,
  });
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");

  // A different success cannot erase the failure notice.
  await receive(page, operationStatus(scope, OPERATION_A, 1, "completed"));
  await expect(status).toHaveText("Visible terminal failure");
  await expect(status).toHaveAttribute("aria-busy", "false");

  // A new explicit request owns the line and its success returns it to idle.
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

  // A late update from the first operation can temporarily own the line.
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
  await expect(page.locator("#astral-chat [data-astral-transient-overlay]")).toHaveCount(0);
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

  await expect(page.locator("#astral-canvas [data-astral-transient-overlay]")).toContainText("Disposable preview");
  await expect(page.locator("#astral-chat [data-astral-transient-overlay]")).toContainText("Transient answer");
  await expect(page.locator("#astral-canvas")).toContainText("ROTE-adapted canvas");
  await expect(page.locator("#astral-canvas")).not.toContainText("Duplicate must not win");
  await expect(page.locator("#astral-canvas")).not.toContainText("Wrong base");
  await expect(page.locator("#astral-chat")).toContainText("Committed answer");

  // A successful operation terminal may race ahead of the authoritative
  // snapshot. It settles activity but cannot discard the visible answer.
  await receive(page, operationStatus(previewScope, OPERATION_A, 0, "completed"));
  await expect(page.locator("#astral-status")).toHaveText("");
  await expect(page.locator("#astral-status")).toHaveAttribute("aria-busy", "false");
  await expect(page.locator("#astral-chat [data-astral-transient-overlay]")).toContainText("Transient answer");
  await expect(page.locator("#astral-canvas [data-astral-transient-overlay]")).toContainText("Disposable preview");
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
  // Reconnect obtains the next authenticated owner's identity.
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
    for (const name of ["inter-latin.woff2", "jetbrains-mono-latin.woff2"]) {
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


test("textarea slash discovery selection and Escape remain usable", async ({ page }) => {
  await installHarness(page, { locator: false });
  await page.locator("#astral-input").fill("/help");
  await expect(page.locator("#astral-slash-menu")).not.toHaveClass(/hidden/);
  await page.locator("#astral-slash-menu button").first().dispatchEvent("mousedown");
  await expect(page.locator("#astral-input")).toHaveValue("/help ");
  await page.locator("#astral-input").fill("/help");
  await page.locator("#astral-input").press("Escape");
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
  // Deep sends the fresh welcome before assigning the empty chat's identity.
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


test("late welcome cannot replace work content or repopulate the start slots", async ({ page }) => {
  await installHarness(page, { locator: false });
  await receive(page, { type: "ui_render", target: "canvas", html: "<p>Current work result</p>" });
  await expect(page.locator("body")).toHaveAttribute("data-astral-view", "work");
  await receive(page, { type: "ui_render", target: "canvas", html: welcomeHtml() });
  await expect(page.locator("#astral-canvas")).toHaveText("Current work result");
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
