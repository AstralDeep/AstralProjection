import {
  lstatSync,
  readFileSync,
  realpathSync,
  statSync,
} from "node:fs";
import { relative, resolve, sep } from "node:path";
import { TextDecoder } from "node:util";

import { parse } from "espree";

import {
  BROWSER_COVERAGE_PRODUCER,
  NODE_COVERAGE_PRODUCER,
} from "./coverage-conversion.mjs";

export {
  BROWSER_COVERAGE_PRODUCER,
  NODE_COVERAGE_PRODUCER,
};

export const UNION_COVERAGE_PRODUCER = Object.freeze({
  schema_version: 1,
  producer_version: 2,
  v8_to_istanbul_version: "9.3.0",
  espree_version: "11.2.0",
  producer: "astralprojection-node-browser-union",
  coverage_lane: "node-browser-union",
});

const MAX_SOURCE_BYTES = 4 * 1024 * 1024;
const MAX_SOURCE_PATH_BYTES = 16 * 1024;
const MAX_SOURCES = 4096;
const MAX_STATEMENTS = 1_000_000;
const PRODUCER_KEYS = Object.keys(UNION_COVERAGE_PRODUCER);
const ENVELOPE_KEYS = [...PRODUCER_KEYS, "coverage"];

function fail(message) {
  throw new TypeError(`invalid canonical JavaScript coverage union: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(value, expected) {
  return (
    isObject(value) &&
    Object.keys(value).sort().join("\u0000") === [...expected].sort().join("\u0000")
  );
}

function isMaintainedSourcePath(path) {
  if (
    typeof path !== "string" ||
    path.length === 0 ||
    Buffer.byteLength(path, "utf8") > MAX_SOURCE_PATH_BYTES ||
    path.startsWith("/") ||
    path.includes("\\") ||
    path.split("/").some((part) =>
      ["", ".", "..", "test", "tests", "node_modules", "build", "dist"].includes(
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

function parsedTokens(source) {
  const options = {
    ecmaVersion: "latest",
    loc: true,
    range: true,
    tokens: true,
  };
  try {
    return parse(source, { ...options, sourceType: "module" }).tokens;
  } catch (moduleError) {
    try {
      return parse(source, { ...options, sourceType: "script" }).tokens;
    } catch (scriptError) {
      fail(
        `candidate source is neither a module nor script: ${moduleError.message}; ${scriptError.message}`,
      );
    }
  }
}

function tokenSegments(token) {
  const finalLine =
    token.loc.end.line > token.loc.start.line && token.loc.end.column === 0
      ? token.loc.end.line - 1
      : token.loc.end.line;
  const segments = [];
  for (let line = token.loc.start.line; line <= finalLine; line += 1) {
    segments.push({
      line,
      startColumn: line === token.loc.start.line ? token.loc.start.column : 0,
      endColumn:
        line === token.loc.end.line
          ? token.loc.end.column
          : Number.MAX_SAFE_INTEGER,
    });
  }
  return segments;
}

function executableLineStatementMap(source) {
  const tokens = parsedTokens(source).filter((token) => token.type !== "Punctuator");
  if (tokens.length === 0) {
    fail("candidate source has no executable tokens");
  }
  const lines = new Map();
  for (const token of tokens) {
    for (const segment of tokenSegments(token)) {
      const record = lines.get(segment.line) ?? {
        startColumn: segment.startColumn,
        endColumn: segment.endColumn,
      };
      record.startColumn = Math.min(record.startColumn, segment.startColumn);
      record.endColumn = Math.max(record.endColumn, segment.endColumn);
      lines.set(segment.line, record);
    }
  }
  const statementMap = {};
  for (const [index, [line, columns]] of [...lines.entries()]
    .sort(([left], [right]) => left - right)
    .entries()) {
    statementMap[String(index)] = {
      start: { line, column: columns.startColumn },
      end: {
        line,
        column: Number.isSafeInteger(columns.endColumn) ? columns.endColumn : 0,
      },
    };
  }
  return statementMap;
}

function readBoundedSource(repoRoot, repoPath) {
  if (!isMaintainedSourcePath(repoPath)) {
    fail(`source path is not maintained: ${repoPath}`);
  }
  const absolute = resolve(repoRoot, repoPath);
  const prefix = `${repoRoot}${sep}`;
  if (!absolute.startsWith(prefix) || relative(repoRoot, absolute).startsWith("..")) {
    fail(`source path escapes the repository: ${repoPath}`);
  }
  let before;
  let canonical;
  try {
    before = lstatSync(absolute);
    canonical = realpathSync(absolute);
  } catch {
    fail(`source is unavailable: ${repoPath}`);
  }
  if (!before.isFile() || before.isSymbolicLink() || canonical !== absolute) {
    fail(`source is not a canonical regular file: ${repoPath}`);
  }
  if (before.size <= 0 || before.size > MAX_SOURCE_BYTES) {
    fail(`source size is out of bounds: ${repoPath}`);
  }
  let bytes;
  let after;
  try {
    bytes = readFileSync(absolute);
    after = statSync(absolute);
  } catch {
    fail(`source could not be read: ${repoPath}`);
  }
  for (const field of ["dev", "ino", "size", "mtimeMs", "ctimeMs"]) {
    if (before[field] !== after[field]) {
      fail(`source changed while it was read: ${repoPath}`);
    }
  }
  if (bytes.length !== before.size) {
    fail(`source changed while it was read: ${repoPath}`);
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail(`source is not UTF-8: ${repoPath}`);
  }
}

function validateEnvelope(document, repoRoot, label, producerIdentity) {
  if (!hasExactKeys(document, ENVELOPE_KEYS)) {
    fail(`${label} envelope has the wrong shape`);
  }
  for (const key of PRODUCER_KEYS) {
    if (document[key] !== producerIdentity[key]) {
      fail(`${label} envelope has an invalid producer identity`);
    }
  }
  if (!isObject(document.coverage)) {
    fail(`${label} coverage must be an object`);
  }
  const paths = Object.keys(document.coverage);
  if (paths.length === 0 || paths.length > MAX_SOURCES) {
    fail(`${label} envelope source count is out of bounds`);
  }
  const validated = new Map();
  let totalStatements = 0;
  for (const path of paths) {
    const record = document.coverage[path];
    if (!hasExactKeys(record, ["path", "statementMap", "s"]) || record.path !== path) {
      fail(`${label} record has the wrong shape or path: ${path}`);
    }
    const source = readBoundedSource(repoRoot, path);
    let canonicalMap;
    try {
      canonicalMap = executableLineStatementMap(source);
    } catch {
      fail(`${label} source cannot produce a canonical statement map: ${path}`);
    }
    if (
      !isObject(record.statementMap) ||
      JSON.stringify(record.statementMap) !== JSON.stringify(canonicalMap)
    ) {
      fail(`${label} statement map is not bound to candidate source: ${path}`);
    }
    const statementIds = Object.keys(canonicalMap);
    if (!isObject(record.s) || Object.keys(record.s).join("\u0000") !== statementIds.join("\u0000")) {
      fail(`${label} hit map does not match its statements: ${path}`);
    }
    totalStatements += statementIds.length;
    if (totalStatements > MAX_STATEMENTS) {
      fail(`${label} statement count exceeds its bound`);
    }
    const hits = {};
    for (const id of statementIds) {
      const count = record.s[id];
      if (!Number.isSafeInteger(count) || count < 0) {
        fail(`${label} hit count is invalid: ${path}`);
      }
      hits[id] = count;
    }
    validated.set(path, { path, statementMap: canonicalMap, s: hits });
  }
  return validated;
}

/** Union one canonical Node and one canonical browser executable-line envelope. */
export function unionCanonicalCoverage({ node, browser, repoRoot }) {
  let canonicalRoot;
  try {
    canonicalRoot = realpathSync(repoRoot);
  } catch {
    fail("repository root is unavailable");
  }
  if (!lstatSync(canonicalRoot).isDirectory()) {
    fail("repository root is not a directory");
  }
  const nodeRecords = validateEnvelope(
    node,
    canonicalRoot,
    "Node",
    NODE_COVERAGE_PRODUCER,
  );
  const browserRecords = validateEnvelope(
    browser,
    canonicalRoot,
    "browser",
    BROWSER_COVERAGE_PRODUCER,
  );
  const paths = [...new Set([...nodeRecords.keys(), ...browserRecords.keys()])].sort();
  if (paths.length > MAX_SOURCES) {
    fail("union source count exceeds its bound");
  }

  const coverage = {};
  for (const path of paths) {
    const records = [nodeRecords.get(path), browserRecords.get(path)].filter(Boolean);
    const statementMap = records[0].statementMap;
    const hits = {};
    for (const id of Object.keys(statementMap)) {
      let total = 0;
      for (const record of records) {
        const next = total + record.s[id];
        if (!Number.isSafeInteger(next)) {
          fail(`hit count overflow: ${path}`);
        }
        total = next;
      }
      hits[id] = total;
    }
    coverage[path] = { path, statementMap, s: hits };
  }
  return { ...UNION_COVERAGE_PRODUCER, coverage };
}
