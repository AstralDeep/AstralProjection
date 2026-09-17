/**
 * Feature 089 (T046/T047): putting each side into the five contract states.
 *
 * `contracts/web-layout-parity.md` scores five states. This file knows how to
 * reach each one on a8p and on the Astral web client, and how to establish the
 * behavioural facts a bounding box cannot show — that the search filters
 * live, that a card lifts on hover, that the expand chip opens the overlay,
 * and that the settings dialog is still under `prefers-reduced-motion`.
 *
 * The a8p driver never issues a chat turn. A real turn would need the owner's
 * TypeSafe key against the reference app, which the 089 credential rule does
 * not permit; instead the response is the one produced by a8p's *own*
 * server-side renderer in `a8p-response-fixture.json`, injected into the same
 * `conversationTurns` array a real turn would have filled.
 */

/* eslint-env node */

const SETTLE_MS = 350;

async function settle(page) {
  await page.waitForTimeout(SETTLE_MS);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => r(null))));
}

// -- a8p (reference) -------------------------------------------------------

export const referenceDriver = {
  name: 'a8p',

  async open(page, baseUrl) {
    await page.goto(baseUrl, { waitUntil: 'networkidle' });
    await page.waitForSelector('.agent-card', { timeout: 15000 });
    await settle(page);
  },

  async reset(page) {
    await page.evaluate(() => {
      // eslint-disable-next-line no-undef
      if (typeof closeFullscreenUI === 'function') closeFullscreenUI();
      // eslint-disable-next-line no-undef
      if (typeof closeUserSettings === 'function') closeUserSettings();
      const fs = document.getElementById('sdui-fullscreen-overlay');
      if (fs) { fs.style.display = 'none'; fs.classList.remove('active'); }
      const modal = document.getElementById('settings-modal-overlay');
      if (modal) { modal.style.display = 'none'; modal.classList.remove('active'); }
      document.body.style.overflow = '';
      // eslint-disable-next-line no-undef
      conversationTurns = [];
      const canvas = document.getElementById('canvas-area');
      if (canvas) canvas.classList.remove('has-response');
      const content = document.getElementById('response-content');
      if (content) content.innerHTML = '';
    });
    await settle(page);
  },

  async landing(page) {
    await this.reset(page);
  },

  async conversation(page, fixture, opts) {
    await this.reset(page);
    await page.evaluate(([fx, loading]) => {
      // eslint-disable-next-line no-undef
      currentSessionId = 'parity089deadbeef';
      // eslint-disable-next-line no-undef
      conversationTurns = [
        { id: 'turn-user-1', role: 'user', query: fx.query, time: '09:41' },
        {
          id: 'turn-assistant-1',
          role: 'assistant',
          agent_id: fx.agent_id,
          time: '09:41',
          ui_html: fx.ui_html,
        },
      ];
      const canvas = document.getElementById('canvas-area');
      if (canvas) canvas.classList.add('has-response');
      // eslint-disable-next-line no-undef
      renderConversationThread(!!loading);
    }, [fixture, !!(opts && opts.loading)]);
    await settle(page);
  },

  async hover(page, fixture) {
    await this.conversation(page, fixture);
    await page.hover('.chat-turn-assistant .sdui-widget-container');
    await settle(page);
  },

  async fullscreen(page, fixture) {
    await this.conversation(page, fixture);
    // eslint-disable-next-line no-undef
    await page.evaluate(() => openFullscreenUI('turn-assistant-1'));
    await settle(page);
  },

  async settings(page) {
    await this.reset(page);
    // eslint-disable-next-line no-undef
    await page.evaluate(() => openUserSettings());
    await page.waitForFunction(() => {
      const el = document.getElementById('settings-modal-overlay');
      return el && getComputedStyle(el).display !== 'none';
    }, null, { timeout: 10000 });
    await settle(page);
  },

  async pending(page, fixture) {
    await this.conversation(page, fixture, { loading: true });
  },

  async context(page, fixture) {
    return collectContext(page, this, fixture, {
      searchInput: '#agent-search',
      agentItem: '.agent-card',
      scenarioCard: '.scenario-card',
      expandChip: '.sdui-widget-expand-chip',
      fullscreen: '#sdui-fullscreen-overlay',
      backToLanding: '.btn-back-dash',
      landing: '#dashboard-landing',
      modalCard: '#settings-modal-overlay .modal-card',
      table: '.astral-table',
    });
  },
};

// -- the Astral web client (candidate) ------------------------------------

export const candidateDriver = {
  name: 'astral',

  async open(page, baseUrl) {
    await page.goto(baseUrl, { waitUntil: 'networkidle' });
    await page.waitForSelector('#astral-agent-list .astral-agent-item', { timeout: 20000 });
    await settle(page);
  },

  async reset(page) {
    await page.evaluate(() => {
      const api = window.__ASTRAL_PARITY__;
      if (api && api.reset) api.reset();
    });
    await settle(page);
  },

  async landing(page) {
    await this.reset(page);
  },

  async conversation(page, fixture, opts) {
    await this.reset(page);
    await page.evaluate(([fx, loading]) => {
      const api = window.__ASTRAL_PARITY__;
      api.seedConversation(fx, { loading: !!loading });
    }, [fixture, !!(opts && opts.loading)]);
    await settle(page);
  },

  async hover(page, fixture) {
    await this.conversation(page, fixture);
    await page.hover('.astral-response-card');
    await settle(page);
  },

  async fullscreen(page, fixture) {
    await this.conversation(page, fixture);
    await page.click('.astral-expand-chip');
    await page.waitForSelector('#astral-fullscreen.is-open', { timeout: 10000 });
    await settle(page);
  },

  async settings(page) {
    await this.reset(page);
    await page.evaluate(() => {
      const api = window.__ASTRAL_PARITY__;
      api.openSettings();
    });
    await page.waitForSelector('#astral-modal .astral-modal-card', { timeout: 15000 });
    await settle(page);
  },

  async pending(page, fixture) {
    await this.conversation(page, fixture, { loading: true });
  },

  async context(page, fixture) {
    return collectContext(page, this, fixture, {
      searchInput: '#astral-agent-search',
      agentItem: '.astral-agent-item',
      scenarioCard: '.astral-scenario-card',
      expandChip: '.astral-expand-chip',
      fullscreen: '#astral-fullscreen',
      backToLanding: '#astral-brand',
      landing: '#astral-landing',
      modalCard: '#astral-modal .astral-modal-card',
      table: 'table',
    });
  },
};

