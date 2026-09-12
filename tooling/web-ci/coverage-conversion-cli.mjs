import {
  lstatSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  convertNodeV8Coverage,
  NODE_COVERAGE_PRODUCER,
} from "./coverage-conversion.mjs";

const MAX_REPORTS = 256;
const MAX_REPORT_BYTES = 16 * 1024 * 1024;
const MAX_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_SOURCE_BYTES = 4 * 1024 * 1024;

function fail(message) {
  throw new TypeError(`invalid Node V8 coverage directory: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function argumentsFrom(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (
      !["--node-v8-directory", "--repo-root", "--output"].includes(flag) ||
      typeof value !== "string"
    ) {
      fail("expected --node-v8-directory, --repo-root, and --output values");
    }
    if (Object.hasOwn(values, flag)) {
      fail(`duplicate argument ${flag}`);
    }
    values[flag] = value;
  }
  if (Object.keys(values).length !== 3) {
    fail("expected --node-v8-directory, --repo-root, and --output values");
  }
  return values;
}

function isMaintainedSource(path) {
  const parts = path.split("/");
  if (
    parts.some((part) =>
      ["tests", "test", "node_modules", "build", "dist"].includes(
        part.toLowerCase(),
      ),
    )
  ) {
    return false;
  }
  if (path.startsWith("backend/webrender/")) {
    return (
      path.endsWith(".js") &&
      !path.includes("/static/vendor/") &&
      !path.endsWith(".min.js")
    );
  }
  return (
    path.startsWith("tooling/web-ci/") &&
    (path.endsWith(".js") || path.endsWith(".mjs"))
  );
}

function canonicalSource(url, repoRoot) {
  if (typeof url !== "string" || !url.startsWith("file://")) {
    return null;
  }
  let sourcePath;
  try {
    sourcePath = realpathSync(fileURLToPath(url));
  } catch {
    return null;
  }
  const prefix = `${repoRoot}${sep}`;
  if (!sourcePath.startsWith(prefix) || !lstatSync(sourcePath).isFile()) {
    return null;
  }
  const repoPath = relative(repoRoot, sourcePath).split(sep).join("/");
  return isMaintainedSource(repoPath) ? { repoPath, sourcePath } : null;
}

function readSource(sourcePath) {
  const size = statSync(sourcePath).size;
  if (size <= 0 || size > MAX_SOURCE_BYTES) {
    fail(`source has invalid size: ${sourcePath}`);
  }
  return readFileSync(sourcePath, "utf8");
}

async function mergeEntry(entries, source, repoPath, rawEntry) {
  const prior = entries.get(repoPath);
  if (prior && prior.source !== source) fail(`source changed between reports: ${repoPath}`);
  // V8 ranges belong to one execution. Combining ranges first lets a narrow
  // unexecuted branch from one run erase a broader successful observation.
  // Apply the pinned token/line converter independently, then union only hits.
  const document = await convertNodeV8Coverage(
    [{ source, functions: rawEntry.functions }], () => repoPath,
  );
  const observation = document.coverage[repoPath];
  if (!prior) {
    entries.set(repoPath, { source, record: observation });
    return;
  }
  if (JSON.stringify(prior.record.statementMap) !== JSON.stringify(observation.statementMap)) {
    fail(`source statement map changed between reports: ${repoPath}`);
  }
  for (const [id, count] of Object.entries(observation.s)) {
    prior.record.s[id] = prior.record.s[id] > 0 || count > 0 ? 1 : 0;
  }
}

async function readEntries(directory, repoRoot) {
  const names = readdirSync(directory)
    .filter((name) => /^coverage-[0-9]+-[0-9]+-[0-9]+\.json$/u.test(name))
    .sort();
  if (names.length === 0 || names.length > MAX_REPORTS) {
    fail("report count is empty or exceeds the bounded maximum");
  }
  let totalBytes = 0;
  const entries = new Map();
  for (const name of names) {
    const reportPath = resolve(directory, name);
    const size = statSync(reportPath).size;
    totalBytes += size;
    if (size <= 0 || size > MAX_REPORT_BYTES || totalBytes > MAX_TOTAL_BYTES) {
      fail(`report size is invalid: ${name}`);
    }
    let document;
    try {
      document = JSON.parse(readFileSync(reportPath, "utf8"));
    } catch (error) {
      fail(`report is not valid JSON: ${name}: ${error.message}`);
    }
    if (!isObject(document) || !Array.isArray(document.result)) {
      fail(`report lacks a result array: ${name}`);
    }
    for (const rawEntry of document.result) {
      if (!isObject(rawEntry)) {
        fail(`report contains a non-object entry: ${name}`);
      }
      const canonical = canonicalSource(rawEntry.url, repoRoot);
      if (canonical === null) {
        continue;
      }
      const source = readSource(canonical.sourcePath);
      await mergeEntry(entries, source, canonical.repoPath, rawEntry);
    }
  }
  if (entries.size === 0) {
    fail("reports contain no maintained repository JavaScript");
  }
  return {
    ...NODE_COVERAGE_PRODUCER,
    coverage: Object.fromEntries([...entries].sort(([left], [right]) => left.localeCompare(right))
      .map(([path, value]) => [path, value.record])),
  };
}

/** Convert a bounded NODE_V8_COVERAGE directory to the canonical envelope. */
export async function convertNodeV8Directory({ directory, repoRoot }) {
  const canonicalRoot = realpathSync(repoRoot);
  const canonicalDirectory = realpathSync(directory);
  return readEntries(canonicalDirectory, canonicalRoot);
}

function writeAtomically(output, document) {
  const outputPath = resolve(output);
  const temporaryDirectory = mkdtempSync(resolve(dirname(outputPath), ".coverage-"));
  const temporaryPath = resolve(temporaryDirectory, "report.json");
  try {
    writeFileSync(temporaryPath, `${JSON.stringify(document, null, 2)}\n`, {
      encoding: "utf8",
      flag: "wx",
    });
    renameSync(temporaryPath, outputPath);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

async function main(argv) {
  const values = argumentsFrom(argv);
  const document = await convertNodeV8Directory({
    directory: values["--node-v8-directory"],
    repoRoot: values["--repo-root"],
  });
  writeAtomically(values["--output"], document);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main(process.argv.slice(2));
}
