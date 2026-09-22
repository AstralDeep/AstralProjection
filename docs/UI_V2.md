# AstralDeep web UI v2

Verified against the local source tree on 2026-09-21. The design started in
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

Windows/PySide6, Android/Compose and Apple/SwiftUI have not adopted this web
layout. Feature 089 explicitly scoped the redesign to web; native menu/frame
contracts and their security/integrity checks remain meaningful. A refreshed
bundled Apple HTML export resource is shared export freshness, not an Apple
UI v2 redesign. Consult [`ui_protocol.json`](../contracts/ui_protocol.json),
[`capabilities.py`](../backend/rote/capabilities.py) and the client READMEs for
the actual supported contracts.

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

Local evidence, distinct from hosted CI and live authenticated verification:

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
