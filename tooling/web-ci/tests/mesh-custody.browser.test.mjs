// Exercises real browser key generation and IndexedDB custody with a synthetic server boundary; Node
// verifies the exact Ed25519 challenge wire bytes while separate browser profiles represent devices.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { createPublicKey, createHash, verify } from "node:crypto";
import { after, test } from "node:test";
import { chromium } from "@playwright/test";

const moduleSource = await readFile(new URL("../../../backend/webrender/static/mesh-custody.js", import.meta.url));
const pageSource = await readFile(new URL("../../../backend/webrender/templates/enrollment.html", import.meta.url), "utf8");
const enrollmentSource = await readFile(new URL("../../../backend/webrender/static/mesh-enrollment.js", import.meta.url));
const sharedStyle = await readFile(new URL("../../../backend/webrender/static/astral.css", import.meta.url));
const pageStyle = await readFile(new URL("../../../backend/webrender/static/mesh-enrollment.css", import.meta.url));
const owner = "synthetic-owner";
const challenge = Buffer.alloc(32, 19);
const payload = Buffer.from(JSON.stringify({ v: 1, o: owner, i: "abc123", t: Buffer.alloc(32, 7).toString("base64url"), c: challenge.toString("base64url") })).toString("base64url");
const coverage = [];
const assetPaths = new Set(["/static/mesh-custody.js", "/static/mesh-enrollment.js"]);

function enrollmentPage() {
  return pageSource.replaceAll("%%ASTRAL_NONCE%%", "synthetic").replace(/\?v=%%ASTRAL_V:[^%]+%%/g, "");
}

async function coveredPage(context, pages, options) {
  const page = await context.newPage(options);
  await page.coverage.startJSCoverage({ resetOnNavigation: false });
  pages.push(page);
  return page;
}

async function collectCoverage(pages) {
  for (const page of pages) {
    coverage.push(...(await page.coverage.stopJSCoverage()).filter(entry => assetPaths.has(new URL(entry.url).pathname)));
  }
}

after(async () => {
  const output = process.env.ASTRAL_MESH_COVERAGE_OUTPUT;
  if (output) {
    assert(coverage.some(entry => new URL(entry.url).pathname === "/static/mesh-custody.js"));
    assert(coverage.some(entry => new URL(entry.url).pathname === "/static/mesh-enrollment.js"));
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, JSON.stringify(coverage) + "\n", { mode: 0o600 });
  }
});

