/**
 * Feature 089 (T047): the parity contract, expressed as code.
 *
 * `contracts/web-layout-parity.md` in AstralDeep lists 27 scored items across
 * six groups, weighted to 100. This file carries the same 27 items with the
 * selectors that locate each region on each side and the rule that turns two
 * measurements into Pass / Partial / Fail.
 *
 * Per the contract:
 *   - Partial means the position or structure matches but a dimension is off
 *     by more than the tolerance;
 *   - the tolerance is ±8% or ±8px, whichever is larger;
 *   - colors are excluded (they come from `ThemeView`);
 *   - content differences are excluded (real agents, real welcome examples).
 *
 * Items whose a8p counterpart does not exist (the 088 "recent work" section)
 * carry `referenceOptional`, and are then scored on the contract's own
 * structural description instead of against a reference measurement.
 */

export const TOLERANCE_PX = 8;
export const TOLERANCE_RATIO = 0.08;

/** a8p's console — the reference. */
export const REFERENCE_SELECTORS = {
  sidebar: '#sidebar',
  main: '#main-content',
  canvas: '#canvas-area',

  brand: '.brand',
  brandLogo: '.brand-logo-img',
  brandText: '.brand-text',
  brandTextLine: '.brand-text h2, .brand-text span',
  dirHead: '.sidebar-header',
  agentCount: '#agent-count',
  searchBox: '.sidebar-search-box',
  searchInput: '#agent-search',
  searchIcon: '.sidebar-search-icon',
  agentList: '#agent-list-container',
  agentItem: '.agent-card',
  agentItemIcon: '.agent-icon',
  agentItemName: '.agent-name',
  agentItemDesc: '.agent-desc',
  agentItemDot: '.agent-status-pill',
  recentWork: null, // a8p has no 088 recent-work section
  recentToggle: null,
  profile: '#user-profile-box',
  recentAction: '.astral-recent-actions button:not(.astral-recent-toggle)',
  profileAvatar: '.user-avatar-container',
  profileDot: '.user-online-dot',
  profileName: '#user-display-name',
  profileRole: '#user-display-role',
  profileCog: '#open-settings-btn',

  landing: '#dashboard-landing',
  pageHeader: '.dash-header',
  pageTitle: '.dash-title-block h1',
  pageSubtitle: '.dash-title-block p',
  statusStrip: '.dash-status-strip',
  statusPill: '.dash-status-strip .status-pill',
  overview: '.overview-panel',
  overviewHeader: '.overview-panel-header',
  overviewGrid: '.overview-grid',
  overviewItem: '.overview-item',
  overviewStep: '.overview-step',
  scenarios: '.scenarios-section',
  scenariosHead: '.scenarios-header-bar',
  scenariosTitle: '.scenarios-section-title',
  filterTabs: '.filter-tabs-row',
  filterTab: '.filter-tab-btn',
  scenarioGrid: '.scenario-grid',
  scenarioCard: '.scenario-card',
  scenarioTag: '.scenario-agent-tag',
  scenarioBadge: '.scenario-cat-badge',
  scenarioTitle: '.scenario-title',
  scenarioDesc: '.scenario-desc',
  scenarioRun: '.btn-scenario-run',

  feed: '.chat-thread-wrapper',
  turnUser: '.chat-turn-user',
  turnAssistant: '.chat-turn-assistant',
  userBubble: '.chat-bubble-user',
  responseCard: '.chat-turn-assistant .sdui-widget-container',
  cardHeader: '.chat-turn-assistant .chat-assistant-meta-bar',
  cardHeaderLeft: '.chat-turn-assistant .chat-agent-info',
  cardHeaderRight: '.chat-turn-assistant .chat-assistant-meta-bar > div:last-child',
  cardHeaderChip: '.chat-turn-assistant .chat-assistant-meta-bar .badge',
  expandChip: '.sdui-widget-expand-chip',
  pendingTurn: '#eval-loading-turn',

  composer: '#composer-bar',
  composerInput: '#prompt-input',
  composerSend: '#send-btn',
  composerControl: '#composer-bar button:not(#send-btn)',

  fullscreen: '#sdui-fullscreen-overlay',
  fsIcon: '#sdui-fs-icon',
  fsTitle: '#sdui-fs-agent-name',
  fsBadge: '.sdui-fs-title-row .badge',
  fsSubtitle: '#sdui-fs-sub',
  fsExit: '.btn-sdui-fs-exit',
  fsKbd: '.sdui-fs-kbd',
  fsCanvas: '.sdui-fs-canvas-wrapper',

  modal: '#settings-modal-overlay',
  modalCard: '#settings-modal-overlay .modal-card',
  modalIcon: '.modal-icon-badge',
  modalTitle: '.modal-title',
  modalSubtitle: '.modal-subtitle',
  modalClose: '.modal-close-btn',
  modalTabStrip: '.modal-tabs',
  modalTab: '.modal-tab-btn',
  modalBody: '.modal-body',
  modalFooter: '.modal-footer',

  chartText: 'svg text',
  table: 'table.astral-table, table',
  componentGrid: '.grid-container',
  drawerToggle: null,
  composerOverflow: null,
};

