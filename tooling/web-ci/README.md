# web-ci — CI-only web lint and browser checks

This directory is **test tooling only**. Nothing here ships in a product image
or wheel (`npm run check:product-isolation` enforces that), and its
dependencies are lock-pinned dev dependencies.

## The hosted `web` job

`.github/workflows/ci.yml` (`jobs.web`) runs, in order:

1. `python tooling/web-ci/fixtures/persistent-agents-079.py <mode>` for
   `create revise detail expired error`, into `build/079/browser-fixtures/`.
2. `corepack npm ci --ignore-scripts` (npm 11.16.0 via Corepack, Node 24).
3. `corepack npm run check:package-manager check:product-isolation lint
   test:coverage-conversion test:coverage-conversion:node test:coverage-union`
   (run as separate scripts).
4. The public offline-worker Node lane under `NODE_V8_COVERAGE`, converted by
   `coverage-conversion-cli.mjs` and gated at ≥90% executable lines for
   `service-worker.js` and `offline-registration.js`.
5. The **browser step**, inside the image pinned by `playwright-image.txt`.
6. The portable-export gate at ≥90% executable lines for `canvas-export.js`
   and `canvas-export-host.js`, from `build/088/export-javascript.json`.

Every tracked `*-088.spec.js` runs in step 5; `tests/ci/test_workflows.py`
pins the spec list against the files on disk, so a new 088 spec that is not
added to the workflow fails that test.

## Running the 088 browser specs locally

### Pinned image (what CI runs)

From the repository root, with Docker available:

```bash
image="$(tr -d '\r\n' < tooling/web-ci/playwright-image.txt)"
mkdir -p build/079/browser-fixtures
for mode in create revise detail expired error; do
  python tooling/web-ci/fixtures/persistent-agents-079.py "$mode" \
    > "build/079/browser-fixtures/$mode.json"
done
docker run --rm --init --env HOME=/tmp \
  --env ASTRAL_ASSIGNMENT_FIXTURE_DIR=/workspace/build/079/browser-fixtures \
  --env ASTRAL_EXPORT_COVERAGE_OUTPUT=/workspace/build/088/export-javascript.json \
  --volume "$PWD:/workspace" --workdir /workspace/tooling/web-ci "$image" \
  /bin/bash -lc 'corepack npm exec -- playwright test \
    tests/first-task-088.spec.js tests/work-reads-088.spec.js \
    tests/guidance-notes-088.spec.js tests/workspace-topbar-088.spec.js \
    tests/native-chart-088.spec.js tests/offline-worker-088.spec.js \
    tests/canvas-review-088.spec.js tests/native-export-088.spec.js \
    --browser=chromium --workers=1'
```

On Git Bash for Windows prefix the command with `MSYS_NO_PATHCONV=1` so the
container paths are not rewritten.

### Without Docker (installed browser channel)

```bash
cd tooling/web-ci
corepack npm ci --ignore-scripts
corepack npm exec -- playwright test tests/first-task-088.spec.js --channel=msedge
```

A locally installed Edge/Chrome channel is a convenience only — the pinned
image is the authority, and coverage gates are only meaningful there.

### Environment the specs read

| Variable | Used by | Purpose |
| --- | --- | --- |
| `ASTRAL_ASSIGNMENT_FIXTURE_DIR` | `persistent-agents-079.spec.js` | Rendered assignment fixtures |
| `ASTRAL_ALL_CLIENT_COVERAGE_DIR` | Seven complete-source client suites | Optional directory containing one exact-source raw array per suite; use instead of the individual client coverage sinks |
| `ASTRAL_EXPORT_COVERAGE_OUTPUT` | `native-export-088.spec.js` | Portable-export V8 coverage sink |
| `ASTRAL_WORK_COVERAGE_OUTPUT` | `work-reads-088.spec.js` | Optional `client.js` coverage sink |
| `ASTRAL_GUIDANCE_COVERAGE_OUTPUT` | `guidance-notes-088.spec.js` | Optional `client.js` coverage sink |
| `ASTRAL_FIRST_TASK_COVERAGE_OUTPUT` | `first-task-088.spec.js` | Optional `client.js` coverage sink (Chromium only) |
| `ASTRAL_SELECTION_RAW_COVERAGE_OUTPUT` | `selection-088.spec.js` | Optional raw `client.js` coverage sink for the canonical converter (Chromium only) |
| `ASTRAL_TEST_PYTHON` | `workspace-topbar-088.spec.js`, `first-task-088.spec.js` | Interpreter that renders the real top bar / modal chrome (defaults to `python3`; needs no third-party packages) |

`first-task-088.spec.js` serves the real `backend/webrender/templates/shell.html`
and `backend/webrender/static/**` over a routed `http://` origin, so the page is
not a secure context and no service worker registers during that spec.

### Canonical browser coverage for the backend/web gate

For the complete Chromium contract run, set `ASTRAL_ALL_CLIENT_COVERAGE_DIR` and
`ASTRAL_EXPORT_COVERAGE_OUTPUT`, leaving individual client sinks unset. Run one
worker so each suite owns its output. Convert the seven complete-source arrays
against the exact checked-out source before the four-lane union:

```bash
node tooling/web-ci/browser-v8-cli.mjs --repo-root . \
  --input build/client-raw/continuity-contract-060.json \
  --input build/client-raw/voice-conversation-065.json \
  --input build/client-raw/persistent-agents-079.json \
  --input build/client-raw/work-reads-088.json \
  --input build/client-raw/guidance-notes-088.json \
  --input build/client-raw/first-task-088.json \
  --input build/client-raw/selection-088.json \
  --output build/browser-javascript.json
```

Canvas and workspace-topbar tests inject partial source fragments, so their tests
remain required but do not contribute canonical `client.js` coverage. The four
individual raw sinks remain available for focused diagnostics.

The converter rejects empty or duplicate inputs, stale source, non-browser
observations, and other assets. It converts each observation separately and
unions observed hits only; an unobserved line stays uncovered. The output retains
the canonical browser producer identity. It is fixture execution evidence and
does not replace authenticated staging acceptance. Run its tests with
`npm run test:coverage-conversion:browser-cli` under `NODE_V8_COVERAGE`; the exact
Node lane now includes this CLI alongside the seven existing tooling sources.
