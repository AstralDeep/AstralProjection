import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { convertNodeV8Directory } from "../coverage-conversion-cli.mjs";
import { NODE_COVERAGE_PRODUCER } from "../coverage-conversion.mjs";

const TOOLING_ROOT = resolve(import.meta.dirname, "..");
const REPO_ROOT = resolve(TOOLING_ROOT, "../..");
const CLI = resolve(TOOLING_ROOT, "coverage-conversion-cli.mjs");

function run(arguments_, options = {}) {
  const result = spawnSync(process.execPath, arguments_, {
    cwd: TOOLING_ROOT,
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `command failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
}

test("two-pass Node coverage maps the converter and its CLI", () => {
  const directory = mkdtempSync(resolve(tmpdir(), "astraldeep-node-v8-"));
  const interim = resolve(directory, "interim.json");
  const output = resolve(directory, "canonical.json");
  const coverageEnvironment = {
    ...process.env,
    NODE_V8_COVERAGE: directory,
  };
  // A nested test runner must not inherit its parent's private child marker.
  delete coverageEnvironment.NODE_TEST_CONTEXT;

  run(["--test", "tests/coverage-conversion.test.mjs"], {
    env: coverageEnvironment,
  });
  assert.ok(
    readdirSync(directory).some((name) => name.startsWith("coverage-")),
    `NODE_V8_COVERAGE did not emit a report: ${readdirSync(directory).join(", ")}`,
  );
  // This first conversion flushes coverage for the CLI itself on process exit.
  run(
    [
      CLI,
      "--node-v8-directory",
      directory,
      "--repo-root",
      REPO_ROOT,
      "--output",
      interim,
    ],
    { env: coverageEnvironment },
  );
  // The second conversion sees both the tests' and the first CLI run's reports.
  run([
    CLI,
    "--node-v8-directory",
    directory,
    "--repo-root",
    REPO_ROOT,
    "--output",
    output,
  ]);

  const document = JSON.parse(readFileSync(output, "utf8"));
  assert.deepEqual(
    Object.fromEntries(
      Object.entries(document).filter(([key]) => key !== "coverage"),
    ),
    NODE_COVERAGE_PRODUCER,
  );
  assert.deepEqual(Object.keys(document.coverage).sort(), [
    "tooling/web-ci/coverage-conversion-cli.mjs",
    "tooling/web-ci/coverage-conversion.mjs",
  ]);
  for (const record of Object.values(document.coverage)) {
    assert.ok(Object.keys(record.statementMap).length > 0);
    assert.deepEqual(Object.keys(record.statementMap), Object.keys(record.s));
  }
});


function observedDecisionFixture() {
  const root = mkdtempSync(resolve(tmpdir(), "astral-observed-ranges-"));
  const path = "tooling/web-ci/decision.mjs";
  const source = [
    "function decide() {",
    "  if (process.env.MODE === 'deny') {",
    "    throw new Error('denied');",
    "  }",
    "  const result = 'golden';",
    "  if (process.env.MODE === 'never') {",
    "    process.stdout.write('unobserved');",
    "  }",
    "  return result;",
    "}",
    "try { process.stdout.write(decide()); } catch { process.stdout.write('denied'); }",
    "",
  ].join("\n");
  const file = resolve(root, path);
  mkdirSync(resolve(file, ".."), { recursive: true });
  writeFileSync(file, source);
  const directory = resolve(root, "raw");
  mkdirSync(directory);
  for (const [mode, output] of [["success", "golden"], ["deny", "denied"]]) {
    const result = spawnSync(process.execPath, [file], {
      env: { ...process.env, NODE_V8_COVERAGE: directory, MODE: mode }, encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, output);
  }
  return { root, path, source, file, directory };
}

test("separate real V8 success and denial observations preserve covered and never-executed lines", async () => {
  const { root, path, directory } = observedDecisionFixture();
  const report = await convertNodeV8Directory({ directory, repoRoot: root });
  assert.equal(report.producer_version, 3);
  const record = report.coverage[path];
  const byLine = Object.fromEntries(Object.entries(record.statementMap)
    .map(([id, span]) => [span.start.line, record.s[id]]));
  assert.equal(byLine[3], 1, "real denial executed the throw");
  assert.equal(byLine[5], 1, "real success executed the result assignment");
  assert.equal(byLine[9], 1, "real success returned the result");
  assert.equal(byLine[7], 0, "union cannot invent the unobserved third path");
  assert.equal(Object.keys(report.coverage).length, 1);
});

test("per-observation conversion still rejects malformed real V8 counts", async () => {
  for (const count of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1]) {
    const { root, path, directory } = observedDecisionFixture();
    const file = resolve(directory, readdirSync(directory).sort()[0]);
    const raw = JSON.parse(readFileSync(file));
    const entry = raw.result.find(value => value.url.endsWith(path));
    entry.functions[0].ranges[0].count = count;
    writeFileSync(file, JSON.stringify(raw));
    await assert.rejects(convertNodeV8Directory({ directory, repoRoot: root }), /range/u);
  }
});

test("source replacement between awaited observations fails closed", async () => {
  const { root, file, source, directory } = observedDecisionFixture();
  const converting = convertNodeV8Directory({ directory, repoRoot: root });
  // The pinned converter yields while loading its exact source observation.
  queueMicrotask(() => writeFileSync(file, source + "process.stdout.write('changed');\n"));
  await assert.rejects(converting, /source changed between reports/u);
});
