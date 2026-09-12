/** Exact runner bytes with synthetic OS/process adapters; never release evidence. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createContext, SourceTextModule, SyntheticModule } from "node:vm";
import test from "node:test";

const ROOT = resolve(import.meta.dirname, "..");
const FILE = resolve(ROOT, "release-runner.mjs");
const SOURCE = readFileSync(FILE, "utf8");
const PIN = readFileSync(resolve(ROOT, "playwright-image.txt"), "utf8").trim();

async function execute(mutate = () => {}) {
  const argv = ["node", FILE, "--base-url", "https://staging.example", "--candidate-sha", "a".repeat(40),
    "--release-id", "release-unit-fixture", "--release-version", "0.4.0", "--staging-file", "/fixture/staging.json",
    "--output", "/fixture/web.json", "--coverage-output", "/fixture/raw.json",
    "--coverage-istanbul-output", "/fixture/browser.json", "--export-coverage-output", "/fixture/export.json"];
  const env = { ASTRAL_PLAYWRIGHT_IMAGE: PIN, npm_config_user_agent: "npm/11.16.0", ASTRAL_RELEASE_USERNAME: "synthetic",
    ASTRAL_RELEASE_PASSWORD: "synthetic", GITHUB_JOB: "unit", GITHUB_RUN_ATTEMPT: "1", GITHUB_RUN_ID: "1",
    GITHUB_WORKFLOW: "unit", RUNNER_ARCH: "X64", RUNNER_NAME: "unit", RUNNER_OS: "Linux", ASTRAL_RUNNER_ENVIRONMENT: "unit" };
  let errorText = "";
  let dispatch;
  const fixture = { argv, env, completed: { status: 0 }, platform: "linux" };
  mutate(fixture);
  const context = createContext({ process: { argv, env, platform: fixture.platform, versions: { node: "24.0.0" },
    execPath: "/fixture/node", stderr: { write: value => { errorText += value; } },
    exit: code => { throw Object.assign(new Error("unit process exit"), { exitCode: code }); } }, URL });
  const adapters = {
    "node:fs": { existsSync: () => true, readFileSync: file => {
      if (file.endsWith("playwright-image.txt")) return PIN;
      return readFileSync(file, "utf8");
    } },
    "node:path": { dirname, isAbsolute, join, resolve },
    "node:child_process": { spawnSync: (command, args, options) => {
      dispatch = { command, args: [...args], env: { ...options.env }, cwd: options.cwd };
      return fixture.completed;
    } },
  };
  const module = new SourceTextModule(SOURCE, { context, identifier: pathToFileURL(FILE).href,
    initializeImportMeta: meta => { meta.dirname = ROOT; } });
  await module.link(specifier => {
    const adapter = adapters[specifier];
    assert.ok(adapter, `unexpected runner import ${specifier}`);
    return new SyntheticModule(Object.keys(adapter), function () {
      for (const [name, value] of Object.entries(adapter)) this.setExport(name, value);
    }, { context });
  });
  let status;
  try { await module.evaluate(); } catch (error) {
    assert.equal(typeof error.exitCode, "number", String(error));
    status = error.exitCode;
  }
  return { status, errorText, dispatch };
}

test("runner launches staging and both actual browser checks with distinct coverage outputs", async () => {
  const result = await execute();
  assert.equal(result.status, 0, result.errorText);
  assert.deepEqual(result.dispatch.args.slice(1), ["test", "tests/release-060.spec.js", "tests/offline-worker-088.spec.js",
    "tests/native-export-088.spec.js", "--browser=chromium", "--workers=1", "--reporter=line"]);
  assert.equal(result.dispatch.env.ASTRAL_RELEASE_COVERAGE_ISTANBUL_OUTPUT, "/fixture/browser.json");
  assert.equal(result.dispatch.env.ASTRAL_EXPORT_COVERAGE_OUTPUT, "/fixture/export.json");
  assert.equal(result.dispatch.env.ASTRAL_RELEASE_CANDIDATE_SHA, "a".repeat(40));
});

test("runner rejects missing, relative, duplicate, or aliased export output before dispatch", async () => {
  for (const mutate of [
    fixture => { fixture.argv.splice(-2); },
    fixture => { fixture.argv[fixture.argv.length - 1] = "relative.json"; },
    fixture => { fixture.argv.push("--export-coverage-output", "/fixture/other.json"); },
    fixture => { fixture.argv[fixture.argv.length - 1] = "/fixture/../fixture/browser.json"; },
  ]) {
    const result = await execute(mutate);
    assert.equal(result.status, 2);
    assert.equal(result.dispatch, undefined);
    assert.match(result.errorText, /rejected/u);
  }
});

test("extra browser lanes cannot relax staging, container, or provider checks", async () => {
  for (const mutate of [
    fixture => { fixture.argv[3] = "http://localhost:8001"; },
    fixture => { fixture.platform = "darwin"; },
    fixture => { delete fixture.env.GITHUB_RUN_ID; },
    fixture => { delete fixture.env.ASTRAL_RELEASE_PASSWORD; },
    fixture => { fixture.env.ASTRAL_PLAYWRIGHT_IMAGE = PIN.replace(/.$/u, "x"); },
  ]) {
    const result = await execute(mutate);
    assert.equal(result.status, 2);
    assert.equal(result.dispatch, undefined);
  }
  const failed = await execute(fixture => { fixture.completed.status = 1; });
  assert.equal(failed.status, 1);
  const unavailable = await execute(fixture => { fixture.completed = { error: new Error("fixture unavailable") }; });
  assert.equal(unavailable.status, 2);
});