/** The Astral web client — the candidate. */
export const CANDIDATE_SELECTORS = {
  sidebar: '#astral-sidebar',
  main: '#astral-main',
  canvas: '#astral-canvas',

  brand: '#astral-brand',
  brandLogo: '#astral-brand img',
  brandText: '.astral-brand-text',
  brandTextLine: '.astral-brand-name, .astral-brand-sub',
  // The account row is the gear alone; the identity it used to print heads
  // the settings dialog instead (see the 2026-09-18 contract correction).
  profileIdentity: '#astral-profile-name, #astral-profile-role, .astral-profile-avatar',
  dirHead: '#astral-dir-head',
  agentCount: '#astral-agent-count',
  searchBox: '.astral-search-box',
  searchInput: '#astral-agent-search',
  searchIcon: '.astral-search-icon',
  agentList: '#astral-agent-list',
  agentItem: '.astral-agent-item',
  agentItemIcon: '.astral-agent-icon',
  settingsNav: '.astral-settings-nav',
  settingsNavItem: '.astral-settings-nav-item',
  agentItemName: '.astral-agent-name',
  agentItemDesc: '.astral-agent-desc',
  agentItemDot: '.astral-agent-dot',
  recentWork: '#astral-recent-work',
  recentToggle: '#astral-recent-toggle',
  profile: '#astral-profile',
  recentAction: '.astral-recent-actions button:not(.astral-recent-toggle)',
  profileAvatar: '.astral-profile-avatar',
  profileDot: '.astral-profile-dot',
  profileName: '#astral-profile-name',
  profileRole: '#astral-profile-role',
  profileCog: '#astral-settings-btn',

  landing: '#astral-landing',
  pageHeader: '.astral-page-header',
  pageTitle: '.astral-page-title',
  pageSubtitle: '.astral-page-subtitle',
  statusStrip: '.astral-status-strip',
  statusPill: '.astral-status-strip .astral-status-pill',
  overview: '#astral-overview',
  overviewHeader: '.astral-overview-header',
  overviewGrid: '.astral-overview-grid',
  overviewItem: '.astral-overview-item',
  overviewStep: '.astral-overview-step',
  scenarios: '#astral-scenarios',
  scenariosHead: '.astral-scenarios-head',
  scenariosTitle: '.astral-scenarios-title',
  filterTabs: '.astral-filter-tabs',
  filterTab: '.astral-filter-tab',
  scenarioGrid: '#astral-scenario-grid',
  scenarioCard: '.astral-scenario-card',
  scenarioTag: '.astral-scenario-tag',
  scenarioBadge: '.astral-scenario-badge',
  scenarioTitle: '.astral-scenario-title',
  scenarioDesc: '.astral-scenario-desc',
  scenarioRun: '.astral-scenario-run',

  feed: '#astral-chat',
  turnUser: '.astral-turn-user',
  turnAssistant: '.astral-turn-assistant',
  userBubble: '.astral-user-bubble',
  responseCard: '.astral-response-card',
  cardHeader: '.astral-response-card > .astral-card-head',
  cardHeaderLeft: '.astral-response-card > .astral-card-head > .astral-card-head-left',
  cardHeaderRight: '.astral-response-card > .astral-card-head > .astral-card-head-right',
  cardHeaderChip: '.astral-response-card > .astral-card-head .astral-meta-chip',
  expandChip: '.astral-expand-chip',
  pendingTurn: '#astral-pending-turn',

  composer: '#astral-composer',
  composerInput: '#astral-input',
  composerSend: '#astral-send-btn',
  composerControl: '#astral-composer button:not(#astral-send-btn)',

  fullscreen: '#astral-fullscreen',
  fsIcon: '.astral-fs-icon',
  fsTitle: '#astral-fs-title',
  fsBadge: '.astral-fs-title-row .astral-badge',
  fsSubtitle: '#astral-fs-sub',
  fsExit: '#astral-fs-exit',
  fsKbd: '.astral-fs-kbd',
  fsCanvas: '#astral-fs-canvas',

  // The host div has no box of its own; the overlay inside it is what
  // covers the viewport, which is what the reference measures too.
  modal: '#astral-modal .astral-modal-overlay',
  modalCard: '#astral-modal .astral-modal-card',
  modalIcon: '.astral-modal-icon',
  modalTitle: '.astral-modal-title',
  modalSubtitle: '.astral-modal-subtitle',
  modalClose: '.astral-modal-close',
  modalTabStrip: '.astral-modal-tabs',
  modalTab: '.astral-modal-tab',
  modalBody: '.astral-modal-body',
  modalFooter: '.astral-modal-footer',

  chartText: 'svg text',
  table: 'table',
  componentGrid: '.astral-grid',
  drawerToggle: '#astral-drawer-toggle',
  composerOverflow: '#astral-composer-more',
};

