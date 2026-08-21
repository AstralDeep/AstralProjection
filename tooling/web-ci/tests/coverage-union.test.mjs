import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import {
  BROWSER_COVERAGE_PRODUCER,
  BROWSER_LANE_SOURCE_PATHS,
  NODE_COVERAGE_PRODUCER,
  NODE_LANE_SOURCE_PATHS,
  UNION_COVERAGE_PRODUCER,
  unionCanonicalCoverage,
} from "../coverage-union.mjs";

const SOURCE = "const alpha = 1;\nalpha;\n";
const NODE_PATHS = Object.freeze([
  "tooling/web-ci/coverage-conversion-cli.mjs",
  "tooling/web-ci/coverage-conversion.mjs",
  "tooling/web-ci/coverage-union-cli.mjs",
  "tooling/web-ci/coverage-union.mjs",
  "tooling/web-ci/eslint.config.mjs",
  "tooling/web-ci/product-isolation.mjs",
  "tooling/web-ci/release-runner.mjs",
]);
const BROWSER_PATHS = Object.freeze(["backend/webrender/static/client.js"]);

function record(path, hits = { 0: 1, 1: 0 }) {
  return {
    path,
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
  };
}

function envelope(identity, paths, hits = { 0: 1, 1: 0 }) {
  return {
    ...identity,
    coverage: Object.fromEntries(paths.map((path) => [path, record(path, { ...hits })])),
  };
}

function fixture() {
  const repoRoot = mkdtempSync(resolve(tmpdir(), "projection-coverage-union-"));
  for (const path of [...NODE_PATHS, ...BROWSER_PATHS]) {
    const absolute = resolve(repoRoot, path);
    mkdirSync(resolve(absolute, ".."), { recursive: true });
    writeFileSync(absolute, SOURCE, "utf8");
  }
  return {
    repoRoot,
    node: envelope(NODE_COVERAGE_PRODUCER, NODE_PATHS),
    browser: envelope(BROWSER_COVERAGE_PRODUCER, BROWSER_PATHS, { 0: 2, 1: 0 }),
  };
}

test("lane source allowlists are exact and disjoint", () => {
  assert.deepEqual(NODE_LANE_SOURCE_PATHS, NODE_PATHS);
  assert.deepEqual(BROWSER_LANE_SOURCE_PATHS, BROWSER_PATHS);
  assert.deepEqual(
    NODE_LANE_SOURCE_PATHS.filter((path) => BROWSER_LANE_SOURCE_PATHS.includes(path)),
    [],
  );
});

test("exact Node tooling and authoritative browser coverage form one envelope", () => {
  const { repoRoot, node, browser } = fixture();
  const merged = unionCanonicalCoverage({ node, browser, repoRoot });

  assert.deepEqual(
    Object.fromEntries(Object.entries(merged).filter(([key]) => key !== "coverage")),
    UNION_COVERAGE_PRODUCER,
  );
  assert.deepEqual(Object.keys(merged.coverage), [...BROWSER_PATHS, ...NODE_PATHS]);
  assert.deepEqual(merged.coverage[BROWSER_PATHS[0]].s, { 0: 2, 1: 0 });
  assert.deepEqual(merged.coverage[NODE_PATHS[0]].s, { 0: 1, 1: 0 });
});

test("relabeled semantic clones cannot impersonate the other lane", () => {
  const { repoRoot, node } = fixture();
  const relabeledClone = {
    ...BROWSER_COVERAGE_PRODUCER,
    coverage: structuredClone(node.coverage),
  };

  assert.throws(
    () => unionCanonicalCoverage({ node, browser: relabeledClone, repoRoot }),
    /semantically identical/u,
  );
});

