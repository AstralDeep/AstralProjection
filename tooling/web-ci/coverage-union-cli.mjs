import {
  closeSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TextDecoder } from "node:util";

import { parse } from "espree";

import { unionCanonicalCoverage } from "./coverage-union.mjs";

const MAX_INPUT_BYTES = 32 * 1024 * 1024;
const MAX_TOTAL_INPUT_BYTES = 64 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const MAX_JSON_AST_NODES = 2_000_000;
const FLAGS = ["--node", "--browser", "--repo-root", "--output"];

function fail(message) {
  throw new TypeError(`coverage union failed: ${message}`);
}

function argumentsFrom(argv) {
  if (argv.length !== FLAGS.length * 2) {
    fail("expected --node, --browser, --repo-root, and --output exactly once");
  }
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!FLAGS.includes(flag) || typeof value !== "string" || value.length === 0) {
      fail("expected --node, --browser, --repo-root, and --output exactly once");
    }
    if (Object.hasOwn(values, flag)) {
      fail(`duplicate argument ${flag}`);
    }
    values[flag] = value;
  }
  if (Object.keys(values).length !== FLAGS.length) {
    fail("expected --node, --browser, --repo-root, and --output exactly once");
  }
  return values;
}

function rejectDuplicateJsonObjectKeys(text, label) {
  let tree;
  try {
    tree = parse(`(${text}\n)`, { ecmaVersion: "latest", sourceType: "script" });
  } catch {
    fail(`${label} input cannot be inspected for duplicate JSON object keys`);
  }
  const pending = [tree];
  let nodes = 0;
  while (pending.length > 0) {
    const value = pending.pop();
    if (Array.isArray(value)) {
      pending.push(...value);
      continue;
    }
    if (value === null || typeof value !== "object") continue;
    nodes += 1;
    if (nodes > MAX_JSON_AST_NODES) {
      fail(`${label} input JSON structure exceeds its bound`);
    }
    if (value.type === "ObjectExpression") {
      const keys = new Set();
      for (const property of value.properties) {
        if (
          property.type !== "Property" ||
          property.computed ||
          property.kind !== "init" ||
          property.method ||
          property.shorthand ||
          property.key.type !== "Literal" ||
          typeof property.key.value !== "string"
        ) {
          fail(`${label} input contains a non-JSON object property`);
        }
        if (keys.has(property.key.value)) {
          fail(`${label} input contains duplicate JSON object key ${property.key.raw}`);
        }
        keys.add(property.key.value);
      }
    }
    pending.push(...Object.values(value));
  }
}

function readDocument(path, label) {
  const absolute = resolve(path);
  let canonical;
  let before;
  try {
    canonical = realpathSync(absolute);
    before = lstatSync(canonical);
  } catch {
    fail(`${label} input is unavailable`);
  }
  if (!before.isFile() || before.isSymbolicLink()) {
    fail(`${label} input must be a canonical regular file`);
  }
  if (before.size <= 0 || before.size > MAX_INPUT_BYTES) {
    fail(`${label} input size is out of bounds`);
  }
  const bytes = readFileSync(canonical);
  const after = statSync(canonical);
  if (
    bytes.length !== before.size ||
    before.dev !== after.dev ||
    before.ino !== after.ino ||
    before.size !== after.size ||
    before.mtimeMs !== after.mtimeMs ||
    before.ctimeMs !== after.ctimeMs
  ) {
    fail(`${label} input changed while it was read`);
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail(`${label} input is not UTF-8`);
  }
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    fail(`${label} input is not valid JSON`);
  }
  rejectDuplicateJsonObjectKeys(text, label);
  return { absolute: canonical, bytes: bytes.length, document };
}

function writeNewOutput(path, document) {
  const output = resolve(path);
  const parent = realpathSync(dirname(output));
  if (!lstatSync(parent).isDirectory()) {
    fail("output parent is not a directory");
  }
  const content = Buffer.from(`${JSON.stringify(document, null, 2)}\n`, "utf8");
  if (content.length <= 0 || content.length > MAX_OUTPUT_BYTES) {
    fail("output size is out of bounds");
  }
  let descriptor;
  let created = false;
  try {
    descriptor = openSync(output, "wx", 0o600);
    created = true;
    writeFileSync(descriptor, content);
    closeSync(descriptor);
    descriptor = undefined;
  } catch {
    if (descriptor !== undefined) closeSync(descriptor);
    if (created) unlinkSync(output);
    fail("output must be a new writable file");
  }
}

export function main(argv) {
  try {
    const values = argumentsFrom(argv);
    const node = readDocument(values["--node"], "Node");
    const browser = readDocument(values["--browser"], "browser");
    if (node.absolute === browser.absolute) {
      fail("Node and browser inputs must be distinct files");
    }
    if (node.bytes + browser.bytes > MAX_TOTAL_INPUT_BYTES) {
      fail("input size exceeds its cumulative bound");
    }
    const document = unionCanonicalCoverage({
      node: node.document,
      browser: browser.document,
      repoRoot: values["--repo-root"],
    });
    writeNewOutput(values["--output"], document);
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    process.stderr.write(
      `${message.startsWith("coverage union failed:") ? message : `coverage union failed: ${message}`}\n`,
    );
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main(process.argv.slice(2));
}
