# AstralDeep UI v2

Verified against the local source tree on 2026-09-25. The design started in
feature 089 and incorporates the owner's subsequent console refinements.
"UI v2" names this web experience, not Python package version `2.0`, a new
wire-protocol version, or a claim of native-client parity. The package remains
`0.1.0`; protocol identity is supplied separately by
[`astralprojection.protocol`](../src/astralprojection/protocol.py).

## What the user sees

| Region | Current behavior | Owning sources |
| --- | --- | --- |
| Desktop frame | Fixed left sidebar, flexible main canvas and bottom composer. The canvas scrolls internally. | [`shell.html`](../backend/webrender/templates/shell.html), [`astral.css`](../backend/webrender/static/astral.css) |
| Sidebar | Logo returns to the dashboard. Collapsible **History** precedes **Agent Directory**. History has one New chat action; the searchable directory shows names, descriptions and availability. | Shell, [`client.js`](../backend/webrender/static/client.js), [`renderer.py`](../backend/webrender/renderer.py) |
| Account and settings | Sidebar footer shows a default avatar, session name, role and settings cog. The cog opens a modal with a settings rail and content pane. Surface-specific tabs stay inside the pane. Sign out remains a link. | Shell, [`topbar.py`](../backend/webrender/chrome/topbar.py), [`settings_nav.py`](../backend/webrender/chrome/settings_nav.py), [`render_modal_shell`](../backend/webrender/chrome/__init__.py) |
| Dashboard | Console heading and subtitle, **Start here** examples and category filters. The header status strip and legacy welcome cards are absent; old welcome target slots remain mounted and hidden for transport compatibility. | Shell and `client.js` landing builder |
| Conversation | Right-aligned user messages and full-width assistant result cards. Result-card headers carry agent/routing details and actions, including expansion into a full-screen result view. | `client.js` response-card and full-screen handlers, `astral.css` |
| Composer | One growing message field, attachment, voice, **More options**, and Send. More options is present at every width and contains **Run in background**, **Advanced settings**, **Workspace timeline**, and **Pulse digest**. Selecting an option closes the menu; Escape closes it and returns focus. | Shell and `client.js` composer handlers |
| History feedback | A first message creates an optimistic history entry using its first four words. Server chat identity replaces the temporary identity; returned title changes animate. The saved-component star is visually absent. | `client.js` history rendering, `renderer.py`, `astral.css` |
| Provenance | Ordinary grounded and generated results have no repeated provenance footer. Estimated results retain their warning. Server provenance remains available to auditing and exports. | [`renderer.py`](../backend/webrender/renderer.py), [`test_provenance.py`](../tests/webrender/test_provenance.py) |

Agent directory selections request the server's agent introduction surface;
scenario actions enter the normal chat path. Displayed controls do not grant
authority. AstralDeep still supplies authorized state and enforces identity,
tool, PHI, egress, confirmation and audit policy.

The web settings rail now renders `model.menu` only. It no longer copies the
shared model's topbar actions into settings. **Recent work** remains in the
shared native/watch chrome model and its renderable surface, but has no direct
entry in this web rail. It is distinct from sidebar chat History and composer
Workspace timeline; do not document those three as interchangeable.

## Responsive and native scope

At 1280 CSS pixels and above the sidebar is 350 px. From 1024 through 1279 it
is 288 px with tighter canvas spacing. Below 1024 it becomes a drawer with an
accessible toggle, backdrop and Escape close. Below 768 the composer is fixed
at the bottom, result grids fold to one column, settings become full-viewport
sheets, and the settings rail becomes horizontal scrolling navigation.

The web uses self-hosted Open Sans and the existing semantic theme variables.
ROTE selects adaptations from device profiles and declared supported types.
The six feature-089 types (`action_group`, `stat_group`, `gauge`,
`pipeline_stepper`, `donut_chart`, `radar_chart`) have server-side fallback
ladders for clients that do not support them.

Apple/SwiftUI and Android/Compose now negotiate `console/v2` and consume the
shared console catalog, labels, identity, selection and ROTE presentation.
[`console_model.py`](../backend/webrender/chrome/console_model.py) defines the
console data; [`console.py`](../backend/rote/console.py) adapts its geometry.
The existing chrome menu still owns available settings and actions. Measured
viewport, display scale, input, motion and voice capabilities update through
the existing device transport. Clients retain owner, request and connection
fences when navigating, reconnecting or applying delayed responses.

Settled result layouts refresh through a negotiated `update_device` hydration.
The client opens a fresh request tied to the current owner, connection, chat and
semantic revision. The server returns the existing canonical conversation
snapshot after re-adapting it through ROTE. This does not navigate History,
re-execute agents, advance content revision or admit stale transient frames.
Rapid viewport changes coalesce; active operations and editing defer refresh.
A refused or timed-out refresh retains the committed view and can be retried.
Older servers and clients retain ordinary capability-update behavior.

The native shells implement the drawer/sidebar, category catalog, agent
directory/introduction, conversation/result/full-screen view, selection,
composer and settings. Scenario Load fills a draft; Run follows normal chat
dispatch. The six composite types render natively with the shared data and
accessible labels; Open Sans is packaged from the licensed contract asset.
The passive web voice warning is excluded by the server-owned native
disposition. Actionable native voice status and recovery remain visible.

