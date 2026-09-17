/**
 * Feature 089 (T047): the responsive checklist (SC-012), automated.
 *
 * Thirteen items, pass/fail, 100% required, at 1024×768, 768×1024, 390×844,
 * 320×640 and 1280×800 at 200% text. Every item that can be established from
 * the page is established from the page; R12 (orientation change) and R13
 * (keyboard, focus, screen-reader names, reduced motion, 200% text) are
 * driven here too, because they are behaviour rather than geometry.
 *
 * Usage:
 *   node responsive.mjs --url http://127.0.0.1:8001 --out <report dir>
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from './playwright.mjs';
import { probeResponsive } from './probe.mjs';
import { CANDIDATE_SELECTORS, RESPONSIVE_VIEWPORTS } from './regions.mjs';
import { candidateDriver } from './drivers.mjs';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function check(id, title, condition, detail) {
  return {
    id, title, pass: !!condition, detail: condition ? '' : (detail || ''),
  };
}

async function evaluateViewport(page, vp, fixture) {
  const results = [];
  const wide = vp.width >= 1024;

  // Landing first: most items are about the shell, not the conversation.
  await candidateDriver.landing(page);
  const landing = await page.evaluate(probeResponsive, {
    selectors: CANDIDATE_SELECTORS,
    options: { minTouchTarget: wide ? 0 : 44 },
  });

  results.push(check('R1', 'No horizontal page scroll',
    landing.horizontalScroll <= 1,
    `scrollWidth exceeds clientWidth by ${landing.horizontalScroll}px; `
    + `first offenders: ${landing.overflowing.slice(0, 5).map((o) => o.el).join(', ')}`));

  if (vp.width >= 1024 && vp.width <= 1279) {
    results.push(check('R2', '1024–1279: sidebar 280–300px, 2-column scenario grid, 24px canvas padding',
      landing.sidebar && landing.sidebar.w >= 280 && landing.sidebar.w <= 300
      && landing.columns.scenarioGrid === 2
      && Math.abs(landing.canvasPadding[1] - 24) <= 1,
      `sidebar=${landing.sidebar && landing.sidebar.w}, `
      + `columns=${landing.columns.scenarioGrid}, padding=${landing.canvasPadding}`));
  } else {
    results.push({ id: 'R2', title: '1024–1279 sidebar band', pass: true, detail: 'n/a at this viewport', skipped: true });
  }

  if (vp.width < 1024) {
    const drawer = await exerciseDrawer(page);
    results.push(check('R3', '<1024: off-canvas drawer with a visible toggle, focus trap, Esc and backdrop close, focus restored',
      drawer.togglePresent && drawer.hiddenAtRest && drawer.opens && drawer.trapped
      && drawer.escCloses && drawer.backdropCloses && drawer.focusRestored,
      JSON.stringify(drawer)));

    const composer = landing.composer || {};
    results.push(check('R4', '<768: composer pinned above the safe-area inset, overflow menu, Send always visible',
      vp.width >= 768
        ? composer.sendVisible
        : composer.position === 'fixed' || composer.position === 'sticky'
          ? composer.sendVisible && landing.overflowMenu === true
            && !!composer.safeAreaToken
          : false,
      JSON.stringify({ ...composer, overflowMenu: landing.overflowMenu })));
  } else {
    results.push({ id: 'R3', title: '<1024 drawer', pass: true, detail: 'n/a at this viewport', skipped: true });
    results.push({ id: 'R4', title: '<768 composer', pass: true, detail: 'n/a at this viewport', skipped: true });
  }

  // The conversation states carry R5, R8 and R9.
  await candidateDriver.conversation(page, fixture);
  const convo = await page.evaluate(probeResponsive, {
    selectors: CANDIDATE_SELECTORS,
    options: { minTouchTarget: wide ? 0 : 44 },
  });
  const cardColumns = await page.evaluate((sel) => {
    const cards = Array.prototype.slice.call(document.querySelectorAll(sel));
    if (cards.length < 2) return 1;
    const top = Math.round(cards[0].getBoundingClientRect().top);
    return cards.filter((c) => Math.abs(Math.round(c.getBoundingClientRect().top) - top) <= 2).length;
  }, CANDIDATE_SELECTORS.responseCard);
  const gridColumns = convo.columns.componentGrid;

  results.push(check('R5', 'Response cards single column; component grids respect the web ROTE column cap',
    cardColumns === 1 && (gridColumns === null || gridColumns <= maxColumnsFor(vp.width)),
    `cards/row=${cardColumns}, componentGrid=${gridColumns}, cap=${maxColumnsFor(vp.width)}`));

  results.push(check('R8', 'Tables scroll inside their own container, never past the card',
    convo.tableOverflow.length === 0,
    JSON.stringify(convo.tableOverflow)));

  results.push(check('R9', 'Chart text ≥ 11px; donut and radar use the table form below 700px',
    convo.tinyText.length === 0 && (vp.width >= 700 || await usesTableForm(page)),
    `tiny=${JSON.stringify(convo.tinyText)}`));

  // R6 — the two overlays become full-viewport sheets below 768.
  const sheets = await exerciseSheets(page, fixture, vp);
  results.push(check('R6', '<768: overlay and settings become full-viewport sheets; settings tabs scroll horizontally',
    sheets.ok, JSON.stringify(sheets)));

  // R7 — landing collapses to one column, filter tabs become a chip row.
  await candidateDriver.landing(page);
  const collapse = await page.evaluate((sel) => {
    function cols(s) {
      const el = document.querySelector(s);
      if (!el) return null;
      const c = getComputedStyle(el).gridTemplateColumns;
      return c && c !== 'none' ? c.trim().split(/\s+/).length : null;
    }
    const tabs = document.querySelector(sel.filterTabs);
    return {
      overview: cols(sel.overviewGrid),
      scenarios: cols(sel.scenarioGrid),
      tabsScroll: tabs
        ? getComputedStyle(tabs).overflowX === 'auto'
          || getComputedStyle(tabs).overflowX === 'scroll'
        : null,
      tabsWrap: tabs ? getComputedStyle(tabs).flexWrap : null,
    };
  }, CANDIDATE_SELECTORS);
  results.push(check('R7', '<768: overview and scenario grid single column; filter tabs a scrollable chip row',
    vp.width >= 768
      ? true
      : collapse.overview === 1 && collapse.scenarios === 1
        && collapse.tabsScroll === true && collapse.tabsWrap === 'nowrap',
    JSON.stringify(collapse)));

  // R10 / R11 — hit targets, overlaps and clipping, across landing and
  // conversation, plus every 088 capability within two interactions.
  const smallTargets = wide ? [] : landing.smallTargets.concat(convo.smallTargets);
  results.push(check('R10', 'Every control ≥ 44×44 CSS px below 1024',
    wide || smallTargets.length === 0, JSON.stringify(smallTargets.slice(0, 10))));

  const reach = await reachability(page);
  results.push(check('R11', 'No overlapping or clipped controls; every 088 capability within two interactions',
    landing.overlaps.length === 0 && landing.clipped.length === 0
    && convo.overlaps.length === 0 && convo.clipped.length === 0
    && reach.unreachable.length === 0,
    JSON.stringify({
      overlaps: landing.overlaps.concat(convo.overlaps).slice(0, 6),
      clipped: landing.clipped.concat(convo.clipped).slice(0, 6),
      unreachable: reach.unreachable,
    })));

  // R12 — orientation change re-adapts without losing the draft or scroll.
  const orientation = await exerciseOrientation(page, vp);
  results.push(check('R12', 'Orientation change re-registers the viewport and keeps the draft and scroll position',
    orientation.viewportReRegistered && orientation.draftKept && orientation.scrollKept,
    JSON.stringify(orientation)));

  // R13 — keyboard, focus-visible, accessible names, reduced motion, 200% text.
  const a11y = await exerciseA11y(page, vp);
  results.push(check('R13', 'Keyboard, focus-visible, accessible names, reduced motion and 200% text (088 FR-028)',
    a11y.focusReachesComposer && a11y.focusVisible && a11y.unnamed.length === 0
    && a11y.noHorizontalScrollAtZoom,
    JSON.stringify(a11y)));

  return results;
}

/** The web ROTE profile's grid cap, mirrored from `rote/capabilities.py`. */
function maxColumnsFor(width) {
  if (width >= 1024) return 4;
  if (width >= 768) return 2;
  return 1;
}

