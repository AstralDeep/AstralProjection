# web_layout_parity — a8p desktop parity and the responsive checklist

Feature 089 (T046/T047). Local-only test tooling: nothing here is referenced
by a CI workflow, and nothing ships in a product image.

## What it measures

- **Desktop parity (SC-010).** The 27 weighted items of
  `AstralDeep:specs/089-typesafe-a8p-integration/contracts/web-layout-parity.md`,
  scored at 1920×1080, 1440×900 and 1280×800 against captures of the a8p
  console. Target ≥ 90% at each viewport.
- **Responsive checklist (SC-012).** R1–R13 at 1024×768, 768×1024, 390×844,
  320×640 and 1280×800 at 200% text. Pass/fail, 100% required.
- **CSP.** Every violation raised while scoring is recorded; a non-zero count
  fails the run.

`probe.mjs` holds the in-page measurement and runs unchanged against both
sides, so a reported difference is a difference in the pages.

## Prerequisites

Playwright comes from the repository's existing lock-pinned CI tooling:

```bash
cd tooling/web-ci && corepack npm ci --ignore-scripts && npx playwright install chromium
```

## Capturing the reference (T046)

Run a8p on a free port (the Astral stack usually holds 8001):

```bash
cd /path/to/a8p && .venv/Scripts/python -m uvicorn astral.app:app --port 8010
```

Regenerate the multi-component response fixture with a8p's own renderer, then
capture:

```bash
node tests/web_layout_parity/capture-reference.mjs \
  --url http://127.0.0.1:8010 \
  --out ../AstralDeep/specs/089-typesafe-a8p-integration/reference
```

This writes, per viewport and per state, a PNG and the region bounding-box
JSON, plus one `a8p-context-*.json` of the behavioural facts and
`a8p-reduced-motion.json`.

The response state never issues a chat turn. A real a8p turn needs the
owner's TypeSafe key against the *reference* app, which the 089 credential
rule does not allow, so the response HTML is produced by a8p's own
server-side renderer from a fixed component list
(`a8p-response-fixture.json`).

## Scoring the Astral web client (T047, T055)

```bash
node tests/web_layout_parity/score-parity.mjs \
  --url http://127.0.0.1:8001 \
  --reference ../AstralDeep/specs/089-typesafe-a8p-integration/reference \
  --out build/089/parity

node tests/web_layout_parity/responsive.mjs \
  --url http://127.0.0.1:8001 \
  --reference ../AstralDeep/specs/089-typesafe-a8p-integration/reference \
  --out build/089/parity
```

Both write a `.json` and a readable `.txt` into the output directory and exit
non-zero when the target is missed.

## What the client must expose

The drivers reach the five states through `window.__ASTRAL_PARITY__`, a
test-only hook `client.js` installs. It carries `reset()`,
`seedConversation(fixture, opts)`, `openSettings()` and
`onViewportRegister(cb)`. Seeding renders a response through the ordinary
component path — it does not hand-write DOM — so what is scored is what a
real turn produces.

## Scoring rules

Straight from the contract: Pass is full weight, Partial (position and
structure right, a dimension outside tolerance) is half, Fail is zero.
Tolerance is ±8% or ±8px, whichever is larger. Colors are excluded, because
they come from `ThemeView`. Content differences are excluded — real agents
instead of a8p's 11 demo agents, real welcome examples instead of a8p's 12
hard-coded scenarios.

Items marked `[review]` in the contract (A3, D5) are automated here as far as
they can be and still recorded separately, so a person scoring them against
the captures can see what the machine saw.

`B5` (the 088 recent-work section) has no a8p counterpart and is scored on
the contract's structural description alone.
