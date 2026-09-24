// Collects optional exact-source browser coverage observations from the existing contract suites
// for test use; canonical conversion itself stays in browser-v8-cli.mjs.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const CLIENT = resolve(import.meta.dirname, "../../../backend/webrender/static/client.js");
const SOURCE = await readFile(CLIENT, "utf8");

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
    await mkdir(resolve(directory), { recursive: true });
    await writeFile(resolve(directory, name + ".json"), JSON.stringify(observations) + "\n", { mode: 0o600 });
  });
}
