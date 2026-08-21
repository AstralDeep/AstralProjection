import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import {
  BROWSER_COVERAGE_PRODUCER,
  NODE_COVERAGE_PRODUCER,
  UNION_COVERAGE_PRODUCER,
  unionCanonicalCoverage,
} from "../coverage-union.mjs";

function fixture() {
  const repoRoot = mkdtempSync(resolve(tmpdir(), "projection-coverage-union-"));
  const sourcePath = "backend/webrender/static/client.js";
  const absolute = resolve(repoRoot, sourcePath);
  mkdirSync(resolve(absolute, ".."), { recursive: true });
  writeFileSync(absolute, "const alpha = 1;\nalpha;\n", "utf8");
  return { repoRoot, sourcePath };
}

function envelope(identity, sourcePath, hits = { 0: 1, 1: 0 }) {
  return {
    ...identity,
    coverage: {
      [sourcePath]: {
        path: sourcePath,
        statementMap: {
          0: {
            start: { line: 1, column: 0 },
            end: { line: 1, column: 15 },
          },
          1: {
            start: { line: 2, column: 0 },
            end: { line: 2, column: 5 },
          },
        },
        s: hits,
      },
    },
  };
}

test("Node and browser observations form one source-bound canonical envelope", () => {
  const { repoRoot, sourcePath } = fixture();
  const merged = unionCanonicalCoverage({
    node: envelope(NODE_COVERAGE_PRODUCER, sourcePath, { 0: 1, 1: 0 }),
    browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath, { 0: 2, 1: 3 }),
    repoRoot,
  });

  assert.deepEqual(
    Object.fromEntries(Object.entries(merged).filter(([key]) => key !== "coverage")),
    UNION_COVERAGE_PRODUCER,
  );
  assert.deepEqual(Object.keys(merged.coverage), [sourcePath]);
  assert.deepEqual(merged.coverage[sourcePath].s, { 0: 3, 1: 3 });
});

test("disjoint maintained sources are emitted in deterministic path order", () => {
  const { repoRoot, sourcePath } = fixture();
  const secondPath = "tooling/web-ci/probe.mjs";
  const secondAbsolute = resolve(repoRoot, secondPath);
  mkdirSync(resolve(secondAbsolute, ".."), { recursive: true });
  writeFileSync(secondAbsolute, "const alpha = 1;\nalpha;\n", "utf8");

  const merged = unionCanonicalCoverage({
    node: envelope(NODE_COVERAGE_PRODUCER, secondPath),
    browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
    repoRoot,
  });

  assert.deepEqual(Object.keys(merged.coverage), [sourcePath, secondPath]);
});

test("metadata, record shape, paths, source binding, and counts fail closed", () => {
  const { repoRoot, sourcePath } = fixture();
  const mutations = [
    (value) => { value.schema_version = 2; },
    (value) => { value.extra = true; },
    (value) => { value.coverage[sourcePath].path = "backend/webrender/static/other.js"; },
    (value) => { value.coverage[sourcePath].extra = true; },
    (value) => { value.coverage[sourcePath].statementMap[0].end.column = 14; },
    (value) => { value.coverage[sourcePath].statementMap[1] = value.coverage[sourcePath].statementMap[0]; },
    (value) => { value.coverage[sourcePath].s[0] = -1; },
    (value) => { value.coverage[sourcePath].s[0] = 1.5; },
  ];

  for (const mutate of mutations) {
    const node = structuredClone(envelope(NODE_COVERAGE_PRODUCER, sourcePath));
    mutate(node);
    assert.throws(
      () => unionCanonicalCoverage({
        node,
        browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
        repoRoot,
      }),
      /invalid canonical JavaScript coverage union/u,
    );
  }

  const unsafe = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
  unsafe.coverage = { "../client.js": unsafe.coverage[sourcePath] };
  assert.throws(
    () => unionCanonicalCoverage({
      node: unsafe,
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot,
    }),
    /invalid canonical JavaScript coverage union/u,
  );
});

