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

function fixture() {
  const repoRoot = mkdtempSync(resolve(tmpdir(), "projection-coverage-union-cli-"));
  const sourcePath = "backend/webrender/static/client.js";
  mkdirSync(resolve(repoRoot, "backend/webrender/static"), { recursive: true });
  writeFileSync(resolve(repoRoot, sourcePath), "const alpha = 1;\nalpha;\n", "utf8");
  const record = {
    [sourcePath]: {
      path: sourcePath,
      statementMap: {
        0: { start: { line: 1, column: 0 }, end: { line: 1, column: 15 } },
        1: { start: { line: 2, column: 0 }, end: { line: 2, column: 5 } },
      },
      s: { 0: 1, 1: 0 },
    },
  };
  const nodeDocument = {
    ...NODE_COVERAGE_PRODUCER,
    coverage: record,
  };
  const browserDocument = {
    ...BROWSER_COVERAGE_PRODUCER,
    coverage: {
      [sourcePath]: { ...structuredClone(record[sourcePath]), s: { 0: 2, 1: 0 } },
    },
  };
  const node = resolve(repoRoot, "node.json");
  const browser = resolve(repoRoot, "browser.json");
  const output = resolve(repoRoot, "union.json");
  writeFileSync(node, `${JSON.stringify(nodeDocument)}\n`, "utf8");
  writeFileSync(browser, `${JSON.stringify(browserDocument)}\n`, "utf8");
  return { repoRoot, node, browser, output, sourcePath };
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
  const { repoRoot, node, browser, output, sourcePath } = fixture();
  const result = run([
    "--node", node,
    "--browser", browser,
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
  assert.deepEqual(document.coverage[sourcePath].s, { 0: 3, 1: 0 });
});

test("CLI rejects duplicated or swapped producer identities", () => {
  for (const mutation of ["node-twice", "browser-twice", "swapped"]) {
    const { repoRoot, node, browser, output } = fixture();
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
      "--repo-root", repoRoot,
      "--output", output,
    ]);
    assert.notEqual(result.status, 0, mutation);
    assert.match(result.stderr, /producer identity/u, mutation);
  }
});

test("CLI rejects duplicate inputs, malformed JSON, duplicate flags, and existing output", () => {
  for (const mutation of ["duplicate-input", "malformed", "duplicate-flag", "output-exists"]) {
    const { repoRoot, node, browser, output } = fixture();
    let arguments_ = [
      "--node", node,
      "--browser", browser,
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
  const { repoRoot, node, browser, output } = fixture();
  const source = readFileSync(browser, "utf8");
  writeFileSync(browser, source.replace("{", "{\"schema_version\":1,"), "utf8");

  const result = run([
    "--node", node,
    "--browser", browser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duplicate JSON object key/u);
});

test("CLI canonicalizes parent aliases and rejects non-file inputs", () => {
  const { repoRoot, browser, output } = fixture();
  const alias = resolve(repoRoot, "alias");
  symlinkSync(repoRoot, alias, "dir");
  const aliasedNode = resolve(alias, "node.json");
  let result = run([
    "--node", aliasedNode,
    "--browser", browser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.equal(result.status, 0, result.stderr);

  result = run([
    "--node", resolve(repoRoot, "missing.json"),
    "--browser", browser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /input is unavailable/u);

  result = run([
    "--node", repoRoot,
    "--browser", browser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /canonical regular file/u);
});

test("CLI rejects invalid UTF-8 and missing output parents", () => {
  const { repoRoot, node, browser, output } = fixture();
  writeFileSync(browser, Buffer.from([0xff]));
  let result = run([
    "--node", node,
    "--browser", browser,
    "--repo-root", repoRoot,
    "--output", output,
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /input is not UTF-8/u);

  const fresh = fixture();
  result = run([
    "--node", fresh.node,
    "--browser", fresh.browser,
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
    "--repo-root", duplicateFlag.repoRoot,
    "--output", duplicateFlag.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /duplicate argument --node/u);

  const unknownFlag = fixture();
  result = invokeMain([
    "--node", unknownFlag.node,
    "--browser", unknownFlag.browser,
    "--repo-root", unknownFlag.repoRoot,
    "--unknown", unknownFlag.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /expected --node/u);

  const duplicateInput = fixture();
  result = invokeMain([
    "--node", duplicateInput.node,
    "--browser", duplicateInput.node,
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
    "--repo-root", occupied.repoRoot,
    "--output", occupied.output,
  ]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /new writable file/u);
  assert.equal(readFileSync(occupied.output, "utf8"), "occupied");
});
