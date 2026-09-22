import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import { convertBrowserV8Reports } from "../browser-v8-cli.mjs";
import { BROWSER_COVERAGE_PRODUCER } from "../coverage-conversion.mjs";

const CLI = resolve(import.meta.dirname, "../browser-v8-cli.mjs");
const PATH = "backend/webrender/static/client.js";
const SOURCE = "const first = 1;\nconst second = 2;\nconst never = 3;\n";

function observation(line = 0, url = "https://candidate.invalid/static/client.js") {
  const lines = SOURCE.split("\n");
  const start = lines.slice(0, line).reduce((total, value) => total + value.length + 1, 0);
  return { url, scriptId: "123", source: SOURCE, functions: [{ functionName: "", isBlockCoverage: true,
    ranges: [{ startOffset: 0, endOffset: SOURCE.length, count: 0 },
      { startOffset: start, endOffset: start + lines[line].length, count: 1 }] }] };
}

function fixture(entries = [observation()]) {
  const root = mkdtempSync(resolve(tmpdir(), "astral-browser-v8-"));
  const source = resolve(root, PATH);
  mkdirSync(resolve(source, ".."), { recursive: true });
  writeFileSync(source, SOURCE);
  const input = resolve(root, "raw.json");
  writeFileSync(input, JSON.stringify(entries));
  return { root, source, input, inputs: [input], repoRoot: root };
}

test("unions independent browser observations without inventing an unobserved line", async () => {
  const options = fixture();
  const second = resolve(options.root, "second.json");
  writeFileSync(second, JSON.stringify([observation(1, "")]));
  const report = await convertBrowserV8Reports({ ...options, inputs: [...options.inputs, second] });
  assert.deepEqual(Object.fromEntries(Object.entries(report).filter(([key]) => key !== "coverage")), BROWSER_COVERAGE_PRODUCER);
  assert.deepEqual(Object.keys(report.coverage), [PATH]);
  assert.deepEqual(report.coverage[PATH].s, { 0: 1, 1: 1, 2: 0 });
});

test("multiple observations within one raw file preserve successful hits", async () => {
  const report = await convertBrowserV8Reports(fixture([observation(1), observation(0), observation(1)]));
  assert.deepEqual(report.coverage[PATH].s, { 0: 1, 1: 1, 2: 0 });
});

test("CLI writes the canonical browser producer atomically", () => {
  const options = fixture();
  const second = resolve(options.root, "second.json");
  writeFileSync(second, JSON.stringify([observation(1)]));
  const output = resolve(options.root, "canonical.json");
  writeFileSync(output, "prior evidence");
  const result = spawnSync(process.execPath, [CLI, "--repo-root", options.root, "--input", options.input,
    "--input", second, "--output", output], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(readFileSync(output, "utf8"));
  assert.equal(report.producer, BROWSER_COVERAGE_PRODUCER.producer);
  assert.deepEqual(report.coverage[PATH].s, { 0: 1, 1: 1, 2: 0 });
});

test("invalid CLI arguments fail before replacing prior evidence", () => {
  const options = fixture();
  const output = resolve(options.root, "canonical.json");
  for (const args of [[], ["--bogus", "value"], ["--input"], ["--input", ""],
    ["--repo-root", options.root, "--repo-root", options.root],
    ["--repo-root", options.root, "--input", options.input, "--output", output, "--input", options.input]]) {
    writeFileSync(output, "prior evidence");
    const result = spawnSync(process.execPath, [CLI, ...args], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(output, "utf8"), "prior evidence");
  }
});

test("denies missing, duplicate, empty, non-array and malformed raw inputs", async () => {
  const options = fixture();
  for (const inputs of [[], Array(33).fill(options.input), [options.input, options.input], [resolve(options.root, "absent")]]) {
    await assert.rejects(convertBrowserV8Reports({ ...options, inputs }));
  }
  for (const value of ["", "[]", "{}", "invalid JSON", "[null]"]) {
    writeFileSync(options.input, value);
    await assert.rejects(convertBrowserV8Reports(options));
  }
  await assert.rejects(convertBrowserV8Reports({ ...options, inputs: [options.root] }), /regular/u);
});

test("rejects stale source, Node reports and observations from other assets", async () => {
  const entries = [null, [], { ...observation(), source: SOURCE + "// old source" },
    { ...observation(), scriptId: "" }, { ...observation(), extra: true },
    ...["file:///repo/backend/webrender/static/client.js", "https://candidate.invalid/static/service-worker.js",
      "https://user:password@candidate.invalid/static/client.js", "https://candidate.invalid/static/client.js?x=1",
      "https://candidate.invalid/static/client.js#x", "not a URL"].map(url => observation(0, url))];
  for (const entry of entries) await assert.rejects(convertBrowserV8Reports(fixture([entry])));
});

test("range validation stays fail closed", async () => {
  const entry = observation();
  entry.functions[0].ranges[0].count = -1;
  await assert.rejects(convertBrowserV8Reports(fixture([entry])), /range/u);
});

test("source mutation while the pinned converter yields fails closed", async () => {
  const options = fixture();
  const converting = convertBrowserV8Reports(options);
  queueMicrotask(() => writeFileSync(options.source, SOURCE + "const changed = 4;\n"));
  await assert.rejects(converting, /changed during conversion/u);
});

test("invalid UTF-8 and excessive entry counts fail closed", async () => {
  const options = fixture();
  writeFileSync(options.input, Buffer.from([0xff]));
  await assert.rejects(convertBrowserV8Reports(options));
  writeFileSync(options.input, JSON.stringify(Array.from({ length: 1025 }, () => observation())));
  await assert.rejects(convertBrowserV8Reports(options), /entry count/u);
});

test("failed atomic rename cleans its temporary directory", () => {
  const options = fixture();
  const result = spawnSync(process.execPath, [CLI, "--repo-root", options.root, "--input", options.input,
    "--output", options.root], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
});
