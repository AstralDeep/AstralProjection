/**
 * Feature 089 (T047): resolve Playwright from the repository's CI tooling.
 *
 * `tooling/web-ci` already lock-pins `@playwright/test`, and adding a second
 * copy under `tests/` would give the parity harness a different browser build
 * from the one the 088 browser specs run against. This shim borrows that
 * installation instead, and fails with an instruction rather than a module
 * resolution error when it has not been installed yet.
 */

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(here, '..', '..');
const webCiPackage = path.join(REPO_ROOT, 'tooling', 'web-ci', 'package.json');

let chromium;
try {
  const require = createRequire(webCiPackage);
  ({ chromium } = require('@playwright/test'));
} catch (error) {
  throw new Error(
    'Playwright is not installed. From the repository root run:\n' +
      '  cd tooling/web-ci && corepack npm ci --ignore-scripts && npx playwright install chromium\n' +
      `(original error: ${error.message})`,
  );
}

export { chromium };