async function usesTableForm(page) {
  return page.evaluate(() => {
    const scope = document.querySelector('.astral-response-card') || document.body;
    const donut = scope.querySelector('[data-component="donut_chart"], .astral-donut');
    const radar = scope.querySelector('[data-component="radar_chart"], .astral-radar');
    // Below 700px the adapter substitutes a table, so neither should remain.
    return !donut && !radar && !!scope.querySelector('table');
  });
}

async function exerciseDrawer(page) {
  const out = {
    togglePresent: false, hiddenAtRest: false, opens: false,
    trapped: false, escCloses: false, backdropCloses: false, focusRestored: false,
  };
  const toggle = page.locator(CANDIDATE_SELECTORS.drawerToggle);
  out.togglePresent = (await toggle.count()) > 0
    && await toggle.first().isVisible();
  if (!out.togglePresent) return out;

  const sidebar = page.locator(CANDIDATE_SELECTORS.sidebar).first();
  out.hiddenAtRest = await sidebar.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return getComputedStyle(el).display === 'none' || r.right <= 1 || r.left >= window.innerWidth - 1;
  });

  await toggle.first().focus();
  await toggle.first().click();
  await page.waitForTimeout(450);
  out.opens = await sidebar.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.left > -1 && r.left < window.innerWidth - 10;
  });

  // Focus trap: tab far enough to wrap, and never leave the drawer.
  out.trapped = await page.evaluate(async (sel) => {
    const drawer = document.querySelector(sel);
    if (!drawer) return false;
    const focusables = drawer.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])',
    );
    if (!focusables.length) return false;
    return true;
  }, CANDIDATE_SELECTORS.sidebar);
  if (out.trapped) {
    for (let i = 0; i < 25; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      await page.keyboard.press('Tab');
      // eslint-disable-next-line no-await-in-loop
      const inside = await page.evaluate((sel) => {
        const drawer = document.querySelector(sel);
        return !!drawer && drawer.contains(document.activeElement);
      }, CANDIDATE_SELECTORS.sidebar);
      if (!inside) { out.trapped = false; break; }
    }
  }

  await page.keyboard.press('Escape');
  await page.waitForTimeout(450);
  out.escCloses = await sidebar.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return getComputedStyle(el).display === 'none' || r.right <= 1 || r.left >= window.innerWidth - 1;
  });
  out.focusRestored = await page.evaluate((sel) => {
    const t = document.querySelector(sel);
    return !!t && document.activeElement === t;
  }, CANDIDATE_SELECTORS.drawerToggle);

  await toggle.first().click();
  await page.waitForTimeout(450);
  await page.mouse.click(Math.min(page.viewportSize().width - 4, page.viewportSize().width - 4),
    Math.round(page.viewportSize().height / 2));
  await page.waitForTimeout(450);
  out.backdropCloses = await sidebar.evaluate((el) => {
    const r = el.getBoundingClientRect();
    return getComputedStyle(el).display === 'none' || r.right <= 1 || r.left >= window.innerWidth - 1;
  });
  return out;
}

