// Keeps a device's nonextractable Ed25519 key in account-scoped IndexedDB and proves possession to the
// existing mesh redemption endpoint. The shell and enrollment page supply current session fences.
(function () {
  "use strict";
  function refuse() { throw new Error("Mesh enrollment unavailable. Check this device, account and connection, then retry."); }
  function encode(bytes) {
    return btoa(String.fromCharCode.apply(null, new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function decode(value, size) {
    if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value) || value.length > 2048) refuse();
    var bytes = Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), function (c) { return c.charCodeAt(0); });
    if (encode(bytes) !== value || size && bytes.length !== size) refuse();
    return bytes;
  }
  function publicKey(key) {
    if (!key || Object.keys(key).sort().join(",") !== "crv,kty,x" || key.kty !== "OKP" || key.crv !== "Ed25519") refuse();
    decode(key.x, 32);
    return { kty: "OKP", crv: "Ed25519", x: key.x };
  }
  function payloadFromLink(value, origin) {
    if (typeof value !== "string" || !value || value.length > 4096) refuse();
    var url = new URL(value, origin);
    if (url.origin !== origin || url.username || url.password || url.pathname !== "/enroll" || url.search || !url.hash) refuse();
    var payload = url.hash.slice(1);
    var parsed = JSON.parse(new TextDecoder().decode(decode(payload)));
    if (!parsed || Object.keys(parsed).sort().join(",") !== "c,i,o,t,v" || parsed.v !== 1 ||
        typeof parsed.o !== "string" || !parsed.o || parsed.o.length > 256 ||
        typeof parsed.i !== "string" || !/^[A-Za-z0-9]{1,128}$/.test(parsed.i)) refuse();
    decode(parsed.t, 32);
    decode(parsed.c, 32);
    return { payload: payload, owner: parsed.o, challenge: decode(parsed.c, 32) };
  }
  function database() {
    return new Promise(function (resolve, reject) {
      var request = indexedDB.open("astral_mesh_custody_v1", 1);
      request.onupgradeneeded = function () { request.result.createObjectStore("devices"); };
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = request.onblocked = function () { reject(new Error("Mesh device custody unavailable.")); };
    });
  }
  async function record(scope, mode, value, current) {
    var db = await database();
    try {
      return await new Promise(function (resolve, reject) {
        var transaction = db.transaction("devices", mode === "get" ? "readonly" : "readwrite");
        var store = transaction.objectStore("devices");
        var selected;
        var request = mode === "get" || mode === "create" || mode === "member" ? store.get(scope) : store.delete(scope);
        if (mode === "create" || mode === "member") request.onsuccess = function () {
          if (current && !current()) { transaction.abort(); return; }
          if (mode === "create") {
            selected = request.result || value;
            if (!request.result) store.put(value, scope);
          } else {
            if (!request.result || !request.result.publicKey || request.result.publicKey.x !== value.device_key.x) { transaction.abort(); return; }
            store.put(Object.assign({}, request.result, { member: value }), scope);
          }
        };
        transaction.oncomplete = function () { resolve(mode === "create" ? selected : request.result); };
        transaction.onerror = transaction.onabort = function () { reject(new Error("Mesh device custody unavailable.")); };
      });
    } finally { db.close(); }
  }
  async function scopeFor(identity) {
    if (!identity || typeof identity.issuer !== "string" || !identity.issuer || typeof identity.subject !== "string" || !identity.subject) refuse();
    var digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([location.origin, identity.issuer, identity.subject])));
    return encode(digest);
  }
  function fence(current) { if (!current()) refuse(); }
  async function device(identity, create, current) {
    fence(current);
    var scope = await scopeFor(identity);
    fence(current);
    var stored = await record(scope, "get");
    fence(current);
    if (!stored && create) {
      var pair = await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
      fence(current);
      var jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      var key = publicKey({ kty: jwk.kty, crv: jwk.crv, x: jwk.x });
      stored = { privateKey: pair.privateKey, publicKey: key };
      stored = await record(scope, "create", stored, current);
      if (!current()) { await record(scope, "delete"); refuse(); }
    }
    if (!stored || !stored.privateKey || stored.privateKey.extractable || stored.privateKey.type !== "private" ||
        stored.privateKey.algorithm.name !== "Ed25519") refuse();
    var normalized = publicKey(stored.publicKey);
    var test = crypto.getRandomValues(new Uint8Array(32));
    var signature = await crypto.subtle.sign("Ed25519", stored.privateKey, test);
    var verifier = await crypto.subtle.importKey("jwk", normalized, "Ed25519", false, ["verify"]);
    if (!await crypto.subtle.verify("Ed25519", verifier, signature, test)) refuse();
    fence(current);
    return { scope: scope, stored: stored, publicKey: normalized };
  }
  async function boundedJson(response) {
    if (!response.ok) refuse();
    var reader = response.body.getReader();
    var parts = [];
    var size = 0;
    try {
      while (true) {
        var next = await reader.read();
        if (next.done) break;
        size += next.value.length;
        if (size > 65536) refuse();
        parts.push(next.value);
      }
    } finally { await reader.cancel(); }
    var bytes = new Uint8Array(size);
    var offset = 0;
    parts.forEach(function (part) { bytes.set(part, offset); offset += part.length; });
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  }
  async function identityFromSession() {
    var response = await fetch("/auth/session", { credentials: "same-origin", cache: "no-store", redirect: "error" });
    if (!response.ok) refuse();
    var session = await boundedJson(response);
    if (!session.authenticated || typeof session.access_token !== "string") refuse();
    var claims = JSON.parse(new TextDecoder().decode(decode(session.access_token.split(".")[1])));
    if (session.user_id !== claims.sub || typeof claims.iss !== "string") refuse();
    return { subject: claims.sub, issuer: claims.iss };
  }
  async function verifyIdentity(identity, current) {
    fence(current);
    var latest = await identityFromSession();
    fence(current);
    if (latest.subject !== identity.subject || latest.issuer !== identity.issuer) {
      await record(await scopeFor(identity), "delete");
      refuse();
    }
  }
  async function prepare(identity, fields, current) {
    if (!fields || typeof fields !== "object") refuse();
    if (fields.device_key) {
      var shared = publicKey(JSON.parse(fields.device_key));
      fence(current);
      return Object.assign({}, fields, { device_key: JSON.stringify(shared) });
    }
    var local = await device(identity, true, current);
    return Object.assign({}, fields, { device_key: JSON.stringify(local.publicKey) });
  }
  async function redeem(identity, link, current) {
    var grant = payloadFromLink(link, location.origin);
    if (grant.owner !== identity.subject) refuse();
    var local = await device(identity, false, current);
    await verifyIdentity(identity, current);
    var signature = await crypto.subtle.sign("Ed25519", local.stored.privateKey, grant.challenge);
    fence(current);
    var response = await fetch("/api/mesh/enrollment/redeem", {
      method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ payload: grant.payload, signature: encode(signature) })
    });
    fence(current);
    if (!response.ok) refuse();
    var result = await boundedJson(response);
    if (result.token_type !== "DPoP" || typeof result.access_token !== "string" || !result.access_token ||
        !result.member || result.member.owner_id !== identity.subject || typeof result.member.member_id !== "string" ||
        !/^[A-Za-z0-9]{1,128}$/.test(result.member.member_id) ||
        publicKey(result.member.device_key).x !== local.publicKey.x || result.member.status !== "active") refuse();
    var nonceResponse = await fetch("/api/mesh/nonce", { method: "POST", credentials: "omit", cache: "no-store", redirect: "error",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify({ owner_id: identity.subject, member_id: result.member.member_id }) });
    fence(current);
    var nonce = (await boundedJson(nonceResponse)).nonce;
    decode(nonce, 32);
    var tokenHash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(result.access_token));
    var header = { typ: "dpop+jwt", alg: "EdDSA", jwk: local.publicKey };
    var claims = { jti: crypto.randomUUID(), htm: "GET", htu: location.origin + "/api/mesh/me",
      iat: Math.floor(Date.now() / 1000), nonce: nonce, ath: encode(tokenHash) };
    var signed = encode(new TextEncoder().encode(JSON.stringify(header))) + "." + encode(new TextEncoder().encode(JSON.stringify(claims)));
    var proof = signed + "." + encode(await crypto.subtle.sign("Ed25519", local.stored.privateKey, new TextEncoder().encode(signed)));
    fence(current);
    var verifiedResponse = await fetch("/api/mesh/me", { credentials: "omit", cache: "no-store", redirect: "error",
      headers: { Authorization: "DPoP " + result.access_token, DPoP: proof, "DPoP-Nonce": nonce } });
    fence(current);
    var verified = (await boundedJson(verifiedResponse)).member;
    if (!verified || verified.owner_id !== identity.subject || verified.member_id !== result.member.member_id ||
        publicKey(verified.device_key).x !== local.publicKey.x || verified.status !== "active") refuse();
    var member = { owner_id: identity.subject, member_id: result.member.member_id, device_key: local.publicKey };
    await verifyIdentity(identity, current);
    await record(local.scope, "member", member, current);
    if (!current()) { await record(local.scope, "delete"); refuse(); }
    return member;
  }
  window.AstralMeshCustody = Object.freeze({ prepare: prepare, redeem: redeem, identityFromSession: identityFromSession,
    publicIdentity: async function (identity, current) { return (await device(identity, true, current)).publicKey; },
    purge: async function (identity) { await record(await scopeFor(identity), "delete"); },
    payloadFromLink: payloadFromLink });
}());