// -- behavioural facts shared by both sides -------------------------------

/**
 * The context flags `regions.mjs` consumes. Each is established by acting on
 * the page, because none of them can be read out of a single layout snapshot.
 */
async function collectContext(page, driver, fixture, sel) {
  const ctx = {};

  // B3 — the search input filters the list live.
  await driver.landing(page);
  // Count what a reader can SEE: one implementation removes the nodes, the
  // other hides them, and "the list filtered" means the same thing either way.
  const visibleItems = () => page.evaluate((s) => Array.prototype.filter.call(
    document.querySelectorAll(s),
    (el) => el.getBoundingClientRect().height > 0 && !el.hidden,
  ).length, sel.agentItem);
  const before = await visibleItems();
  await page.fill(sel.searchInput, 'zzzzqqq');
  await page.waitForTimeout(250);
  const afterNoMatch = await visibleItems();
  await page.fill(sel.searchInput, '');
  await page.waitForTimeout(250);
  const afterClear = await visibleItems();
  ctx.filtersLive = before > 0 && afterNoMatch < before && afterClear === before;

  // C4 — the scenario card lifts on hover.
  const card = page.locator(sel.scenarioCard).first();
  if (await card.count()) {
    const restY = await card.evaluate((el) => el.getBoundingClientRect().top);
    const restTransform = await card.evaluate((el) => getComputedStyle(el).transform);
    await card.hover();
    await page.waitForTimeout(400);
    const hoverY = await card.evaluate((el) => el.getBoundingClientRect().top);
    const hoverTransform = await card.evaluate((el) => getComputedStyle(el).transform);
    ctx.cardHoverLift = hoverY < restY - 0.5 || hoverTransform !== restTransform;
    await page.mouse.move(0, 0);
  } else {
    ctx.cardHoverLift = false;
  }

  // C5 — the landing comes back from "return to dashboard".
  await driver.conversation(page, fixture);
  const backCount = await page.locator(sel.backToLanding).count();
  if (backCount) {
    await page.locator(sel.backToLanding).first().click();
    await page.waitForTimeout(400);
    ctx.landingReturns = await page.locator(sel.landing).first()
      .evaluate((el) => getComputedStyle(el).display !== 'none' && el.getBoundingClientRect().height > 0);
  } else {
    ctx.landingReturns = false;
  }

  // D4 — the expand chip opens the overlay.
  await driver.hover(page, fixture);
  if (await page.locator(sel.expandChip).count()) {
    await page.locator(sel.expandChip).first().click({ force: true });
    await page.waitForTimeout(500);
    ctx.expandOpensFullscreen = await page.locator(sel.fullscreen).first()
      .evaluate((el) => getComputedStyle(el).display !== 'none'
        && el.getBoundingClientRect().height > 0);
  } else {
    ctx.expandOpensFullscreen = false;
  }

  // D5 — the component kinds actually present in a rendered response.
  await driver.conversation(page, fixture);
  ctx.componentKinds = await page.evaluate((tableSel) => {
    const scope = document.querySelector('.sdui-widget-preview-content')
      || document.querySelector('.astral-response-card')
      || document.body;
    const text = scope.innerHTML;
    return {
      metric: /metric|stat-(value|item)|kpi/i.test(text),
      chart: !!scope.querySelector('svg') && /chart/i.test(text),
      gauge: /gauge/i.test(text),
      stepper: /stepper|pipeline|timeline/i.test(text),
      table: !!scope.querySelector(tableSel) || !!scope.querySelector('table'),
    };
  }, sel.table);
  ctx.tableStickyHeader = await page.evaluate((tableSel) => {
    const table = document.querySelector(tableSel) || document.querySelector('table');
    if (!table) return false;
    const head = table.querySelector('thead th') || table.querySelector('th');
    if (!head) return false;
    return getComputedStyle(head).position === 'sticky';
  }, sel.table);

  // F2 — the dialog animates, and is still when reduced motion is asked for.
  await driver.settings(page);
  ctx.modalAnimates = await page.locator(sel.modalCard).first().evaluate((el) => {
    const cs = getComputedStyle(el);
    return parseFloat(cs.animationDuration) > 0.01 || parseFloat(cs.transitionDuration) > 0.01;
  });

  return ctx;
}

/** Re-measure the one reduced-motion fact on a page opened with the media
 * feature forced; the caller supplies that page. */
export async function probeReducedMotionDialog(page, driver, baseUrl, modalCardSelector) {
  await driver.open(page, baseUrl);
  await driver.settings(page);
  return page.locator(modalCardSelector).first().evaluate((el) => {
    const cs = getComputedStyle(el);
    return parseFloat(cs.animationDuration) <= 0.01 && parseFloat(cs.transitionDuration) <= 0.01;
  });
}

export const MODAL_CARD = {
  a8p: '#settings-modal-overlay .modal-card',
  astral: '#astral-modal .astral-modal-card',
};
