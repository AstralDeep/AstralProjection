/**
 * Feature 089 (T047): score the Astral web client against the a8p captures.
 *
 * Reads the reference measurements written by `capture-reference.mjs`, drives
 * the Astral web client through the same five states at the same three
 * desktop viewports, and applies the rules in `regions.mjs`. Every CSP
 * violation raised along the way is recorded, because a layout that only
 * works with an inline style is not the layout the contract asks for.
 *
 * Usage:
 *   node score-parity.mjs --url http://127.0.0.1:8001 \
 *     --reference <reference dir> --out <report dir>
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from './playwright.mjs';
import { probePage } from './probe.mjs';
import {
  CANDIDATE_SELECTORS, DESKTOP_VIEWPORTS, ITEMS, TOTAL_WEIGHT, VERDICT_CREDIT,
} from './regions.mjs';
import { candidateDriver, probeReducedMotionDialog, MODAL_CARD } from './drivers.mjs';

/** The composer controls on the bar: attach, voice, more options (with background, advanced, timeline, pulse nested). */
const REQUIRED_COMPOSER_CONTROLS = 3;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const STATE_RUNNERS = {
  landing: (d, p) => d.landing(p),
  conversation: (d, p, f) => d.conversation(p, f),
  hover: (d, p, f) => d.hover(p, f),
  fullscreen: (d, p, f) => d.fullscreen(p, f),
  settings: (d, p) => d.settings(p),
  pending: (d, p, f) => d.pending(p, f),
};

async function main() {
  const baseUrl = arg('url', 'http://127.0.0.1:8001');
  const refDir = path.resolve(arg('reference', '.'));
  const outDir = path.resolve(arg('out', 'build/089/parity'));
  await fs.mkdir(outDir, { recursive: true });

  const fixture = JSON.parse(
    await fs.readFile(path.join(refDir, 'a8p-response-fixture.json'), 'utf8'),
  );
  const states = Object.keys(STATE_RUNNERS);

  const browser = await chromium.launch();
  const report = { generated: new Date().toISOString(), baseUrl, viewports: [] };

  try {
    // The one fact measured in its own context: does the dialog hold still
    // when the viewer has asked for reduced motion?
    const rmContext = await browser.newContext({
      viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce',
    });
    const rmPage = await rmContext.newPage();
    let modalReducedMotionStill = false;
    try {
      modalReducedMotionStill = await probeReducedMotionDialog(
        rmPage, candidateDriver, baseUrl, MODAL_CARD.astral,
      );
    } catch (error) {
      report.reducedMotionError = error.message;
    }
    await rmContext.close();

    for (const vp of DESKTOP_VIEWPORTS) {
      const context = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        deviceScaleFactor: 1,
        reducedMotion: 'no-preference',
      });
      const page = await context.newPage();
      const cspViolations = [];
      page.on('console', (msg) => {
        const text = msg.text();
        if (/Content Security Policy|CSP/i.test(text)) cspViolations.push(text);
      });
      await page.addInitScript(() => {
        document.addEventListener('securitypolicyviolation', (e) => {
          window.__CSP__ = window.__CSP__ || [];
          window.__CSP__.push(`${e.violatedDirective} ${e.blockedURI}`);
        });
      });

      const vpReport = { viewport: vp.name, items: [], csp: [], errors: [] };
      try {
        await candidateDriver.open(page, baseUrl);

        const measurements = {};
        for (const state of states) {
          await STATE_RUNNERS[state](candidateDriver, page, fixture);
          measurements[state] = await page.evaluate(probePage, CANDIDATE_SELECTORS);
          await page.screenshot({
            path: path.join(outDir, `astral-${state}-${vp.width}x${vp.height}.png`),
          });
        }
        await fs.writeFile(
          path.join(outDir, `astral-measurements-${vp.width}x${vp.height}.json`),
          `${JSON.stringify(measurements, null, 2)}\n`,
          'utf8',
        );

        const ctx = await candidateDriver.context(page, fixture);
        ctx.viewportWidth = vp.width;
        ctx.requiredComposerControls = REQUIRED_COMPOSER_CONTROLS;
        ctx.modalReducedMotionStill = modalReducedMotionStill;

        const refs = {};
        for (const state of states) {
          refs[state] = JSON.parse(await fs.readFile(
            path.join(refDir, `a8p-${state}-${vp.width}x${vp.height}.json`), 'utf8',
          ));
        }

        for (const item of ITEMS) {
          let result;
          try {
            result = item.score(refs[item.state], measurements[item.state], ctx);
          } catch (error) {
            result = { verdict: 'fail', detail: `scorer threw: ${error.message}` };
          }
          vpReport.items.push({
            id: item.id,
            group: item.group,
            weight: item.weight,
            auto: item.auto,
            title: item.title,
            verdict: result.verdict,
            detail: result.detail || '',
            earned: item.weight * VERDICT_CREDIT[result.verdict],
          });
        }
        vpReport.csp = (await page.evaluate(() => window.__CSP__ || []))
          .concat(cspViolations);
      } catch (error) {
        vpReport.errors.push(error.message);
        for (const item of ITEMS) {
          if (vpReport.items.some((i) => i.id === item.id)) continue;
          vpReport.items.push({
            id: item.id,
            group: item.group,
            weight: item.weight,
            auto: item.auto,
            title: item.title,
            verdict: 'fail',
            detail: `not reached: ${error.message}`,
            earned: 0,
          });
        }
      }

      vpReport.earned = vpReport.items.reduce((s, i) => s + i.earned, 0);
      vpReport.total = TOTAL_WEIGHT;
      vpReport.score = Math.round((vpReport.earned / TOTAL_WEIGHT) * 1000) / 10;
      report.viewports.push(vpReport);
      await context.close();
    }
  } finally {
    await browser.close();
  }

  report.minScore = Math.min(...report.viewports.map((v) => v.score));
  report.pass = report.minScore >= 90
    && report.viewports.every((v) => v.csp.length === 0);

  await fs.writeFile(
    path.join(outDir, 'parity-report.json'), `${JSON.stringify(report, null, 2)}\n`, 'utf8',
  );
  const text = renderText(report);
  await fs.writeFile(path.join(outDir, 'parity-report.txt'), text, 'utf8');
  process.stdout.write(text);
  process.exitCode = report.pass ? 0 : 1;
}

function renderText(report) {
  const lines = [`a8p desktop parity — ${report.generated}`, ''];
  for (const vp of report.viewports) {
    lines.push(`## ${vp.viewport} — ${vp.score}% (${vp.earned}/${vp.total})`);
    for (const item of vp.items) {
      const mark = { pass: 'PASS', partial: 'PART', fail: 'FAIL' }[item.verdict];
      const kind = item.auto ? 'auto  ' : 'review';
      lines.push(`  ${mark} ${kind} ${item.id} (${item.weight}) ${item.title}`);
      if (item.detail) lines.push(`         ${item.detail}`);
    }
    if (vp.csp.length) {
      lines.push(`  CSP violations: ${vp.csp.length}`);
      for (const v of vp.csp.slice(0, 10)) lines.push(`    ${v}`);
    } else {
      lines.push('  CSP violations: 0');
    }
    for (const e of vp.errors) lines.push(`  ERROR ${e}`);
    lines.push('');
  }
  lines.push(`lowest viewport score: ${report.minScore}%  (target ≥ 90%)`);
  lines.push(report.pass ? 'PASS' : 'FAIL');
  lines.push('');
  return lines.join('\n');
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