test("missing, cross-lane, and unknown source paths fail closed", () => {
  for (const mutation of [
    (node) => { delete node.coverage[NODE_PATHS[0]]; },
    (node) => {
      node.coverage["tooling/web-ci/unknown.mjs"] = record(
        "tooling/web-ci/unknown.mjs",
      );
    },
    (node) => {
      node.coverage[BROWSER_PATHS[0]] = structuredClone(record(BROWSER_PATHS[0]));
    },
    (_node, browser) => { browser.coverage = {}; },
    (_node, browser) => {
      browser.coverage[NODE_PATHS[0]] = structuredClone(record(NODE_PATHS[0]));
    },
    (_node, browser) => {
      browser.coverage["backend/webrender/static/other.js"] = record(
        "backend/webrender/static/other.js",
      );
    },
  ]) {
    const { repoRoot, node, browser } = fixture();
    mutation(node, browser);
    assert.throws(
      () => unionCanonicalCoverage({ node, browser, repoRoot }),
      /lane source scope/u,
    );
  }
});

test("metadata, record shape, source binding, and counts fail closed", () => {
  const path = NODE_PATHS[0];
  const mutations = [
    (value) => { value.schema_version = 2; },
    (value) => { value.extra = true; },
    (value) => { value.coverage[path].path = NODE_PATHS[1]; },
    (value) => { value.coverage[path].extra = true; },
    (value) => { value.coverage[path].statementMap[0].end.column = 14; },
    (value) => { value.coverage[path].statementMap[1] = value.coverage[path].statementMap[0]; },
    (value) => { value.coverage[path].s[0] = -1; },
    (value) => { value.coverage[path].s[0] = 1.5; },
    (value) => { value.coverage[path].statementMap = []; },
    (value) => { value.coverage[path].s = []; },
    (value) => { delete value.coverage[path].s[1]; },
  ];

  for (const mutate of mutations) {
    const { repoRoot, node, browser } = fixture();
    mutate(node);
    assert.throws(
      () => unionCanonicalCoverage({ node, browser, repoRoot }),
      /invalid canonical JavaScript coverage union/u,
    );
  }
});

test("malformed envelopes and lane identities fail closed", () => {
  for (const mutate of [
    (node) => { node.coverage = null; },
    (node) => { node.coverage_lane = "browser-v8"; },
    (node, browser) => { browser.producer = node.producer; },
    (node, browser) => {
      const original = node.coverage;
      node.coverage = browser.coverage;
      browser.coverage = original;
    },
  ]) {
    const { repoRoot, node, browser } = fixture();
    mutate(node, browser);
    assert.throws(
      () => unionCanonicalCoverage({ node, browser, repoRoot }),
      /invalid canonical JavaScript coverage union/u,
    );
  }
});

test("candidate sources must remain canonical, current, executable UTF-8", () => {
  for (const [bytes, expected] of [
    [Buffer.from([0xff]), /source is not UTF-8/u],
    ["const = ;\n", /source cannot produce a canonical statement map/u],
    ["// comment only\n", /source cannot produce a canonical statement map/u],
    ["", /source size is out of bounds/u],
  ]) {
    const { repoRoot, node, browser } = fixture();
    writeFileSync(resolve(repoRoot, NODE_PATHS[0]), bytes);
    assert.throws(
      () => unionCanonicalCoverage({ node, browser, repoRoot }),
      expected,
    );
  }

  const linked = fixture();
  const path = resolve(linked.repoRoot, NODE_PATHS[0]);
  unlinkSync(path);
  symlinkSync(resolve(linked.repoRoot, NODE_PATHS[1]), path);
  assert.throws(
    () => unionCanonicalCoverage(linked),
    /source is not a canonical regular file/u,
  );
});

test("repository root must be an available directory", () => {
  const missing = fixture();
  assert.throws(
    () => unionCanonicalCoverage({
      node: missing.node,
      browser: missing.browser,
      repoRoot: resolve(missing.repoRoot, "missing"),
    }),
    /repository root is unavailable/u,
  );

  const regular = fixture();
  const regularFile = resolve(regular.repoRoot, "root-file");
  writeFileSync(regularFile, "not a directory", "utf8");
  assert.throws(
    () => unionCanonicalCoverage({
      node: regular.node,
      browser: regular.browser,
      repoRoot: regularFile,
    }),
    /repository root is not a directory/u,
  );
});