// -- scoring helpers -------------------------------------------------------

export function near(a, b) {
  if (a == null || b == null) return false;
  const tol = Math.max(TOLERANCE_PX, Math.abs(b) * TOLERANCE_RATIO);
  return Math.abs(a - b) <= tol;
}

/** Pass when every dimension is within tolerance, Partial when at least one
 * is not but the structure held, Fail when the structure did not. */
function dims(structureOk, pairs) {
  if (!structureOk) return { verdict: 'fail', detail: 'structure' };
  const bad = pairs.filter(([name, a, b]) => !near(a, b))
    .map(([name, a, b]) => `${name}: ${fmt(a)} vs ${fmt(b)}`);
  if (!bad.length) return { verdict: 'pass' };
  return { verdict: 'partial', detail: bad.join('; ') };
}
function fmt(n) { return n == null ? 'none' : Math.round(n * 10) / 10; }
function ok(condition, detail) {
  return condition ? { verdict: 'pass' } : { verdict: 'fail', detail: detail || '' };
}
function present(m) { return !!(m && m.present); }

/** Headless Chromium draws overlay scrollbars, so a measured gutter is 0 on
 * both sides. The declared rule is the observable fact instead. */
function thinScrollbar(m) {
  const r = m.scrollbarRules || { widths: [], scrollbarWidth: 'auto' };
  if (r.scrollbarWidth === 'thin') return true;
  return r.widths.some((w) => w > 0 && w <= 8);
}

// -- the 27 scored items ---------------------------------------------------