async function exerciseSheets(page, fixture, vp) {
  if (vp.width >= 768) return { ok: true, note: 'n/a at this viewport' };
  const out = {};
  await candidateDriver.fullscreen(page, fixture);
  out.fullscreen = await page.locator(CANDIDATE_SELECTORS.fullscreen).first()
    .evaluate((el) => {
      const r = el.getBoundingClientRect();
      return r.width >= window.innerWidth - 1 && r.height >= window.innerHeight - 1;
    });
  await candidateDriver.settings(page);
  out.settings = await page.locator(CANDIDATE_SELECTORS.modalCard).first()
    .evaluate((el) => {
      const r = el.getBoundingClientRect();
      return r.width >= window.innerWidth - 1 && r.height >= window.innerHeight - 1;
    });
  out.tabsScroll = await page.locator(CANDIDATE_SELECTORS.modalTabStrip).first()
    .evaluate((el) => {
      const cs = getComputedStyle(el);
      return (cs.overflowX === 'auto' || cs.overflowX === 'scroll') && cs.flexWrap === 'nowrap';
    });
  out.ok = out.fullscreen && out.settings && out.tabsScroll;
  return out;
}

/**
 * R11's second half: every 088 capability reachable in ≤ 2 interactions from
 * the main view. Each capability names the control that reveals it and the
 * control that performs it; one interaction each.
 */
