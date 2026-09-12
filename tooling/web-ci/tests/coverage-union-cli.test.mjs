import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { main } from "../coverage-union-cli.mjs";
import {
  BROWSER_COVERAGE_PRODUCER,
  NODE_COVERAGE_PRODUCER,
} from "../coverage-conversion.mjs";
import { UNION_COVERAGE_PRODUCER } from "../coverage-union.mjs";

const TOOLING_ROOT = resolve(import.meta.dirname, "..");
const CLI = resolve(TOOLING_ROOT, "coverage-union-cli.mjs");
const NODE_PATHS = [
  "tooling/web-ci/coverage-conversion-cli.mjs",
  "tooling/web-ci/coverage-conversion.mjs",
  "tooling/web-ci/coverage-union-cli.mjs",
  "tooling/web-ci/coverage-union.mjs",
  "tooling/web-ci/eslint.config.mjs",
  "tooling/web-ci/product-isolation.mjs",
  "tooling/web-ci/release-runner.mjs",
];
const BROWSER_PATH = "backend/webrender/static/client.js";
const OFFLINE_PATHS = ["backend/webrender/static/offline-registration.js", "backend/webrender/static/service-worker.js"];
const EXPORT_PATHS = ["backend/webrender/static/canvas-export-host.js", "backend/webrender/static/canvas-export.js"];

function record(path, hits) {
  return {
    path,
    statementMap: {
      0: { start: { line: 1, column: 0 }, end: { line: 1, column: 15 } },
      1: { start: { line: 2, column: 0 }, end: { line: 2, column: 5 } },
    },
    s: hits,
  };
}

function fixture() {
  const repoRoot = mkdtempSync(resolve(tmpdir(), "projection-coverage-union-cli-"));
  for (const path of [...NODE_PATHS, BROWSER_PATH, ...OFFLINE_PATHS, ...EXPORT_PATHS]) {
    mkdirSync(resolve(repoRoot, path, ".."), { recursive: true });
    writeFileSync(resolve(repoRoot, path), "const alpha = 1;\nalpha;\n", "utf8");
  }
  const nodeDocument = {
    ...NODE_COVERAGE_PRODUCER,
    coverage: Object.fromEntries(
      NODE_PATHS.map((path) => [path, record(path, { 0: 1, 1: 0 })]),
    ),
  };
  const browserDocument = {
    ...BROWSER_COVERAGE_PRODUCER,
    coverage: {
      [BROWSER_PATH]: record(BROWSER_PATH, { 0: 2, 1: 0 }),
    },
  };
  const node = resolve(repoRoot, "node.json");
  const browser = resolve(repoRoot, "browser.json");
  const output = resolve(repoRoot, "union.json");
  const offlineNode = resolve(repoRoot, "offline.json");
  const exportBrowser = resolve(repoRoot, "export.json");
  for (const [file, identity, paths] of [
    [offlineNode, NODE_COVERAGE_PRODUCER, OFFLINE_PATHS],
    [exportBrowser, BROWSER_COVERAGE_PRODUCER, EXPORT_PATHS],
  ]) writeFileSync(file, JSON.stringify({ ...identity,
    coverage: Object.fromEntries(paths.map(path => [path, record(path, { 0: 1, 1: 0 })])),
  }));
  writeFileSync(node, `${JSON.stringify(nodeDocument)}\n`, "utf8");
  writeFileSync(browser, `${JSON.stringify(browserDocument)}\n`, "utf8");
  return { repoRoot, node, browser, offlineNode, exportBrowser, output, sourcePath: BROWSER_PATH };
}

function run(arguments_) {
  return spawnSync(process.execPath, [CLI, ...arguments_], {
    cwd: TOOLING_ROOT,
    encoding: "utf8",
  });
}

function invokeMain(arguments_) {
  let stderr = "";
  const originalWrite = process.stderr.write;
  process.stderr.write = (chunk) => {
    stderr += String(chunk);
    return true;
  };
  try {
    return { status: main(arguments_), stderr };
  } finally {
    process.stderr.write = originalWrite;
  }
}

