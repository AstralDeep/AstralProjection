/**
 * Feature 089 (T047): the in-page measurement used by both sides of the
 * parity comparison.
 *
 * One function runs against a8p and against the Astral web client, so a
 * "difference" can only ever be a difference in the pages, never in how the
 * two were measured. It reads the DOM through a *logical* selector map: the
 * caller supplies `{sidebar: '#sidebar', ...}` for a8p and
 * `{sidebar: '#astral-sidebar', ...}` for Astral, and every probe below is
 * written against the logical name.
 *
 * It measures only; nothing here decides pass or fail. Scoring lives in
 * `regions.mjs` on the Node side, where both measurements are in hand.
 */

/* eslint-env browser */

export function probePage(selectors) {
  const out = { viewport: { w: window.innerWidth, h: window.innerHeight }, missing: [] };

  function one(name) {
    const sel = selectors[name];
    if (!sel) return null;
    const el = document.querySelector(sel);
    if (!el) {
      out.missing.push(name);
      return null;
    }
    return el;
  }
  function all(name) {
    const sel = selectors[name];
    if (!sel) return [];
    return Array.prototype.slice.call(document.querySelectorAll(sel));
  }
  function visible(el) {
    if (!el) return false;
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.01;
  }
  function box(el) {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return {
      x: round(r.x), y: round(r.y), w: round(r.width), h: round(r.height),
      right: round(r.right), bottom: round(r.bottom),
    };
  }
  function round(n) { return Math.round(n * 100) / 100; }
  function px(value) {
    const n = parseFloat(value);
    return Number.isFinite(n) ? round(n) : 0;
  }
  function styles(el, props) {
    if (!el) return null;
    const cs = getComputedStyle(el);
    const result = {};
    for (const p of props) result[p] = cs.getPropertyValue(p);
    return result;
  }
  function region(name, props) {
    const el = one(name);
    if (!el) return { present: false };
    const cs = getComputedStyle(el);
    const result = {
      present: true,
      visible: visible(el),
      box: box(el),
      padding: [px(cs.paddingTop), px(cs.paddingRight), px(cs.paddingBottom), px(cs.paddingLeft)],
      gap: px(cs.rowGap || cs.gap),
      radius: px(cs.borderTopLeftRadius),
      borderTop: px(cs.borderTopWidth),
      borderRight: px(cs.borderRightWidth),
      borderBottom: px(cs.borderBottomWidth),
      borderLeft: px(cs.borderLeftWidth),
      display: cs.display,
      position: cs.position,
      overflowY: cs.overflowY,
      scrollH: el.scrollHeight,
      clientH: el.clientHeight,
      scrollbar: el.offsetWidth - el.clientWidth - px(cs.borderLeftWidth) - px(cs.borderRightWidth),
      hasShadow: cs.boxShadow !== 'none' && cs.boxShadow !== '',
      hasBackdrop: (cs.backdropFilter || cs.webkitBackdropFilter || 'none') !== 'none',
      backgroundImage: (cs.backgroundImage || 'none').slice(0, 120),
      children: el.children.length,
    };
    if (props) result.extra = styles(el, props);
    return result;
  }
  function renderedColumns(el) {
    const kids = Array.prototype.slice.call(el.children).filter(visible);
    if (kids.length) {
      const top = Math.round(kids[0].getBoundingClientRect().top);
      return kids.filter(
        (k) => Math.abs(Math.round(k.getBoundingClientRect().top) - top) <= 2,
      ).length;
    }
    const cols = getComputedStyle(el).gridTemplateColumns;
    if (!cols || cols === 'none') return 0;
    const repeat = /^repeat\((\d+),/.exec(cols.trim());
    if (repeat) return Number(repeat[1]);
    return cols.trim().split(/\s+/).length;
  }
  function count(name) { return all(name).length; }
  /** How many children actually share the first row — which is the number a
   * reader counts. The declared track list is only a fallback, because a
   * `repeat()` value survives in the computed style of an element that is not
   * a grid container at all. */
  function gridColumns(name) {
    const el = one(name);
    if (!el) return 0;
    return renderedColumns(el);
  }

  // -- A. global frame ---------------------------------------------------
  out.sidebar = region('sidebar');
  out.main = region('main');
  out.canvas = region('canvas');
  out.pageScroll = {
    horizontal: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    vertical: document.documentElement.scrollHeight - document.documentElement.clientHeight,
    bodyOverflow: getComputedStyle(document.body).overflowY,
  };

  // A5 — every text node's resolved font family, and the weights in use.
  const families = {};
  const weights = {};
  let textNodes = 0;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      const tag = parent.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE') return NodeFilter.FILTER_REJECT;
      if (!visible(parent)) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const cs = getComputedStyle(n.parentElement);
    const fam = cs.fontFamily.split(',')[0].replace(/["']/g, '').trim();
    families[fam] = (families[fam] || 0) + 1;
    const w = cs.fontWeight;
    weights[w] = (weights[w] || 0) + 1;
    textNodes += 1;
  }
  // Placeholders and value-bearing controls carry text the walker cannot see.
  for (const ctrl of document.querySelectorAll('input, textarea, select')) {
    if (!visible(ctrl)) continue;
    const cs = getComputedStyle(ctrl);
    const fam = cs.fontFamily.split(',')[0].replace(/["']/g, '').trim();
    families[fam] = (families[fam] || 0) + 1;
    weights[cs.fontWeight] = (weights[cs.fontWeight] || 0) + 1;
    textNodes += 1;
  }
  out.fonts = { families, weights, textNodes };

  // A4 — the declared scrollbar treatment. Headless Chromium draws overlay
  // scrollbars, so a measured gutter is 0 on both sides and says nothing; the
  // rule the stylesheet declares is the fact that survives.
  out.scrollbarRules = (() => {
    const widths = [];
    const selectors = [];
    let scrollbarWidth = 'auto';
    const canvasEl = one('canvas');
    if (canvasEl) scrollbarWidth = getComputedStyle(canvasEl).scrollbarWidth || 'auto';
    for (const sheet of Array.prototype.slice.call(document.styleSheets)) {
      let rules;
      try { rules = sheet.cssRules; } catch (e) { continue; } // cross-origin
      if (!rules) continue;
      for (const rule of Array.prototype.slice.call(rules)) {
        const sel = rule.selectorText;
        if (!sel || sel.indexOf('-webkit-scrollbar') === -1) continue;
        if (sel.indexOf('thumb') !== -1 || sel.indexOf('track') !== -1) continue;
        selectors.push(sel);
        const w = parseFloat(rule.style && rule.style.width);
        if (Number.isFinite(w)) widths.push(w);
      }
    }
    return { widths, selectors, scrollbarWidth };
  })();

  // -- B. sidebar --------------------------------------------------------
  out.brand = region('brand');
  out.brandLogo = { present: !!one('brandLogo'), box: box(one('brandLogo')) };
  out.brandText = { present: !!one('brandText'), lines: count('brandTextLine') };
  // B1 scores the ABSENCE of the wordmark/tagline lines since the
  // 2026-09-18 correction, so the count has to be reachable on its own.
  out.brandTextLine = { n: count('brandTextLine') };
  out.dirHead = region('dirHead');
  out.agentCount = { present: !!one('agentCount'), box: box(one('agentCount')) };
  out.searchBox = region('searchBox');
  out.searchInput = region('searchInput');
  out.searchIcon = { present: !!one('searchIcon'), box: box(one('searchIcon')) };
  out.agentList = region('agentList');
  out.agentItems = (() => {
    const items = all('agentItem');
    return {
      n: items.length,
      first: items[0] ? box(items[0]) : null,
      parts: items[0]
        ? {
          icon: !!items[0].querySelector(selectors.agentItemIcon || '\\0'),
          name: !!items[0].querySelector(selectors.agentItemName || '\\0'),
          desc: !!items[0].querySelector(selectors.agentItemDesc || '\\0'),
          dot: !!items[0].querySelector(selectors.agentItemDot || '\\0'),
        }
        : null,
    };
  })();
  out.recentWork = region('recentWork');
  out.recentToggle = (() => {
    const el = one('recentToggle');
    return el
      ? { present: true, box: box(el), expanded: el.getAttribute('aria-expanded') }
      : { present: false };
  })();
  // The buttons the History header carries beside its own collapse toggle.
  out.recentActions = count('recentAction');
  out.profile = region('profile');
  out.profileParts = {
    avatar: box(one('profileAvatar')),
    dot: box(one('profileDot')),
    name: box(one('profileName')),
    role: box(one('profileRole')),
    cog: box(one('profileCog')),
  };

  // -- C. landing --------------------------------------------------------
  out.landing = region('landing');
  out.pageHeader = region('pageHeader');
  out.pageTitle = { box: box(one('pageTitle')) };
  out.pageSubtitle = { box: box(one('pageSubtitle')) };
  out.statusStrip = region('statusStrip');
  out.statusPills = { n: count('statusPill') };
  out.overview = region('overview');
  out.overviewHeader = region('overviewHeader');
  out.overviewGrid = { ...region('overviewGrid'), columns: gridColumns('overviewGrid') };
  out.overviewItems = { n: count('overviewItem'), steps: count('overviewStep') };
  out.scenarios = region('scenarios');
  out.scenariosHead = region('scenariosHead');
  out.scenariosTitle = { box: box(one('scenariosTitle')) };
  out.filterTabs = { ...region('filterTabs'), n: count('filterTab') };
  out.filterTabActive = (() => {
    const tabs = all('filterTab');
    const active = tabs.filter((t) => t.classList.contains('active')
      || t.getAttribute('aria-selected') === 'true'
      || t.getAttribute('aria-pressed') === 'true');
    if (!active.length || !tabs.length) return { n: active.length, distinct: false };
    const a = getComputedStyle(active[0]);
    const other = tabs.find((t) => !active.includes(t));
    if (!other) return { n: active.length, distinct: true };
    const b = getComputedStyle(other);
    return {
      n: active.length,
      distinct: a.backgroundColor !== b.backgroundColor || a.color !== b.color
        || a.borderColor !== b.borderColor,
    };
  })();
  out.scenarioGrid = { ...region('scenarioGrid'), columns: gridColumns('scenarioGrid') };
  out.scenarioCards = (() => {
    const cards = all('scenarioCard');
    if (!cards.length) return { n: 0 };
    const cs = getComputedStyle(cards[0]);
    return {
      n: cards.length,
      box: box(cards[0]),
      radius: px(cs.borderTopLeftRadius),
      border: px(cs.borderTopWidth),
      parts: {
        tag: !!cards[0].querySelector(selectors.scenarioTag || '\\0'),
        badge: !!cards[0].querySelector(selectors.scenarioBadge || '\\0'),
        title: !!cards[0].querySelector(selectors.scenarioTitle || '\\0'),
        desc: !!cards[0].querySelector(selectors.scenarioDesc || '\\0'),
        run: !!cards[0].querySelector(selectors.scenarioRun || '\\0'),
      },
    };
  })();

  // -- D. conversation and results --------------------------------------
  out.feed = region('feed');
  out.turns = (() => {
    const users = all('turnUser');
    const assistants = all('turnAssistant');
    const feedEl = one('feed');
    const feedBox = feedEl ? feedEl.getBoundingClientRect() : null;
    const inner = feedEl
      ? feedBox.width - px(getComputedStyle(feedEl).paddingLeft)
        - px(getComputedStyle(feedEl).paddingRight)
      : 0;
    const bubble = users[0] ? users[0].querySelector(selectors.userBubble || '\\0') : null;
    return {
      user: users.length,
      assistant: assistants.length,
      userBox: users[0] ? box(users[0]) : null,
      userBubbleBox: bubble ? box(bubble) : null,
      // "right-aligned" measured as the gap on each side of the bubble.
      userBubbleGapLeft: bubble && feedBox
        ? round(bubble.getBoundingClientRect().left - feedBox.left) : null,
      userBubbleGapRight: bubble && feedBox
        ? round(feedBox.right - bubble.getBoundingClientRect().right) : null,
      assistantBox: assistants[0] ? box(assistants[0]) : null,
      assistantFillsWidth: assistants[0] && inner
        ? round(assistants[0].getBoundingClientRect().width / inner) : null,
    };
  })();
  out.responseCard = (() => {
    const el = one('responseCard');
    if (!el) return { present: false };
    const cs = getComputedStyle(el);
    const feedEl = one('feed');
    const inner = feedEl
      ? feedEl.getBoundingClientRect().width - px(getComputedStyle(feedEl).paddingLeft)
        - px(getComputedStyle(feedEl).paddingRight)
      : 0;
    return {
      present: true,
      box: box(el),
      radius: px(cs.borderTopLeftRadius),
      border: px(cs.borderTopWidth),
      shadow: cs.boxShadow !== 'none' && cs.boxShadow !== '',
      widthRatio: inner ? round(el.getBoundingClientRect().width / inner) : null,
    };
  })();
  out.cardHeader = (() => {
    const el = one('cardHeader');
    if (!el) return { present: false };
    return {
      present: true,
      box: box(el),
      left: box(one('cardHeaderLeft')),
      right: box(one('cardHeaderRight')),
      chips: count('cardHeaderChip'),
    };
  })();
  out.expandChip = (() => {
    const el = one('expandChip');
    return el ? { present: true, box: box(el), visible: visible(el) } : { present: false };
  })();
  out.pendingTurn = (() => {
    const el = one('pendingTurn');
    return el ? { present: true, box: box(el), visible: visible(el) } : { present: false };
  })();

  // -- E. composer -------------------------------------------------------
  out.composer = region('composer');
  out.composerInput = region('composerInput');
  out.composerSend = { box: box(one('composerSend')) };
  out.composerControls = (() => {
    const controls = all('composerControl').filter(visible);
    const send = one('composerSend');
    const sendBox = send ? send.getBoundingClientRect() : null;
    const rows = new Set();
    for (const c of controls) rows.add(Math.round(c.getBoundingClientRect().top / 8));
    if (sendBox) rows.add(Math.round(sendBox.top / 8));
    return {
      n: controls.length,
      rows: rows.size,
      allLeftOfSend: sendBox
        ? controls.every((c) => c.getBoundingClientRect().right <= sendBox.left + 1)
        : null,
      boxes: controls.map(box),
    };
  })();

  // -- F. overlays -------------------------------------------------------
  out.fullscreen = (() => {
    const el = one('fullscreen');
    if (!el) return { present: false };
    const r = el.getBoundingClientRect();
    return {
      present: true,
      visible: visible(el),
      box: box(el),
      coversViewport: r.width >= window.innerWidth - 1 && r.height >= window.innerHeight - 1,
      icon: !!one('fsIcon'),
      title: !!one('fsTitle'),
      badges: count('fsBadge'),
      subtitle: !!one('fsSubtitle'),
      exit: box(one('fsExit')),
      kbdHint: !!one('fsKbd'),
      canvas: region('fsCanvas'),
    };
  })();
  out.modal = (() => {
    const el = one('modal');
    if (!el) return { present: false };
    const card = one('modalCard');
    const cardBox = card ? card.getBoundingClientRect() : null;
    return {
      present: true,
      visible: visible(el),
      box: box(el),
      card: card ? region('modalCard') : { present: false },
      centered: cardBox
        ? {
          dx: round(Math.abs((cardBox.left + cardBox.right) / 2 - window.innerWidth / 2)),
          dy: round(Math.abs((cardBox.top + cardBox.bottom) / 2 - window.innerHeight / 2)),
        }
        : null,
      icon: !!one('modalIcon'),
      title: !!one('modalTitle'),
      subtitle: !!one('modalSubtitle'),
      close: !!one('modalClose'),
      tabs: count('modalTab'),
      tabStrip: box(one('modalTabStrip')),
      // F2 scores the settings rail since the 2026-09-18 correction: the
      // gear opens the dialog and the menu runs down its left side.
      nav: box(one('settingsNav')),
      navItems: count('settingsNavItem'),
      body: box(one('modalBody')),
      footer: box(one('modalFooter')),
    };
  })();

  return out;
}

/**
 * Responsive-checklist measurements (SC-012). Separate from `probePage`
 * because these are pass/fail facts about one viewport rather than paired
 * dimensions, and several of them are expensive.
 */
export function probeResponsive(input) {
  const selectors = input.selectors;
  const opts = input.options || {};
  const minTarget = opts.minTouchTarget || 44;
  const out = { viewport: { w: window.innerWidth, h: window.innerHeight } };

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none' || Number(cs.opacity) <= 0.01) {
      return false;
    }
    // An off-canvas drawer is still laid out: its controls have boxes, all in
    // the same place, entirely outside the viewport. Treating them as on
    // screen would report every one of them as overlapping every other.
    if (r.right <= 0 || r.left >= window.innerWidth
      || r.bottom <= 0 || r.top >= window.innerHeight) return false;
    // Same for a row scrolled past the end of the list it lives in: it has a
    // box, but it is behind whatever comes after the list.
    const scroller = nearestScroller(el);
    if (scroller) {
      const s = scroller.getBoundingClientRect();
      if (r.bottom <= s.top || r.top >= s.bottom
        || r.right <= s.left || r.left >= s.right) return false;
    }
    return true;
  }
  /** The nearest ancestor that scrolls or clips — the box this element is
   * actually seen through. */
  function nearestScroller(el) {
    let node = el.parentElement;
    while (node && node !== document.body) {
      const cs = getComputedStyle(node);
      // A fixed-position subtree escapes every scroller above it, so the walk
      // ends there rather than reporting the page frame as its clipper.
      if (cs.position === 'fixed') return null;
      const flow = cs.overflow + cs.overflowX + cs.overflowY;
      if (flow.indexOf('auto') !== -1 || flow.indexOf('scroll') !== -1
        || flow.indexOf('hidden') !== -1) return node;
      node = node.parentElement;
    }
    return null;
  }
  function label(el) {
    const id = el.id ? `#${el.id}` : '';
    const cls = el.className && typeof el.className === 'string'
      ? `.${el.className.trim().split(/\s+/).slice(0, 2).join('.')}` : '';
    return `${el.tagName.toLowerCase()}${id}${cls}`;
  }

  // R1 — no horizontal page scroll.
  out.horizontalScroll = document.documentElement.scrollWidth
    - document.documentElement.clientWidth;

  // R1 (cause) — elements sticking out past the viewport's right edge.
  out.overflowing = [];
  for (const el of document.querySelectorAll('body *')) {
    if (!visible(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0) continue;
    if (r.right > window.innerWidth + 1 || r.left < -1) {
      const cs = getComputedStyle(el);
      if (cs.position === 'fixed' && r.width >= window.innerWidth) continue;
      out.overflowing.push({ el: label(el), left: Math.round(r.left), right: Math.round(r.right) });
    }
  }
  out.overflowing = out.overflowing.slice(0, 25);

  // R10 — interactive controls big enough to hit.
  out.smallTargets = [];
  const interactive = 'button, a[href], input:not([type=hidden]), select, textarea, '
    + '[role=button], [role=tab], [tabindex]:not([tabindex="-1"])';
  for (const el of document.querySelectorAll(interactive)) {
    if (!visible(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width + 0.5 < minTarget || r.height + 0.5 < minTarget) {
      out.smallTargets.push({
        el: label(el), w: Math.round(r.width), h: Math.round(r.height),
      });
    }
  }
  out.smallTargets = out.smallTargets.slice(0, 40);

  // R11 — controls overlapping one another, and controls clipped by an
  // ancestor with hidden overflow.
  out.overlaps = [];
  out.clipped = [];
  const controls = Array.prototype.slice
    .call(document.querySelectorAll(interactive)).filter(visible);
  /** The part of an element a reader can actually see: its rect clamped to
   * the scroller it sits in. A row half-scrolled out of a list does not
   * overlap what is below the list. */
  function seenRect(el) {
    const r = el.getBoundingClientRect();
    const host = nearestScroller(el);
    if (!host) return r;
    const s = host.getBoundingClientRect();
    return {
      left: Math.max(r.left, s.left), right: Math.min(r.right, s.right),
      top: Math.max(r.top, s.top), bottom: Math.min(r.bottom, s.bottom),
    };
  }
  for (let i = 0; i < controls.length; i += 1) {
    const a = seenRect(controls[i]);
    for (let j = i + 1; j < controls.length; j += 1) {
      if (controls[i].contains(controls[j]) || controls[j].contains(controls[i])) continue;
      const b = seenRect(controls[j]);
      const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left);
      const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
      if (ox > 2 && oy > 2) {
        out.overlaps.push({ a: label(controls[i]), b: label(controls[j]) });
      }
    }
    // Only a hidden ancestor truly clips: content inside a scroller is one
    // scroll away, which is how a list is supposed to work. A fixed-position
    // element is not clipped by an ancestor's overflow at all.
    const own = getComputedStyle(controls[i]).position;
    const host = own === 'fixed' ? null : nearestScroller(controls[i]);
    if (host) {
      const cs = getComputedStyle(host);
      const flow = cs.overflow + cs.overflowX + cs.overflowY;
      const scrolls = flow.indexOf('auto') !== -1 || flow.indexOf('scroll') !== -1;
      if (!scrolls) {
        const p = host.getBoundingClientRect();
        if (a.right > p.right + 1 || a.left < p.left - 1
          || a.bottom > p.bottom + 1 || a.top < p.top - 1) {
          out.clipped.push({ el: label(controls[i]), by: label(host) });
        }
      }
    }
  }
  out.overlaps = out.overlaps.slice(0, 25);
  out.clipped = out.clipped.slice(0, 25);

  // R9 — chart and readout text legibility.
  out.tinyText = [];
  const chartSel = selectors.chartText || 'svg text, .astral-chart text';
  for (const el of document.querySelectorAll(chartSel)) {
    if (!visible(el)) continue;
    const size = parseFloat(getComputedStyle(el).fontSize);
    if (size < 11) out.tinyText.push({ el: label(el), size: Math.round(size * 10) / 10 });
  }
  out.tinyText = out.tinyText.slice(0, 25);

  // R8 — tables scroll inside their own container, never past the card.
  out.tableOverflow = [];
  for (const table of document.querySelectorAll(selectors.table || 'table')) {
    if (!visible(table)) continue;
    let host = table.parentElement;
    let scroller = null;
    while (host && host !== document.body) {
      const cs = getComputedStyle(host);
      if (cs.overflowX === 'auto' || cs.overflowX === 'scroll') { scroller = host; break; }
      host = host.parentElement;
    }
    const card = table.closest(selectors.responseCard || '.astral-response-card');
    if (card) {
      const t = table.getBoundingClientRect();
      const c = card.getBoundingClientRect();
      if (t.right > c.right + 1 && !scroller) {
        out.tableOverflow.push({ el: label(table), by: Math.round(t.right - c.right) });
      }
    }
  }

  // R2 / R3 — sidebar width, or the drawer that replaces it.
  const sidebar = document.querySelector(selectors.sidebar);
  out.sidebar = sidebar
    ? {
      visible: visible(sidebar),
      w: Math.round(sidebar.getBoundingClientRect().width),
      x: Math.round(sidebar.getBoundingClientRect().x),
      position: getComputedStyle(sidebar).position,
    }
    : null;
  const toggle = selectors.drawerToggle
    ? document.querySelector(selectors.drawerToggle) : null;
  out.drawerToggle = toggle
    ? {
      visible: visible(toggle),
      box: toggle.getBoundingClientRect().toJSON(),
      expanded: toggle.getAttribute('aria-expanded'),
    }
    : null;
  const canvas = document.querySelector(selectors.canvas);
  out.canvasPadding = canvas
    ? [
      parseFloat(getComputedStyle(canvas).paddingTop),
      parseFloat(getComputedStyle(canvas).paddingRight),
    ]
    : null;

  // R4 — composer pinned, above the safe-area inset, Send always visible.
  const composer = document.querySelector(selectors.composer);
  const send = document.querySelector(selectors.composerSend);
  out.composer = composer
    ? {
      position: getComputedStyle(composer).position,
      bottom: Math.round(composer.getBoundingClientRect().bottom),
      paddingBottom: getComputedStyle(composer).paddingBottom,
      // `env(safe-area-inset-bottom)` is already resolved to px by the time
      // computed style sees it, so the wiring is observed through the custom
      // property the stylesheet defines from it.
      safeAreaToken: getComputedStyle(composer)
        .getPropertyValue('--astral-safe-bottom').trim(),
      sendVisible: !!send && visible(send),
    }
    : null;
  out.overflowMenu = selectors.composerOverflow
    ? !!document.querySelector(selectors.composerOverflow) : null;

  // R5 / R7 — column counts.
  function columnsOf(sel) {
    const el = sel && document.querySelector(sel);
    if (!el) return null;
    const kids = Array.prototype.slice.call(el.children).filter(visible);
    if (kids.length) {
      const top = Math.round(kids[0].getBoundingClientRect().top);
      return kids.filter(
        (k) => Math.abs(Math.round(k.getBoundingClientRect().top) - top) <= 2,
      ).length;
    }
    const cols = getComputedStyle(el).gridTemplateColumns;
    if (!cols || cols === 'none') return null;
    const repeat = /^repeat\((\d+),/.exec(cols.trim());
    if (repeat) return Number(repeat[1]);
    return cols.trim().split(/\s+/).length;
  }
  out.columns = {
    scenarioGrid: columnsOf(selectors.scenarioGrid),
    overviewGrid: columnsOf(selectors.overviewGrid),
    componentGrid: columnsOf(selectors.componentGrid),
  };

  // R13 — reduced motion honoured, and a visible focus ring.
  out.reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  out.animatedUnderReducedMotion = [];
  if (out.reducedMotion) {
    for (const el of document.querySelectorAll('body *')) {
      if (!visible(el)) continue;
      const cs = getComputedStyle(el);
      const dur = parseFloat(cs.animationDuration) + parseFloat(cs.transitionDuration);
      if (dur > 0.05) out.animatedUnderReducedMotion.push({ el: label(el), dur });
    }
    out.animatedUnderReducedMotion = out.animatedUnderReducedMotion.slice(0, 15);
  }

  return out;
}