test("joining device retains its own key and only proves the exact confirmed challenge", async () => {
  let requests = 0;
  let meRequests = 0;
  const issuedNonce = "0123456789abcdef0123456789abcdef." + Buffer.alloc(32, 27).toString("base64url");
  let nonce = issuedNonce;
  let expectedKey;
  let denied = false;
  let sessionOwner = owner;
  let badMember = false;
  let oversized = false;
  let switched = false;
  let meArrived;
  let releaseMe;
  let retireAfterPersistence = false;
  let sessionResponsesAfterMe = null;
  const server = createServer(async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    if (request.url === "/static/mesh-custody.js") { response.setHeader("Content-Type", "text/javascript"); response.end(moduleSource); return; }
    if (request.url === "/static/mesh-enrollment.js") { response.setHeader("Content-Type", "text/javascript"); response.end(enrollmentSource); return; }
    if (request.url === "/enroll") { response.setHeader("Content-Type", "text/html"); response.end(enrollmentPage()); return; }
    if (request.url === "/auth/session") {
      if (sessionResponsesAfterMe !== null && sessionResponsesAfterMe++ > 0) sessionOwner = "replacement-owner";
      response.setHeader("Content-Type", "application/json");
      const claims = Buffer.from(JSON.stringify({ iss: "https://iam.example/realms/astral", sub: sessionOwner })).toString("base64url");
      response.end(JSON.stringify({ authenticated: true, user_id: sessionOwner, access_token: `synthetic.${claims}.signature` })); return;
    }
    if (request.url === "/api/mesh/nonce") {
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({ nonce })); return;
    }
    if (request.url === "/api/mesh/me") {
      meRequests++;
      assert.equal(request.headers.authorization, "DPoP ephemeral-synthetic");
      assert.equal(request.headers.cookie, undefined);
      if (meArrived) { meArrived(); await new Promise(resolve => { releaseMe = resolve; }); }
      const parts = request.headers.dpop.split(".");
      const header = JSON.parse(Buffer.from(parts[0], "base64url"));
      const claims = JSON.parse(Buffer.from(parts[1], "base64url"));
      assert.equal(header.alg, "EdDSA"); assert.equal(header.typ, "dpop+jwt");
      assert.deepEqual(header.jwk, expectedKey);
      assert.equal(claims.htm, "GET"); assert.equal(claims.htu, `http://127.0.0.1:${server.address().port}/api/mesh/me`);
      assert.equal(claims.ath, createHash("sha256").update("ephemeral-synthetic").digest("base64url"));
      assert.equal(claims.nonce, request.headers["dpop-nonce"]);
      assert.equal(claims.nonce, issuedNonce);
      assert(verify(null, Buffer.from(parts[0] + "." + parts[1]), createPublicKey({ key: expectedKey, format: "jwk" }), Buffer.from(parts[2], "base64url")));
      response.setHeader("Content-Type", "application/json");
      if (switched) sessionOwner = "replacement-owner";
      if (retireAfterPersistence) sessionResponsesAfterMe = 0;
      response.end(JSON.stringify({ member: { owner_id: owner, member_id: "member1", device_key: expectedKey, status: badMember ? "revoked" : "active" } })); return;
    }
    if (request.url === "/api/mesh/enrollment/redeem") {
      requests++;
      let body = "";
      for await (const chunk of request) body += chunk;
      const parsed = JSON.parse(body);
      assert.deepEqual(Object.keys(parsed).sort(), ["payload", "signature"]);
      assert.equal(parsed.payload, payload);
      assert.equal(Buffer.from(parsed.signature, "base64url").length, 64);
      const valid = verify(null, challenge, createPublicKey({ key: expectedKey, format: "jwk" }), Buffer.from(parsed.signature, "base64url"));
      response.setHeader("Content-Type", "application/json");
      if (!valid || denied) { response.writeHead(403); response.end('{"detail":"mesh_redeem_invalid"}'); return; }
      if (oversized) { response.end(JSON.stringify({ unexpected: "x".repeat(65536) })); return; }
      response.end(JSON.stringify({ token_type: "DPoP", access_token: "ephemeral-synthetic", member: { owner_id: owner, member_id: "member1", device_key: expectedKey, status: "active" } }));
      return;
    }
    response.setHeader("Content-Type", "text/html"); response.end('<script src="/static/mesh-custody.js"></script>');
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true });
  const pages = [];
  try {
    const joining = await browser.newContext();
    const approving = await browser.newContext();
    const page = await coveredPage(joining, pages);
    const other = await coveredPage(approving, pages);
    await page.goto(origin); await other.goto(origin);
    await joining.addCookies([{ name: "astral_session", value: "synthetic-owner-cookie", url: origin }]);
    const identity = { issuer: "https://iam.example/realms/astral", subject: owner };
    const key = await page.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => true), identity);
    expectedKey = key;
    const prepared = await page.evaluate(async identity => window.AstralMeshCustody.prepare(identity, { role: "device" }, () => true), identity);
    assert.deepEqual(JSON.parse(prepared.device_key), key);
    assert.equal(prepared.role, "device");
    const shared = await page.evaluate(async ({ identity, key }) => window.AstralMeshCustody.prepare(identity,
      { role: "device", device_key: JSON.stringify(key) }, () => true), { identity, key });
    assert.deepEqual(shared, prepared);
    const afterReload = await page.reload().then(() => page.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => true), identity));
    assert.deepEqual(afterReload, key);
    const keyState = await page.evaluate(() => new Promise((resolve, reject) => {
      const open = indexedDB.open("astral_mesh_custody_v1", 1);
      open.onsuccess = () => {
        const db = open.result; const get = db.transaction("devices").objectStore("devices").getAll();
        get.onsuccess = async () => {
          const key = get.result[0].privateKey;
          let exported;
          try { await crypto.subtle.exportKey("pkcs8", key); exported = true; } catch { exported = false; }
          resolve({ extractable: key.extractable, exported }); db.close();
        };
        get.onerror = reject;
      };
      open.onerror = reject;
    }));
    assert.deepEqual(keyState, { extractable: false, exported: false });
    const sameProfile = await coveredPage(joining, pages);
    await sameProfile.goto(origin);
    const raceIdentity = { ...identity, subject: "concurrent-owner" };
    const concurrent = await Promise.all([page, sameProfile].map(tab => tab.evaluate(async identity =>
      window.AstralMeshCustody.publicIdentity(identity, () => true), raceIdentity)));
    assert.deepEqual(concurrent[0], concurrent[1]);
    const link = `${origin}/enroll#${payload}`;
    await assert.rejects(other.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    assert.equal(requests, 0);
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem({ ...identity, subject: "other-owner" }, link, () => true), { identity, link }));
    assert.equal(requests, 0);
    const otherKey = await other.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => true), identity);
    assert.notEqual(otherKey.x, key.x);
    await assert.rejects(other.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    assert.equal(requests, 1);
    denied = true;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    denied = false;
    oversized = true;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    oversized = false;
    badMember = true;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    badMember = false;
    const member = await page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link });
    assert.equal(member.member_id, "member1"); assert.equal(member.device_key.x, key.x);
    const enrollment = await coveredPage(joining, pages);
    await enrollment.goto(link);
    await enrollment.getByRole("button", { name: "Complete enrollment" }).click();
    await enrollment.getByRole("status").filter({ hasText: "This device is enrolled." }).waitFor();
    assert.equal(await enrollment.getByLabel("Secure enrollment link").inputValue(), "");
    assert.equal(await enrollment.getByRole("button", { name: "Complete enrollment" }).isEnabled(), true);
    await enrollment.goto(origin);
    retireAfterPersistence = true;
    await enrollment.goto(link);
    await enrollment.getByRole("button", { name: "Complete enrollment" }).click();
    await enrollment.getByRole("status").filter({ hasText: "Enrollment refused." }).waitFor();
    assert.equal(await enrollment.getByLabel("Secure enrollment link").inputValue(), "");
    retireAfterPersistence = false; sessionResponsesAfterMe = null; sessionOwner = owner;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    expectedKey = await page.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => true), identity);
    const beforeMalformedNonce = meRequests;
    for (const malformed of [null, Buffer.alloc(32, 27).toString("base64url"), "g".repeat(32) + issuedNonce.slice(32), issuedNonce + "=", issuedNonce + "\n", issuedNonce.slice(0, -1) + "B", "a".repeat(2049)]) {
      nonce = malformed;
      await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
      assert.equal(meRequests, beforeMalformedNonce);
    }
    nonce = issuedNonce;
    for (const bad of [`https://foreign.example/enroll#${payload}`, `${origin}/enroll?token=bad#${payload}`, `${origin}/other#${payload}`, `${origin}/enroll#%%%`]) {
      await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link: bad }));
    }
    await assert.rejects(page.evaluate(async identity => window.AstralMeshCustody.prepare(identity, { device_key: JSON.stringify({ kty: "OKP", crv: "Ed25519", x: "bad", d: "private" }) }, () => true), identity));
    await assert.rejects(page.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => false), identity));
    switched = true;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    switched = false; sessionOwner = owner;
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    expectedKey = await page.evaluate(async identity => window.AstralMeshCustody.publicIdentity(identity, () => true), identity);
    const arrival = new Promise(resolve => { meArrived = resolve; });
    const pending = page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link });
    await arrival;
    await sameProfile.evaluate(async identity => window.AstralMeshCustody.purge(identity), identity);
    releaseMe(); meArrived = null;
    await assert.rejects(pending);
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
    await page.evaluate(async identity => window.AstralMeshCustody.purge(identity), identity);
    await assert.rejects(page.evaluate(async ({ identity, link }) => window.AstralMeshCustody.redeem(identity, link, () => true), { identity, link }));
  } finally {
    try { await collectCoverage(pages); }
    finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
  }
});