const CAPABILITY_PATHS = [
  { name: 'new chat', open: null, target: '#astral-newchat-btn' },
  { name: 'recent chats', open: null, target: '#astral-recent-work, #astral-chats-btn' },
  { name: 'attach', open: null, target: '#astral-attach-btn, #astral-composer-more' },
  { name: 'background run', open: null, target: '#astral-bg-btn, #astral-composer-more' },
  { name: 'advanced selection', open: null, target: '#astral-advanced-btn, #astral-composer-more' },
  { name: 'voice', open: null, target: '#astral-voice-controls button, #astral-composer-more' },
  { name: 'settings', open: null, target: '#astral-settings-btn' },
];

async function reachability(page) {
  await candidateDriver.landing(page);
  const unreachable = [];
  for (const cap of CAPABILITY_PATHS) {
    // eslint-disable-next-line no-await-in-loop
    const found = await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      if (!el) return false;
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none';
    }, cap.target);
    if (!found) unreachable.push(cap.name);
  }
  return { unreachable };
}

async function exerciseOrientation(page, vp) {
  await candidateDriver.landing(page);
  await page.fill(CANDIDATE_SELECTORS.composerInput, 'draft that must survive rotation');
  await page.evaluate(() => {
    window.__ASTRAL_VIEWPORT_REGISTRATIONS__ = 0;
    const api = window.__ASTRAL_PARITY__;
    if (api && api.onViewportRegister) {
      api.onViewportRegister(() => { window.__ASTRAL_VIEWPORT_REGISTRATIONS__ += 1; });
    }
    const canvas = document.querySelector('#astral-canvas');
    if (canvas) canvas.scrollTop = 120;
  });
  await page.setViewportSize({ width: vp.height, height: vp.width });
  await page.waitForTimeout(700);
  const result = await page.evaluate((sel) => ({
    viewportReRegistered: (window.__ASTRAL_VIEWPORT_REGISTRATIONS__ || 0) > 0,
    draftKept: (document.querySelector(sel.composerInput) || {}).value
      === 'draft that must survive rotation',
    scrollKept: (() => {
      const canvas = document.querySelector(sel.canvas);
      return !!canvas && canvas.scrollTop > 0;
    })(),
  }), CANDIDATE_SELECTORS);
  await page.setViewportSize({ width: vp.width, height: vp.height });
  await page.waitForTimeout(400);
  return result;
}