test("CLI writes one deterministic Node-plus-browser envelope", () => {
  const { repoRoot, node, browser, offlineNode, exportBrowser, output, sourcePath } = fixture();
  const result = run([
    "--node", node,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.equal(result.status, 0, result.stderr);
  const document = JSON.parse(readFileSync(output, "utf8"));
  assert.deepEqual(
    Object.fromEntries(
      Object.entries(document).filter(([key]) => key !== "coverage"),
    ),
    UNION_COVERAGE_PRODUCER,
  );
  assert.deepEqual(document.coverage[sourcePath].s, { 0: 2, 1: 0 });
});

test("CLI rejects a relabeled semantic clone instead of doubling its hits", () => {
  const { repoRoot, node, browser, offlineNode, exportBrowser, output } = fixture();
  const nodeDocument = JSON.parse(readFileSync(node, "utf8"));
  writeFileSync(
    browser,
    `${JSON.stringify({
      ...BROWSER_COVERAGE_PRODUCER,
      coverage: nodeDocument.coverage,
    })}\n`,
    "utf8",
  );

  const result = run([
    "--node", node,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /semantically identical/u);
});

test("CLI rejects duplicated or swapped producer identities", () => {
  for (const mutation of ["node-twice", "browser-twice", "swapped"]) {
    const { repoRoot, node, browser, offlineNode, exportBrowser, output } = fixture();
    const nodeBytes = readFileSync(node);
    const browserBytes = readFileSync(browser);
    if (mutation === "node-twice") writeFileSync(browser, nodeBytes);
    if (mutation === "browser-twice") writeFileSync(node, browserBytes);
    if (mutation === "swapped") {
      writeFileSync(node, browserBytes);
      writeFileSync(browser, nodeBytes);
    }
    const result = run([
      "--node", node,
      "--browser", browser,
      "--offline-node", offlineNode,
      "--export-browser", exportBrowser,
      "--repo-root", repoRoot,
      "--output", output,
    ]);
    assert.notEqual(result.status, 0, mutation);
    assert.match(result.stderr, /producer identity/u, mutation);
  }
});

test("CLI rejects duplicate inputs, malformed JSON, duplicate flags, and existing output", () => {
  for (const mutation of ["duplicate-input", "malformed", "duplicate-flag", "output-exists"]) {
    const { repoRoot, node, browser, offlineNode, exportBrowser, output } = fixture();
    let arguments_ = [
      "--node", node,
      "--browser", browser,
      "--offline-node", offlineNode,
      "--export-browser", exportBrowser,
      "--repo-root", repoRoot,
      "--output", output,
    ];
    if (mutation === "duplicate-input") arguments_[3] = node;
    if (mutation === "malformed") writeFileSync(browser, "{\"coverage\":", "utf8");
    if (mutation === "duplicate-flag") arguments_ = ["--node", node, ...arguments_];
    if (mutation === "output-exists") writeFileSync(output, "occupied", "utf8");

    const result = run(arguments_);
    assert.notEqual(result.status, 0, mutation);
    assert.match(result.stderr, /coverage union failed/u, mutation);
  }
});

test("CLI rejects duplicate JSON keys instead of accepting last-key-wins input", () => {
  const { repoRoot, node, browser, offlineNode, exportBrowser, output } = fixture();
  const source = readFileSync(browser, "utf8");
  writeFileSync(browser, source.replace("{", "{\"schema_version\":1,"), "utf8");

  const result = run([
    "--node", node,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duplicate JSON object key/u);
});

test("CLI canonicalizes parent aliases and rejects non-file inputs", () => {
  const { repoRoot, browser, offlineNode, exportBrowser, output } = fixture();
  const alias = resolve(repoRoot, "alias");
  symlinkSync(repoRoot, alias, "dir");
  const aliasedNode = resolve(alias, "node.json");
  let result = run([
    "--node", aliasedNode,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.equal(result.status, 0, result.stderr);

  result = run([
    "--node", resolve(repoRoot, "missing.json"),
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /input is unavailable/u);

  result = run([
    "--node", repoRoot,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /canonical regular file/u);
});

test("CLI rejects invalid UTF-8 and missing output parents", () => {
  const { repoRoot, node, browser, offlineNode, exportBrowser, output } = fixture();
  writeFileSync(browser, Buffer.from([0xff]));
  let result = run([
    "--node", node,
    "--browser", browser,
    "--offline-node", offlineNode,
    "--export-browser", exportBrowser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /input is not UTF-8/u);

  const fresh = fixture();
  result = run([
    "--node", fresh.node,
    "--browser", fresh.browser,
    "--offline-node", fresh.offlineNode,
    "--export-browser", fresh.exportBrowser,
    "--repo-root", fresh.repoRoot,
    "--output", resolve(fresh.repoRoot, "missing", "union.json"),
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /coverage union failed/u);
});

test("exported main covers success and bounded argument/input error behavior", () => {
  const valid = fixture();
  let result = invokeMain([
    "--node", valid.node,
    "--browser", valid.browser,
    "--offline-node", valid.offlineNode,
    "--export-browser", valid.exportBrowser,
    "--repo-root", valid.repoRoot,
    "--output", valid.output,
  ]);
  assert.equal(result.status, 0, result.stderr);

  result = invokeMain([]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /expected --node/u);

  const duplicateFlag = fixture();
  result = invokeMain([
    "--node", duplicateFlag.node,
    "--node", duplicateFlag.browser,
    "--offline-node", duplicateFlag.offlineNode,
    "--export-browser", duplicateFlag.exportBrowser,
    "--repo-root", duplicateFlag.repoRoot,
    "--output", duplicateFlag.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /duplicate argument --node/u);

  const unknownFlag = fixture();
  result = invokeMain([
    "--node", unknownFlag.node,
    "--browser", unknownFlag.browser,
    "--offline-node", unknownFlag.offlineNode,
    "--export-browser", unknownFlag.exportBrowser,
    "--repo-root", unknownFlag.repoRoot,
    "--unknown", unknownFlag.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /expected --node/u);

  const duplicateInput = fixture();
  result = invokeMain([
    "--node", duplicateInput.node,
    "--browser", duplicateInput.node,
    "--offline-node", duplicateInput.offlineNode,
    "--export-browser", duplicateInput.exportBrowser,
    "--repo-root", duplicateInput.repoRoot,
    "--output", duplicateInput.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /must be distinct/u);
});

test("exported main rejects empty, invalid, duplicate-key, and unavailable inputs", () => {
  for (const mutation of ["empty", "invalid-json", "duplicate-key", "missing", "directory"]) {
    const values = fixture();
    if (mutation === "empty") writeFileSync(values.node, "", "utf8");
    if (mutation === "invalid-json") writeFileSync(values.node, "{", "utf8");
    if (mutation === "duplicate-key") {
      const source = readFileSync(values.node, "utf8");
      writeFileSync(values.node, source.replace("{", "{\"schema_version\":1,"), "utf8");
    }
    if (mutation === "missing") values.node = resolve(values.repoRoot, "missing.json");
    if (mutation === "directory") values.node = values.repoRoot;

    const result = invokeMain([
      "--node", values.node,
      "--browser", values.browser,
      "--offline-node", values.offlineNode,
      "--export-browser", values.exportBrowser,
      "--repo-root", values.repoRoot,
      "--output", values.output,
    ]);
    assert.equal(result.status, 2, mutation);
    assert.match(result.stderr, /coverage union failed/u, mutation);
  }
});

test("exported main refuses invalid UTF-8 and output replacement", () => {
  const invalidUtf8 = fixture();
  writeFileSync(invalidUtf8.browser, Buffer.from([0xff]));
  let result = invokeMain([
    "--node", invalidUtf8.node,
    "--browser", invalidUtf8.browser,
    "--offline-node", invalidUtf8.offlineNode,
    "--export-browser", invalidUtf8.exportBrowser,
    "--repo-root", invalidUtf8.repoRoot,
    "--output", invalidUtf8.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /not UTF-8/u);

  const occupied = fixture();
  writeFileSync(occupied.output, "occupied", "utf8");
  result = invokeMain([
    "--node", occupied.node,
    "--browser", occupied.browser,
    "--offline-node", occupied.offlineNode,
    "--export-browser", occupied.exportBrowser,
    "--repo-root", occupied.repoRoot,
    "--output", occupied.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /new writable file/u);
  assert.equal(readFileSync(occupied.output, "utf8"), "occupied");
});


test("CLI refuses either missing feature lane and source-identical lane aliases", () => {
  for (const missing of ["--offline-node", "--export-browser"]) {
    const value = fixture();
    const args = ["--node", value.node, "--browser", value.browser,
      "--offline-node", value.offlineNode, "--export-browser", value.exportBrowser,
      "--repo-root", value.repoRoot, "--output", value.output];
    args.splice(args.indexOf(missing), 2);
    const result = invokeMain(args);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /expected --node/u);
  }
  const value = fixture();
  const alias = resolve(value.repoRoot, "export-alias.json");
  symlinkSync(value.exportBrowser, alias);
  const result = invokeMain(["--node", value.node, "--browser", value.browser,
    "--offline-node", alias, "--export-browser", value.exportBrowser,
    "--repo-root", value.repoRoot, "--output", value.output]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /must be distinct/u);
});