test("empty, malformed, and non-canonical source envelopes fail closed", () => {
  const { repoRoot, sourcePath } = fixture();
  const mutations = [
    (value) => { value.coverage = null; },
    (value) => { value.coverage = {}; },
    (value) => { value.coverage[sourcePath].statementMap = []; },
    (value) => { value.coverage[sourcePath].s = []; },
    (value) => { delete value.coverage[sourcePath].s[1]; },
  ];
  for (const mutate of mutations) {
    const node = structuredClone(envelope(NODE_COVERAGE_PRODUCER, sourcePath));
    mutate(node);
    assert.throws(
      () => unionCanonicalCoverage({
        node,
        browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
        repoRoot,
      }),
      /invalid canonical JavaScript coverage union/u,
    );
  }

  for (const unsafePath of [
    "",
    "/backend/webrender/static/client.js",
    "backend\\webrender\\static\\client.js",
    "backend/webrender/tests/client.js",
    "backend/webrender/static/vendor/client.js",
    "backend/webrender/static/client.min.js",
    "tooling/web-ci/client.txt",
  ]) {
    const node = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
    node.coverage = {
      [unsafePath]: { ...node.coverage[sourcePath], path: unsafePath },
    };
    assert.throws(
      () => unionCanonicalCoverage({
        node,
        browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
        repoRoot,
      }),
      /invalid canonical JavaScript coverage union/u,
    );
  }

  const missingPath = "backend/webrender/static/missing.js";
  const missing = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
  missing.coverage = {
    [missingPath]: { ...missing.coverage[sourcePath], path: missingPath },
  };
  assert.throws(
    () => unionCanonicalCoverage({
      node: missing,
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot,
    }),
    /source is unavailable/u,
  );

  const emptyPath = "backend/webrender/static/empty.js";
  writeFileSync(resolve(repoRoot, emptyPath), "", "utf8");
  const empty = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
  empty.coverage = { [emptyPath]: { ...empty.coverage[sourcePath], path: emptyPath } };
  assert.throws(
    () => unionCanonicalCoverage({
      node: empty,
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot,
    }),
    /source size is out of bounds/u,
  );

  const linkPath = "backend/webrender/static/link.js";
  symlinkSync(resolve(repoRoot, sourcePath), resolve(repoRoot, linkPath));
  const linked = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
  linked.coverage = { [linkPath]: { ...linked.coverage[sourcePath], path: linkPath } };
  assert.throws(
    () => unionCanonicalCoverage({
      node: linked,
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot,
    }),
    /source is not a canonical regular file/u,
  );
});

test("invalid UTF-8, invalid syntax, and non-executable source fail closed", () => {
  for (const [name, bytes, expected] of [
    ["utf8.js", Buffer.from([0xff]), /source is not UTF-8/u],
    ["syntax.js", "const = ;\n", /source cannot produce a canonical statement map/u],
    ["comments.js", "// comment only\n", /source cannot produce a canonical statement map/u],
  ]) {
    const { repoRoot, sourcePath } = fixture();
    const path = `backend/webrender/static/${name}`;
    writeFileSync(resolve(repoRoot, path), bytes);
    const mutated = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
    mutated.coverage = { [path]: { ...mutated.coverage[sourcePath], path } };
    assert.throws(
      () => unionCanonicalCoverage({
        node: mutated,
        browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
        repoRoot,
      }),
      expected,
    );
  }
});

test("repository root must be an available directory", () => {
  const { repoRoot, sourcePath } = fixture();
  assert.throws(
    () => unionCanonicalCoverage({
      node: envelope(NODE_COVERAGE_PRODUCER, sourcePath),
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot: resolve(repoRoot, "missing"),
    }),
    /repository root is unavailable/u,
  );
  const regularFile = resolve(repoRoot, "root-file");
  writeFileSync(regularFile, "not a directory", "utf8");
  assert.throws(
    () => unionCanonicalCoverage({
      node: envelope(NODE_COVERAGE_PRODUCER, sourcePath),
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath),
      repoRoot: regularFile,
    }),
    /repository root is not a directory/u,
  );
});

test("hit-count overflow fails instead of wrapping or saturating", () => {
  const { repoRoot, sourcePath } = fixture();
  assert.throws(
    () => unionCanonicalCoverage({
      node: envelope(NODE_COVERAGE_PRODUCER, sourcePath, {
        0: Number.MAX_SAFE_INTEGER,
        1: 0,
      }),
      browser: envelope(BROWSER_COVERAGE_PRODUCER, sourcePath, { 0: 1, 1: 0 }),
      repoRoot,
    }),
    /overflow/u,
  );
});

test("union requires one genuine Node lane and one genuine browser lane", () => {
  const { repoRoot, sourcePath } = fixture();
  const node = envelope(NODE_COVERAGE_PRODUCER, sourcePath);
  const browser = envelope(BROWSER_COVERAGE_PRODUCER, sourcePath);

  for (const [left, right] of [
    [node, node],
    [browser, browser],
    [browser, node],
  ]) {
    assert.throws(
      () => unionCanonicalCoverage({ node: left, browser: right, repoRoot }),
      /producer identity/u,
    );
  }

  const forgedBrowser = structuredClone(browser);
  forgedBrowser.coverage_lane = NODE_COVERAGE_PRODUCER.coverage_lane;
  assert.throws(
    () => unionCanonicalCoverage({ node, browser: forgedBrowser, repoRoot }),
    /producer identity/u,
  );
});