test("joining page clears its fragment and remains usable at narrow enlarged widths", async () => {
  const observed = [];
  const server = createServer((request, response) => {
    observed.push(request.url);
    response.setHeader("Cache-Control", "no-store");
    if (request.url === "/auth/session") { response.writeHead(401); response.end("{}"); return; }
    const assets = {
      "/static/mesh-custody.js": ["text/javascript", moduleSource],
      "/static/mesh-enrollment.js": ["text/javascript", enrollmentSource],
      "/static/astral.css": ["text/css", sharedStyle],
      "/static/mesh-enrollment.css": ["text/css", pageStyle]
    };
    if (assets[request.url]) {
      response.setHeader("Content-Type", assets[request.url][0]); response.end(assets[request.url][1]); return;
    }
    if (request.url.startsWith("/static/")) { response.writeHead(404); response.end(); return; }
    response.setHeader("Content-Type", "text/html");
    response.end(enrollmentPage());
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true });
  const pages = [];
  try {
    const page = await coveredPage(browser, pages, { viewport: { width: 320, height: 720 } });
    await page.goto(`${origin}/enroll#${payload}`);
    assert.equal(new URL(page.url()).hash, "");
    assert.equal(await page.evaluate(() => Object.hasOwn(window, "__ASTRAL_ENROLLMENT__")), false);
    assert.equal(await page.getByLabel("Secure enrollment link").inputValue(), `${origin}/enroll#${payload}`);
    await page.evaluate(() => { document.documentElement.style.fontSize = "200%"; });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement.textContent), "Sign in as the owner in another tab");
    await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement.id), "mesh-link");
    await page.getByRole("button", { name: "Complete enrollment" }).click();
    await page.getByRole("status").filter({ hasText: "Enrollment refused." }).waitFor();
    assert.equal(await page.getByLabel("Secure enrollment link").inputValue(), "");
    assert(!observed.some(url => url.includes(payload) || url.startsWith("/api/mesh/")));
  } finally {
    try { await collectCoverage(pages); }
    finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
  }
});
