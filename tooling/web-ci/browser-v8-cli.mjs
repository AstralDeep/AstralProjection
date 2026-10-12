// CLI converting browser V8 coverage observations to the canonical format via
// coverage-conversion.mjs, for coverage-union.mjs and its tests.

import { lstatSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TextDecoder } from "node:util";

import { BROWSER_COVERAGE_PRODUCER, convertPlaywrightV8Coverage } from "./coverage-conversion.mjs";

const SOURCE_PATHS = new Map([
  ["/static/client.js", "backend/webrender/static/client.js"],
  ["/static/mesh-custody.js", "backend/webrender/static/mesh-custody.js"],
  ["/static/mesh-enrollment.js", "backend/webrender/static/mesh-enrollment.js"],
]);
const MAX_REPORT_BYTES = 64 * 1024 * 1024;
const MAX_TOTAL_BYTES = 256 * 1024 * 1024;
const MAX_ENTRIES = 1024;

function fail(message) {
  throw new TypeError(`invalid browser V8 coverage reports: ${message}`);
}

function readRegular(path, maximum) {
  const info = lstatSync(path);
  if (!info.isFile() || info.size <= 0 || info.size > maximum) fail("file is not a bounded regular file");
  return new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(path));
}

function browserEntry(entry) {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)
      || Object.keys(entry).sort().join(",") !== "functions,scriptId,source,url"
      || typeof entry.scriptId !== "string" || !entry.scriptId || typeof entry.source !== "string") {
    fail("entry shape or candidate source does not match");
  }
  if (entry.url === "") return SOURCE_PATHS.get("/static/client.js");
  let url;
  try { url = new URL(entry.url); } catch { fail("entry has no browser asset URL"); }
  if (!["http:", "https:"].includes(url.protocol) || !SOURCE_PATHS.has(url.pathname)
      || url.username || url.password || url.search || url.hash) fail("entry belongs to another coverage lane");
  return SOURCE_PATHS.get(url.pathname);
}

export async function convertBrowserV8Reports({ inputs, repoRoot }) {
  if (!Array.isArray(inputs) || inputs.length === 0 || inputs.length > 32) fail("input count is empty or excessive");
  const root = realpathSync(repoRoot);
  const sources = new Map();
  const seen = new Set();
  let totalBytes = 0;
  let count = 0;
  const records = new Map();
  for (const input of inputs) {
    const canonical = realpathSync(input);
    if (seen.has(canonical)) fail("duplicate input report");
    seen.add(canonical);
    const raw = readRegular(input, MAX_REPORT_BYTES);
    totalBytes += Buffer.byteLength(raw, "utf8");
    if (totalBytes > MAX_TOTAL_BYTES) fail("total report size exceeds bound");
    const entries = JSON.parse(raw);
    if (!Array.isArray(entries) || entries.length === 0) fail("report must contain a nonempty raw browser array");
    for (const entry of entries) {
      if (++count > MAX_ENTRIES) fail("entry count exceeds bound");
      const path = browserEntry(entry);
      const sourceFile = resolve(root, path);
      if (realpathSync(sourceFile) !== sourceFile) fail("candidate source must not traverse a symbolic link");
      if (!sources.has(path)) sources.set(path, readRegular(sourceFile, 4 * 1024 * 1024));
      const source = sources.get(path);
      if (entry.source !== source) fail("entry shape or candidate source does not match");
      const document = await convertPlaywrightV8Coverage([entry], () => path);
      if (readRegular(sourceFile, 4 * 1024 * 1024) !== source) fail("candidate source changed during conversion");
      const observed = document.coverage[path];
      const record = records.get(path);
      if (!record) {
        records.set(path, observed);
      } else {
        if (JSON.stringify(record.statementMap) !== JSON.stringify(observed.statementMap)) fail("inconsistent statement map");
        for (const [id, hits] of Object.entries(observed.s)) record.s[id] = record.s[id] > 0 || hits > 0 ? 1 : 0;
      }
    }
  }
  for (const [path, source] of sources) {
    if (readRegular(resolve(root, path), 4 * 1024 * 1024) !== source) fail("candidate source changed during conversion");
  }
  return { ...BROWSER_COVERAGE_PRODUCER, coverage: Object.fromEntries([...records].sort(([left], [right]) => left.localeCompare(right))) };
}

function argumentsFrom(argv) {
  const values = { inputs: [] };
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--input", "--repo-root", "--output"].includes(flag) || typeof value !== "string" || !value) fail("invalid CLI arguments");
    if (flag === "--input") values.inputs.push(value);
    else if (Object.hasOwn(values, flag)) fail("duplicate CLI argument");
    else values[flag] = value;
  }
  if (!values.inputs.length || !values["--repo-root"] || !values["--output"]) fail("missing CLI arguments");
  return values;
}

async function main(argv) {
  const values = argumentsFrom(argv);
  const report = await convertBrowserV8Reports({ inputs: values.inputs, repoRoot: values["--repo-root"] });
  const output = resolve(values["--output"]);
  const temporary = mkdtempSync(resolve(dirname(output), ".browser-coverage-"));
  try {
    const path = resolve(temporary, "report.json");
    writeFileSync(path, JSON.stringify(report) + "\n", { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(path, output);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
