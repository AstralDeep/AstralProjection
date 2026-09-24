// Resolves the Playwright install from tooling/web-ci so the layout-parity harness shares its
// browser build with the rest of the suite; imported by every script and spec that drives a
// browser.

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
