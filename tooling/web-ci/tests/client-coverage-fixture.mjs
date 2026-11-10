// Collects exact-source browser observations from the contract suites and writes bounded, lossless reports
// holding each source once per record, with its distinct per-test executions. Canonical validation and
// conversion remain in browser-v8-cli.mjs.

import { mkdir, readFile, writeFile, mkdtemp, readdir, lstat, unlink, rename, rm } from "node:fs/promises";
import { resolve } from "node:path";

const CLIENT = resolve(import.meta.dirname, "../../../backend/webrender/static/client.js");
const SOURCE = await readFile(CLIENT, "utf8");
const REPORT_BYTES = 32 * 1024 * 1024;

export function clientCoverageRecords(observations, maximum = REPORT_BYTES) {
  const groups = new Map();
  for (const observation of observations) {
    if (observation === null || typeof observation !== "object" || typeof observation.url !== "string"
        || typeof observation.source !== "string" || typeof observation.scriptId !== "string") {
      throw new TypeError("Invalid browser coverage observation");
    }
    const key = JSON.stringify([observation.url, observation.source]);
    if (!groups.has(key)) groups.set(key, {url: observation.url, source: observation.source, seen: new Set(), executions: []});
    const group = groups.get(key);
    const functions = JSON.stringify(observation.functions);
    if (typeof functions !== "string") throw new TypeError("Invalid browser coverage observation");
    // Identical executions cannot change the union of observed lines.
    if (group.seen.has(functions)) continue;
    group.seen.add(functions);
    group.executions.push(JSON.stringify({scriptId: observation.scriptId, functions: observation.functions}));
  }
  const records = [];
  for (const {url, source, executions} of groups.values()) {
    const prefix = JSON.stringify({url, source}).slice(0, -1) + ',"executions":[';
    // Each record must fit in one report chunk: "[" + prefix + executions + "]}" + "]\n".
    const empty = Buffer.byteLength(prefix, "utf8") + 5;
    let current = [];
    let size = empty;
    for (const execution of executions) {
      const length = Buffer.byteLength(execution, "utf8");
      if (empty + length > maximum) throw new TypeError("Browser coverage observation exceeds output bound");
      if (current.length && size + 1 + length > maximum) {
        records.push(prefix + current.join(",") + "]}");
        current = [];
        size = empty;
      }
      size += length + (current.length ? 1 : 0);
      current.push(execution);
    }
    records.push(prefix + current.join(",") + "]}");
  }
  return records;
}

export async function writeClientCoverageReports(directory, name, observations, maximum = REPORT_BYTES) {
  if (typeof name !== "string" || !/^[a-z0-9][a-z0-9-]{0,80}$/u.test(name) || !Array.isArray(observations)
      || observations.length === 0 || observations.length > 1024
      || !Number.isSafeInteger(maximum) || maximum < 3 || maximum > REPORT_BYTES) {
    throw new TypeError("Invalid bounded browser coverage output");
  }
  const chunks = [];
  let current = [];
  let bytes = 3;
  for (const encoded of clientCoverageRecords(observations, maximum)) {
    const size = Buffer.byteLength(encoded, "utf8");
    if (bytes + size + (current.length ? 1 : 0) > maximum) {
      chunks.push("[" + current.join(",") + "]\n");
      current = [];
      bytes = 3;
    }
    bytes += size + (current.length ? 1 : 0);
    current.push(encoded);
  }
  chunks.push("[" + current.join(",") + "]\n");
  if (chunks.length > 32 || chunks.reduce((total, chunk) => total + Buffer.byteLength(chunk), 0) > 256 * 1024 * 1024) {
    throw new TypeError("Browser coverage output exceeds total bound");
  }
  const root = resolve(directory);
  await mkdir(root, {recursive: true});
  const pattern = new RegExp("^" + name + "(?:\\.part-[0-9]{3})?\\.json$", "u");
  const prior = (await readdir(root)).filter(path => pattern.test(path));
  for (const path of prior) {
    if (!(await lstat(resolve(root, path))).isFile()) throw new TypeError("Browser coverage output is not regular");
  }
  const staging = await mkdtemp(resolve(root, ".client-coverage-" + name + "-"));
  const names = chunks.map((_chunk, index) => chunks.length === 1 ? name + ".json"
    : name + ".part-" + String(index).padStart(3, "0") + ".json");
  try {
    for (const [index, chunk] of chunks.entries()) {
      await writeFile(resolve(staging, names[index]), chunk, {encoding: "utf8", mode: 0o600, flag: "wx"});
    }
    for (const path of prior) await unlink(resolve(root, path));
    for (const name of names) await rename(resolve(staging, name), resolve(root, name));
  } finally {
    await rm(staging, {recursive: true, force: true});
  }
  return names.map(name => resolve(root, name));
}

export function collectClientCoverage(test, name) {
  const directory = process.env.ASTRAL_ALL_CLIENT_COVERAGE_DIR;
  const observations = [];
  test.beforeEach(async ({ page, browserName }) => {
    if (!directory) return;
    if (browserName !== "chromium") throw new Error("Client coverage requires pinned Chromium");
    await page.coverage.startJSCoverage({ reportAnonymousScripts: true, resetOnNavigation: false });
  });
  test.afterEach(async ({ page }) => {
    if (!directory) return;
    for (const entry of await page.coverage.stopJSCoverage()) {
      if (entry.source === SOURCE) observations.push(entry);
    }
  });
  test.afterAll(async () => {
    if (!directory) return;
    if (await readFile(CLIENT, "utf8") !== SOURCE || !observations.length) {
      throw new Error("Missing or changed exact client.js browser coverage");
    }
    await writeClientCoverageReports(directory, name, observations);
  });
}
