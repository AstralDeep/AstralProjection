/**
 * Feature 089 (T046): capture the a8p reference.
 *
 * For each of the three desktop viewports and the five contract states, this
 * writes a PNG and the region bounding-box JSON the scorer later compares
 * against. It also writes one `context.json` holding the behavioural facts
 * (live filter, hover lift, return-to-landing, expand-to-full-screen, the
 * component kinds present, dialog animation), so the reference side of every
 * scored item is on disk rather than re-derived on each scoring run.
 *
 * Usage:
 *   node capture-reference.mjs --url http://127.0.0.1:8010 --out <reference dir>
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from './playwright.mjs';
import { probePage } from './probe.mjs';
import { DESKTOP_VIEWPORTS, REFERENCE_SELECTORS } from './regions.mjs';
import { referenceDriver, probeReducedMotionDialog, MODAL_CARD } from './drivers.mjs';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const STATES = [
  { key: 'landing', run: (d, p) => d.landing(p) },
  { key: 'conversation', run: (d, p, f) => d.conversation(p, f) },
  { key: 'hover', run: (d, p, f) => d.hover(p, f) },
  { key: 'fullscreen', run: (d, p, f) => d.fullscreen(p, f) },
  { key: 'settings', run: (d, p) => d.settings(p) },
  { key: 'pending', run: (d, p, f) => d.pending(p, f) },
];

async function main() {
  const baseUrl = arg('url', 'http://127.0.0.1:8010');
  const outDir = path.resolve(arg('out', '.'));
  await fs.mkdir(outDir, { recursive: true });

  const fixture = JSON.parse(
    await fs.readFile(path.join(outDir, 'a8p-response-fixture.json'), 'utf8'),
  );

  const browser = await chromium.launch();
  const written = [];
  try {
    for (const vp of DESKTOP_VIEWPORTS) {
      const context = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        deviceScaleFactor: 1,
        reducedMotion: 'no-preference',
      });
      const page = await context.newPage();
      await referenceDriver.open(page, baseUrl);

      for (const state of STATES) {
        await state.run(referenceDriver, page, fixture);
        const measurement = await page.evaluate(probePage, REFERENCE_SELECTORS);
        const stem = `a8p-${state.key}-${vp.width}x${vp.height}`;
        await page.screenshot({ path: path.join(outDir, `${stem}.png`), fullPage: false });
        await fs.writeFile(
          path.join(outDir, `${stem}.json`),
          `${JSON.stringify(measurement, null, 2)}\n`,
          'utf8',
        );
        written.push(stem);
        const absent = measurement.missing.filter((m) => REFERENCE_SELECTORS[m]);
        if (absent.length) {
          process.stderr.write(`  ${stem}: not found — ${absent.join(', ')}\n`);
        }
      }

      const ctx = await referenceDriver.context(page, fixture);
      await fs.writeFile(
        path.join(outDir, `a8p-context-${vp.width}x${vp.height}.json`),
        `${JSON.stringify(ctx, null, 2)}\n`,
        'utf8',
      );
      await context.close();
      process.stdout.write(`${vp.name}: ${STATES.length} states captured\n`);
    }

    // The one fact that needs its own browser context.
    const reduced = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      reducedMotion: 'reduce',
    });
    const rmPage = await reduced.newPage();
    const still = await probeReducedMotionDialog(
      rmPage, referenceDriver, baseUrl, MODAL_CARD.a8p,
    );
    await fs.writeFile(
      path.join(outDir, 'a8p-reduced-motion.json'),
      `${JSON.stringify({ modalReducedMotionStill: still }, null, 2)}\n`,
      'utf8',
    );
    await reduced.close();
    process.stdout.write(`reduced-motion dialog still: ${still}\n`);
  } finally {
    await browser.close();
  }

  process.stdout.write(`${written.length} captures written to ${outDir}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