export const ITEMS = [
  // A. Global frame (14)
  {
    id: 'A1', group: 'A', weight: 4, auto: true, state: 'landing',
    title: 'Two-column frame, full height, no page scroll, canvas scrolls internally',
    score(ref, cand) {
      const structure = present(cand.sidebar) && present(cand.main)
        && cand.sidebar.box.x < cand.main.box.x
        && cand.main.box.w > cand.sidebar.box.w
        && cand.sidebar.box.h >= cand.viewport.h - 2
        && cand.pageScroll.vertical <= 1
        && (cand.canvas.overflowY === 'auto' || cand.canvas.overflowY === 'scroll');
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `sidebar@${cand.sidebar.box && cand.sidebar.box.x}, `
            + `sidebarH=${cand.sidebar.box && cand.sidebar.box.h}/${cand.viewport.h}, `
            + `pageScrollY=${cand.pageScroll.vertical}, canvasOverflow=${cand.canvas.overflowY}`,
        };
      }
      return dims(true, [['main.h', cand.main.box.h, ref.main.box.h]]);
    },
  },
  {
    id: 'A2', group: 'A', weight: 3, auto: true, state: 'landing',
    title: 'Sidebar 350px wide, right border, 22px padding, 16px vertical gap',
    score(ref, cand) {
      return dims(present(cand.sidebar) && cand.sidebar.borderRight > 0, [
        ['width', cand.sidebar.box.w, ref.sidebar.box.w],
        ['padding-top', cand.sidebar.padding[0], ref.sidebar.padding[0]],
        ['padding-left', cand.sidebar.padding[3], ref.sidebar.padding[3]],
        ['gap', cand.sidebar.gap, ref.sidebar.gap],
      ]);
    },
  },
  {
    id: 'A3', group: 'A', weight: 2, auto: false, state: 'landing',
    title: 'Main column background is a theme-derived radial gradient anchored top-center',
    score(ref, cand) {
      const has = (cand.main.backgroundImage || '').includes('radial-gradient')
        || (cand.canvas.backgroundImage || '').includes('radial-gradient');
      return ok(has, `background-image=${cand.main.backgroundImage}`);
    },
  },
  {
    id: 'A4', group: 'A', weight: 2, auto: true, state: 'landing',
    title: 'Canvas padding 32px 48px with a thin custom scrollbar',
    score(ref, cand) {
      const padding = dims(present(cand.canvas), [
        ['padding-top', cand.canvas.padding[0], ref.canvas.padding[0]],
        ['padding-right', cand.canvas.padding[1], ref.canvas.padding[1]],
        ['padding-left', cand.canvas.padding[3], ref.canvas.padding[3]],
      ]);
      if (padding.verdict !== 'pass') return padding;
      if (!thinScrollbar(cand)) {
        return { verdict: 'partial', detail: 'no thin scrollbar declared for the canvas' };
      }
      return { verdict: 'pass' };
    },
  },
  {
    id: 'A5', group: 'A', weight: 3, auto: true, state: 'landing',
    title: 'Open Sans on every text element; heading weights 700–800, body 400–600',
    score(ref, cand) {
      const fams = Object.keys(cand.fonts.families);
      const wrong = fams.filter((f) => f.toLowerCase() !== 'open sans');
      if (wrong.length) {
        const counts = wrong.map((f) => `${f}×${cand.fonts.families[f]}`).join(', ');
        return { verdict: 'fail', detail: `non-Open-Sans families: ${counts}` };
      }
      const weights = Object.keys(cand.fonts.weights).map(Number);
      const outside = weights.filter((w) => w < 400 || w > 800);
      return ok(!outside.length, `weights outside 400–800: ${outside.join(', ')}`);
    },
  },

  // B. Sidebar (22)
  {
    id: 'B1', group: 'B', weight: 4, auto: true, state: 'landing',
    title: 'Brand block: logo only (no product name or tagline), bottom divider, returns to landing',
    score(ref, cand) {
      // Owner directive 2026-09-18: the wordmark and tagline came off. The
      // logo, the divider and the return-to-landing behavior are what this
      // row still scores; the name/subtitle lines must be ABSENT.
      const structure = present(cand.brand) && cand.brandLogo.present
        && cand.brandTextLine.n === 0 && cand.brand.borderBottom > 0
        && cand.brand.box.y < cand.dirHead.box.y;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `logo=${cand.brandLogo.present}, textLines=${cand.brandTextLine.n}, `
            + `divider=${cand.brand.borderBottom}`,
        };
      }
      return dims(true, [
        ['logo.h', cand.brandLogo.box && cand.brandLogo.box.h,
          ref.brandLogo.box && ref.brandLogo.box.h],
      ]);
    },
  },
  {
    id: 'B2', group: 'B', weight: 3, auto: true, state: 'landing',
    title: 'Section header row with a right-aligned count badge',
    score(ref, cand) {
      const structure = present(cand.dirHead) && cand.agentCount.present
        && cand.dirHead.box.right - cand.agentCount.box.right <= 4;
      return dims(structure, [['header.h', cand.dirHead.box.h, ref.dirHead.box.h]]);
    },
  },
  {
    id: 'B3', group: 'B', weight: 4, auto: true, state: 'landing',
    title: 'Search input with a leading magnifier that filters the list live',
    score(ref, cand, ctx) {
      const structure = present(cand.searchInput) && cand.searchIcon.present
        && cand.searchIcon.box.x < cand.searchInput.box.x + cand.searchInput.padding[3] + 4
        && ctx.filtersLive === true;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `icon=${cand.searchIcon.present}, filtersLive=${ctx.filtersLive}`,
        };
      }
      return dims(true, [
        ['input.h', cand.searchInput.box.h, ref.searchInput.box.h],
        ['input.w', cand.searchInput.box.w, ref.searchInput.box.w],
      ]);
    },
  },
  {
    id: 'B4', group: 'B', weight: 5, auto: true, state: 'landing',
    title: 'Scrollable agent list filling the remaining height; name and description flush left, status dot',
    score(ref, cand) {
      // Owner directive 2026-09-18: no per-agent icon. The name and the
      // description start at the card's left padding instead, so the row
      // scores the absence of the icon and the presence of everything else.
      const p = cand.agentItems.parts;
      const structure = present(cand.agentList) && cand.agentItems.n > 0 && !!p
        && !p.icon && p.name && p.desc && p.dot
        && (cand.agentList.overflowY === 'auto' || cand.agentList.overflowY === 'scroll');
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `items=${cand.agentItems.n}, parts=${JSON.stringify(p)}, `
            + `overflow=${cand.agentList.overflowY}`,
        };
      }
      return dims(true, [['item.h', cand.agentItems.first.h, ref.agentItems.first.h]]);
    },
  },
  {
    id: 'B5', group: 'B', weight: 2, auto: true, state: 'landing', referenceOptional: true,
    title: 'History section above the agent directory, collapsible',
    score(ref, cand) {
      // Owner directive 2026-09-21: History and the agent directory switched
      // places — History sits on top, with the agent directory below.
      const structure = present(cand.recentWork) && cand.recentToggle.present
        && cand.recentWork.box.bottom <= cand.agentList.box.y + 2
        && cand.recentToggle.expanded !== null
        && cand.recentActions === 1;
      return ok(structure, `present=${present(cand.recentWork)}, `
        + `toggle=${cand.recentToggle.present}, expanded=${cand.recentToggle.expanded}, `
        + `buttons=${cand.recentActions}`);
    },
  },
  {
    id: 'B6', group: 'B', weight: 4, auto: true, state: 'landing',
    title: 'Account row pinned to the sidebar bottom: picture, name, role, settings cog',
    score(ref, cand) {
      // Owner directive 2026-09-18 took the identity off this row; the
      // owner's 2026-09-19 walkthrough put it back, because a console with no
      // sign of whose account it is reads as signed out. The dialog still
      // heads itself with the same identity, from the same derivation.
      const p = cand.profileParts;
      const structure = present(cand.profile) && p.cog && p.avatar && p.name && p.role
        && cand.sidebar.box.bottom - cand.profile.box.bottom <= cand.sidebar.padding[2] + 4
        && cand.profile.box.right - p.cog.right <= 20
        && p.avatar.right <= p.name.left;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `cog=${!!p.cog}, missing=`
            + `${['avatar', 'name', 'role'].filter((k) => !p[k]).join(',') || 'none'}; `
            + `bottomGap=${cand.sidebar.box.bottom - cand.profile.box.bottom}`,
        };
      }
      return ok(true, 'identity then cog');
    },
  },

  // C. Landing (18)
  {
    id: 'C1', group: 'C', weight: 4, auto: true, state: 'landing', referenceOptional: true,
    title: 'Page header: title + subtitle left, status pill strip removed',
    score(ref, cand) {
      // Owner directive 2026-09-21: The status pill strip in the page header
      // is removed; the page header carries only the title and subtitle.
      const structure = present(cand.pageHeader) && cand.pageTitle.box && cand.pageSubtitle.box
        && (!present(cand.statusStrip) || cand.statusPills.n === 0)
        && cand.pageSubtitle.box.y >= cand.pageTitle.box.bottom - 2;
      if (!structure) {
        return { verdict: 'fail', detail: `header=${present(cand.pageHeader)}, statusStrip=${present(cand.statusStrip)}` };
      }
      return dims(true, [['header.h', cand.pageHeader.box.h, ref.pageHeader.box.h]]);
    },
  },
  {
    id: 'C2', group: 'C', weight: 3, auto: true, state: 'landing', referenceOptional: true,
    title: 'No explanatory overview panel between the page header and the examples',
    score(ref, cand) {
      // Owner directive 2026-09-18: the "How a turn runs" panel came off the
      // landing. The examples are the explanation. This row now scores its
      // ABSENCE, and that the examples sit directly under the page header.
      if (present(cand.overview)) {
        return { verdict: 'fail', detail: 'the overview panel is still rendered' };
      }
      const structure = present(cand.scenarios)
        && cand.scenarios.box.y >= cand.pageHeader.box.bottom - 2;
      return ok(structure, `scenariosTop=${cand.scenarios.box && cand.scenarios.box.y}, `
        + `headerBottom=${cand.pageHeader.box && cand.pageHeader.box.bottom}`);
    },
  },
  {
    id: 'C3', group: 'C', weight: 4, auto: true, state: 'landing',
    title: 'Scenarios header: title left, horizontal filter tabs with the active one highlighted',
    score(ref, cand) {
      const structure = present(cand.scenariosHead) && cand.scenariosTitle.box
        && cand.filterTabs.n >= 3 && cand.filterTabActive.n === 1
        && cand.filterTabActive.distinct
        && cand.scenariosTitle.box.x < cand.filterTabs.box.x
        && cand.filterTabs.box.h <= cand.scenariosHead.box.h + 2;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `tabs=${cand.filterTabs.n}, active=${cand.filterTabActive.n}, `
            + `distinct=${cand.filterTabActive.distinct}`,
        };
      }
      return dims(true, [['tab.h', cand.filterTabs.box.h, ref.filterTabs.box.h]]);
    },
  },
  {
    id: 'C4', group: 'C', weight: 5, auto: true, state: 'landing',
    title: 'Scenario card grid: same auto-fit column count as the reference, 12px radius, tag + badge + title + description + run, hover lift',
    score(ref, cand, ctx) {
      const expected = ref.scenarioGrid.columns;
      const parts = cand.scenarioCards.parts || {};
      const structure = cand.scenarioCards.n > 0
        && cand.scenarioGrid.columns === expected
        && parts.tag && parts.badge && parts.title && parts.desc && parts.run
        && ctx.cardHoverLift === true;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `columns=${cand.scenarioGrid.columns} (want ${expected}), `
            + `parts=${JSON.stringify(parts)}, hoverLift=${ctx.cardHoverLift}`,
        };
      }
      return dims(true, [
        ['radius', cand.scenarioCards.radius, 12],
        ['card.w', cand.scenarioCards.box.w, ref.scenarioCards.box.w],
      ]);
    },
  },
  {
    id: 'C5', group: 'C', weight: 2, auto: true, state: 'conversation',
    title: 'Landing hides once a conversation has a response and returns on "return to dashboard"',
    score(ref, cand, ctx) {
      return ok(
        cand.landing.present && !cand.landing.visible && ctx.landingReturns === true,
        `visibleDuringConversation=${cand.landing.visible}, returns=${ctx.landingReturns}`,
      );
    },
  },

  // D. Conversation and results (24)
  {
    id: 'D1', group: 'D', weight: 5, auto: true, state: 'conversation',
    title: 'Vertical feed, 24px gap; user turns right-aligned bubbles, assistant turns full width',
    score(ref, cand) {
      const t = cand.turns;
      const structure = present(cand.feed) && t.user > 0 && t.assistant > 0
        && t.userBubbleGapRight != null
        && t.userBubbleGapRight < t.userBubbleGapLeft
        && t.assistantFillsWidth >= 0.97;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `user=${t.user}, assistant=${t.assistant}, `
            + `bubbleGaps=${t.userBubbleGapLeft}/${t.userBubbleGapRight}, `
            + `assistantWidthRatio=${t.assistantFillsWidth}`,
        };
      }
      return dims(true, [['feed.gap', cand.feed.gap, 24]]);
    },
  },
  {
    id: 'D2', group: 'D', weight: 5, auto: true, state: 'conversation',
    title: 'Response card: 14px radius, bordered, elevated, full canvas width',
    score(ref, cand) {
      const c = cand.responseCard;
      const structure = c.present && c.border > 0 && c.shadow && c.widthRatio >= 0.97;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `border=${c.border}, shadow=${c.shadow}, widthRatio=${c.widthRatio}`,
        };
      }
      return dims(true, [['radius', c.radius, 14]]);
    },
  },
  {
    id: 'D3', group: 'D', weight: 4, auto: true, state: 'conversation',
    title: 'Card header: agent badge/name + routing meta chips left, actions right',
    score(ref, cand) {
      const h = cand.cardHeader;
      const structure = h.present && h.left && h.right && h.chips >= 1
        && h.left.x < h.right.x
        && h.box.right - h.right.right <= h.box.w * 0.08;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `left=${!!h.left}, right=${!!h.right}, chips=${h.chips}`,
        };
      }
      return dims(true, [['header.h', h.box.h, ref.cardHeader.box.h]]);
    },
  },
  {
    id: 'D4', group: 'D', weight: 3, auto: true, state: 'hover',
    title: 'Hover overlay with an expand chip that opens the full-screen view',
    score(ref, cand, ctx) {
      return ok(
        cand.expandChip.present && cand.expandChip.visible && ctx.expandOpensFullscreen === true,
        `chip=${cand.expandChip.present}/${cand.expandChip.visible}, `
        + `opens=${ctx.expandOpensFullscreen}`,
      );
    },
  },
  {
    id: 'D5', group: 'D', weight: 5, auto: false, state: 'conversation',
    title: 'Components inside cards use a8p component styling (tiles, SVG charts, gauges, steppers, sticky-header tables)',
    score(ref, cand, ctx) {
      const found = ctx.componentKinds || {};
      const wanted = ['metric', 'chart', 'gauge', 'stepper', 'table'];
      const missing = wanted.filter((k) => !found[k]);
      if (missing.length) {
        return { verdict: 'fail', detail: `missing component kinds: ${missing.join(', ')}` };
      }
      return ok(ctx.tableStickyHeader === true, `stickyHeader=${ctx.tableStickyHeader}`);
    },
  },
  {
    id: 'D6', group: 'D', weight: 2, auto: true, state: 'pending',
    title: 'Progress/thinking state shown inline at the position of the pending turn',
    score(ref, cand) {
      const p = cand.pendingTurn;
      const structure = p.present && p.visible && present(cand.feed)
        && p.box.y >= cand.feed.box.y - 1 && p.box.bottom <= cand.feed.box.bottom + 400;
      return ok(structure, `present=${p.present}, visible=${p.visible}`);
    },
  },

  // E. Composer (10)
  {
    id: 'E1', group: 'E', weight: 3, auto: true, state: 'landing',
    title: 'Composer bar pinned to the bottom of the main column: top border, blurred background, 18px 48px padding',
    score(ref, cand) {
      const structure = present(cand.composer) && cand.composer.borderTop > 0
        && cand.composer.hasBackdrop
        && Math.abs(cand.composer.box.bottom - cand.main.box.bottom) <= 2
        && Math.abs(cand.composer.box.w - cand.main.box.w) <= 2;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `borderTop=${cand.composer.borderTop}, backdrop=${cand.composer.hasBackdrop}, `
            + `bottomDelta=${cand.composer.box.bottom - cand.main.box.bottom}`,
        };
      }
      return dims(true, [
        ['padding-top', cand.composer.padding[0], ref.composer.padding[0]],
        ['padding-left', cand.composer.padding[3], ref.composer.padding[3]],
      ]);
    },
  },
  {
    id: 'E2', group: 'E', weight: 4, auto: true, state: 'landing',
    title: 'One wide input (10px radius, 14px 18px padding) with the primary Send button at its right',
    score(ref, cand) {
      const structure = present(cand.composerInput) && cand.composerSend.box
        && cand.composerSend.box.x > cand.composerInput.box.right - 1
        && cand.composerInput.box.w > cand.composer.box.w * 0.5;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `sendRightOfInput=${cand.composerSend.box
            && cand.composerSend.box.x > cand.composerInput.box.right - 1}`,
        };
      }
      return dims(true, [
        ['radius', cand.composerInput.radius, 10],
        ['padding-top', cand.composerInput.padding[0], 14],
        ['padding-left', cand.composerInput.padding[3], 18],
      ]);
    },
  },
  {
    id: 'E3', group: 'E', weight: 3, auto: true, state: 'landing',
    title: '088 composer controls inside the bar, left of Send, on one row at ≥1280px',
    score(ref, cand, ctx) {
      const c = cand.composerControls;
      const required = ctx.requiredComposerControls || 0;
      const structure = c.n >= required && c.allLeftOfSend === true && c.rows === 1;
      return ok(structure, `controls=${c.n} (need ${required}), `
        + `leftOfSend=${c.allLeftOfSend}, rows=${c.rows}`);
    },
  },

  // F. Overlays (12)
  {
    id: 'F1', group: 'F', weight: 6, auto: true, state: 'fullscreen',
    title: 'Full-screen result overlay: viewport-covering, icon badge, title row with badges, subtitle, exit + ESC hint, scrollable canvas',
    score(ref, cand) {
      const f = cand.fullscreen;
      const structure = f.present && f.visible && f.coversViewport && f.icon && f.title
        && f.badges >= 1 && f.subtitle && f.exit && f.kbdHint
        && (f.canvas.overflowY === 'auto' || f.canvas.overflowY === 'scroll');
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `covers=${f.coversViewport}, icon=${f.icon}, title=${f.title}, `
            + `badges=${f.badges}, subtitle=${f.subtitle}, exit=${!!f.exit}, kbd=${f.kbdHint}, `
            + `canvasOverflow=${f.canvas && f.canvas.overflowY}`,
        };
      }
      return dims(true, [['header.h', f.canvas.box.y, ref.fullscreen.canvas.box.y]]);
    },
  },
  {
    id: 'F2', group: 'F', weight: 6, auto: true, state: 'settings', referenceOptional: true,
    title: 'Settings dialog: centered card with slide-up (reduced motion respected), icon + title + close, left menu rail, right options pane',
    score(ref, cand, ctx) {
      // Owner directive 2026-09-18: the gear opens the dialog directly and
      // the menu is a rail down its left side, so this row scores the rail
      // and its pane rather than a8p's tab strip. The reference has no rail
      // to measure against, hence referenceOptional.
      const m = cand.modal;
      const structure = m.present && m.visible && m.icon && m.title && m.close
        && m.nav && m.navItems >= 4 && m.body
        && m.nav.right <= m.body.x + 1
        && m.centered && m.centered.dx <= 8
        && ctx.modalAnimates === true && ctx.modalReducedMotionStill === true;
      if (!structure) {
        return {
          verdict: 'fail',
          detail: `icon=${m.icon}, title=${m.title}, close=${m.close}, nav=${!!m.nav}, `
            + `navItems=${m.navItems}, railRight=${m.nav && m.nav.right}, `
            + `paneLeft=${m.body && m.body.x}, dx=${m.centered && m.centered.dx}, `
            + `animates=${ctx.modalAnimates}, stillUnderReducedMotion=${ctx.modalReducedMotionStill}`,
        };
      }
      return ok(true, `rail=${Math.round(m.nav.w)}px, items=${m.navItems}`);
    },
  },
];

export const TOTAL_WEIGHT = ITEMS.reduce((sum, item) => sum + item.weight, 0);

export const VERDICT_CREDIT = { pass: 1, partial: 0.5, fail: 0 };

/** The responsive checklist (SC-012) — pass/fail, 100% required. */
export const RESPONSIVE_VIEWPORTS = [
  { name: '1024x768', width: 1024, height: 768 },
  { name: '768x1024', width: 768, height: 1024 },
  { name: '390x844', width: 390, height: 844 },
  { name: '320x640', width: 320, height: 640 },
  { name: '1280x800@200%', width: 1280, height: 800, zoom: 2 },
];

export const DESKTOP_VIEWPORTS = [
  { name: '1920x1080', width: 1920, height: 1080 },
  { name: '1440x900', width: 1440, height: 900 },
  { name: '1280x800', width: 1280, height: 800 },
];

export const STATES = ['landing', 'conversation', 'hover', 'fullscreen', 'settings', 'pending'];