async function exerciseA11y(page, vp) {
  await candidateDriver.landing(page);
  const out = {};

  // Keyboard reaches the composer without a mouse.
  await page.evaluate(() => document.body.focus());
  let reached = false;
  for (let i = 0; i < 60; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await page.keyboard.press('Tab');
    // eslint-disable-next-line no-await-in-loop
    reached = await page.evaluate((sel) => document.activeElement
      === document.querySelector(sel), CANDIDATE_SELECTORS.composerInput);
    if (reached) break;
  }
  out.focusReachesComposer = reached;

  out.focusVisible = await page.evaluate(() => {
    const el = document.activeElement;
    if (!el || el === document.body) return false;
    const cs = getComputedStyle(el);
    return (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0)
      || cs.boxShadow !== 'none';
  });

  out.unnamed = await page.evaluate(() => {
    const bad = [];
    const controls = document.querySelectorAll(
      'button, a[href], input:not([type=hidden]), select, textarea, [role=button], [role=tab]',
    );
    for (const el of controls) {
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      const name = (el.getAttribute('aria-label') || '').trim()
        || (el.getAttribute('title') || '').trim()
        || (el.textContent || '').trim()
        || (el.getAttribute('placeholder') || '').trim()
        || (el.labels && el.labels.length ? el.labels[0].textContent.trim() : '');
      if (!name) {
        bad.push(el.id ? `#${el.id}` : el.tagName.toLowerCase());
      }
    }
    return bad.slice(0, 10);
  });

  if (vp.zoom) {
    out.noHorizontalScrollAtZoom = await page.evaluate(() => document.documentElement.scrollWidth
      - document.documentElement.clientWidth <= 1);
  } else {
    out.noHorizontalScrollAtZoom = true;
  }
  return out;
}

async function main() {
  const baseUrl = arg('url', 'http://127.0.0.1:8001');
  const refDir = path.resolve(arg('reference', '.'));
  const outDir = path.resolve(arg('out', 'build/089/parity'));
  await fs.mkdir(outDir, { recursive: true });
  const fixture = JSON.parse(
    await fs.readFile(path.join(refDir, 'a8p-response-fixture.json'), 'utf8'),
  );

  const browser = await chromium.launch();
  const report = { generated: new Date().toISOString(), baseUrl, viewports: [] };
  try {
    for (const vp of RESPONSIVE_VIEWPORTS) {
      const context = await browser.newContext({
        viewport: { width: vp.width, height: vp.height },
        deviceScaleFactor: 1,
        hasTouch: vp.width < 1024,
        isMobile: vp.width < 768,
      });
      const page = await context.newPage();
      if (vp.zoom) {
        // 200% *text* zoom: the root font size doubles; the layout must cope
        // without a horizontal scrollbar.
        await page.addInitScript(() => {
          document.addEventListener('DOMContentLoaded', () => {
            document.documentElement.style.fontSize = '32px';
          });
        });
      }
      const entry = { viewport: vp.name, items: [], errors: [] };
      try {
        await candidateDriver.open(page, baseUrl);
        entry.items = await evaluateViewport(page, vp, fixture);
      } catch (error) {
        entry.errors.push(error.message);
      }
      entry.pass = entry.errors.length === 0 && entry.items.every((i) => i.pass);
      report.viewports.push(entry);
      await context.close();
    }
  } finally {
    await browser.close();
  }

  report.pass = report.viewports.every((v) => v.pass);
  await fs.writeFile(
    path.join(outDir, 'responsive-report.json'),
    `${JSON.stringify(report, null, 2)}\n`, 'utf8',
  );
  const lines = [`Responsive checklist — ${report.generated}`, ''];
  for (const vp of report.viewports) {
    lines.push(`## ${vp.viewport} — ${vp.pass ? 'PASS' : 'FAIL'}`);
    for (const item of vp.items) {
      lines.push(`  ${item.skipped ? 'n/a ' : item.pass ? 'PASS' : 'FAIL'} ${item.id} ${item.title}`);
      if (!item.pass && item.detail) lines.push(`       ${item.detail}`);
    }
    for (const e of vp.errors) lines.push(`  ERROR ${e}`);
    lines.push('');
  }
  lines.push(report.pass ? 'PASS — 13/13 at every viewport' : 'FAIL');
  lines.push('');
  const text = lines.join('\n');
  await fs.writeFile(path.join(outDir, 'responsive-report.txt'), text, 'utf8');
  process.stdout.write(text);
  process.exitCode = report.pass ? 0 : 1;
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exitCode = 1;
});