watchOS negotiates the same console with ROTE-selected navigation stacks,
compact controls and explicit phone/desktop handoffs for unavailable actions.
Opening an introduction or owner surface preserves the initiating screen on
Back. Result detail retains the current conversation. Device login and voice
continue through the existing authenticated paths.

Windows implementation belongs to the separate Windows workstream. This
change leaves its source untouched and preserves legacy non-negotiating
behavior. Consult [`ui_protocol.json`](../contracts/ui_protocol.json),
[`capabilities.py`](../backend/rote/capabilities.py) and the client READMEs for
supported contracts and native build requirements.

## Native local qualification

The September 25 source checks passed Android core161/app392 unit tests,
all116 instrumented fixtures, ktlint, Android lint, Kover and debug assembly.
Apple checks passed Core283, Mac294, iOS277 and31 iOS UI tests. Watch navigation
passed10 tests; watch model/render checks passed104, with one protected-staging
evidence test skipped because its producer URL was unavailable. Current-source
changed-line diagnostics measured91.40% Swift and93.82% Kotlin.

The owner confirmed Mac voice returned speech, response text and the dice UI;
the corrected Mac composer was inspected at desktop width. Synthetic native
fixtures cover responsive layouts and denied/stale operations. The
[kos-wiki reference archive](https://github.com/Kentucky-Open-Science/kos-wiki/tree/main/assets/astral-native-ui-v2)
contains the54 web references captured before resumed native edits and
separately identified native captures. Complete backend CI, clean composed
candidate qualification and authenticated mobile/watch audio acceptance remain
open; these local checks do not establish release qualification.

## Test and CI maintenance

The 2026-09-21 audit updated existing tests instead of replacing them with a
second suite. It removed the obsolete expectation that Recent work appears in
the settings rail while retaining native/watch projection assertions. The
real-shell browser fixture now substitutes every boot placeholder, uses the
host path separator for Python imports, and fails on initialization errors.
Its existing responsive/keyboard checks now cover every composer menu entry;
one focused test covers menu dismissal and ordinary surface dispatch.
The existing selection suite now enters through More options and **Advanced
settings**, including the new focus-return target. Its owner isolation,
malformed selection, stale response and disconnected-write tests are retained.

The Git executable bit check now reads the committed/indexed mode rather than
Windows filesystem mode bits. Auth, sanitization, export integrity, continuity,
native contracts and release guards were retained. Their contracts still exist;
the new web appearance does not make them obsolete.

[`ci.yml`](../.github/workflows/ci.yml) already runs the real-shell
`first-task-088.spec.js` suite alongside continuity, voice, guidance, selection,
offline, chart and export checks. Its numeric filename is historical and does
not mean it exercises the old UI. No workflow gate was disabled. The separate
[`web_layout_parity`](../tests/web_layout_parity/README.md) harness remains a
local a8p-reference comparison; owner-directed differences are recorded in
AstralDeep's feature-089 layout contract, rather than rewriting reference images.

Historical September 21 web evidence, distinct from current native checks,
hosted CI and live authenticated verification:

| Command/check | Result |
| --- | --- |
| Python 3.11, `python -m pytest tests/chrome tests/webrender tests/rote -q --tb=short` (`PYTHONUTF8=1` on Windows) | **2,099 passed** |
| Linux existing AstralDeep image, current checkout mounted; `python -m pytest tests/ci/test_workflows.py -q --tb=short` | **64 passed** |
| Local Chromium, `node tooling/web-ci/node_modules/@playwright/test/cli.js test tooling/web-ci/tests/first-task-088.spec.js --browser=chromium --workers=1 --reporter=line` | **11 passed, 1 failed** |
| Local Chromium, same command targeting `tooling/web-ci/tests/selection-088.spec.js` | **16 passed, 1 failed** |
| Ruff for the two changed Python tests; ESLint for `client.js`, `first-task-088.spec.js` and `selection-088.spec.js` | **Passed** |
| Generated export document/manifest freshness within renderer suite | **Passed** after regeneration |

Both retained browser failures concern **320 px with 200% root text**: expanded
composer **Run in background** and **Advanced settings** entries extend about
100 px beyond the left viewport edge. The assertions remain active. Desktop,
tablet, 320 px ordinary-text reachability,
keyboard order, send behavior, menu dismissal, Work and notes interactions
passed. This audit deliberately did not change the new UI to fix the overflow.
The four Apple workflow-shell tests cannot execute using this Windows host's
unconfigured WSL Bash; the same tests pass in the Linux run above. Neither run
builds an Apple app or establishes native/live parity. Local browser testing
used Node 22; hosted CI retains its pinned Node 24 and Playwright image.

For a quick focused run, use the Python and browser commands above. Set
`ASTRAL_TEST_PYTHON` to a Python 3.11 interpreter with the local Primitives
package installed when the default `python3` is unsuitable. Full hosted gates,
native builds, desktop layout scoring and authenticated end-to-end dispatch
remain separate checks; this checkpoint does not claim all of them passed.

## Referencing the checkpoint

Use this document as the source-owned UI inventory and link it from kos-wiki's
web-client/UI pages. Pair those references with the exact Projection commit
SHA and AstralDeep composition pin. The intended annotated source-checkpoint
tag is `ui-v2-2026-09-21`, applied to the committed snapshot. The tag names
recoverable source; it is not a formal GitHub/native release while the
responsive failure remains.
Do not infer a package-version bump, store submission or qualified native
release from the UI name. Release publication workflows are disabled and
require their own activation; see the [repository README](../README.md).
