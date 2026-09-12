# Ephemeral visual export representation v1

The adjacent JSON file defines the closed display-only shape and limits. This
contract is an implementation slice; no HTTP route or native consumer is implied.

`render_presentation(bytes)` accepts UTF-8 JSON with exactly the request fields.
It returns a dictionary with exactly the response fields. Inputs have no owner,
token, chat, revision, arbitrary HTML, CSS, script, action or storage authority.
A future authenticated HTTP adapter supplies those authorization fences outside
this pure function. The submitted tree must not be logged, stored or hashed.

Freeze the current visible canvas after the existing authorization GET, including
visible uncommitted components, at the same capture stage as web. Strip transcript,
welcome, skeleton and overlay content at the source. Do not substitute stored
committed components or re-run device adaptation. Capture local disclosure/tab
state and loaded image pixels at that same instant. Viewport dimensions are
finite numeric logical pixels (fractional values are accepted within the bounds);
theme is the captured thirteen-role palette, each value `#RRGGBB` (border also
accepts `#RRGGBBAA`). The host does not round input geometry; the shared finalizer
retains the web's existing output-width rounding.

For each collapsible include `{path, component_id, kind:"collapsible_open",
value:true|false}`; for each tabs node use `kind:"tabs_open"` and the distinct
zero-based indices of open panes (native selected tab is a one-element array).
Every image and chart requires `{path, component_id, data_url}` with already loaded PNG
pixels, even if its original source is a data URL. No URL is fetched. PNG is the
initial explicit supported pixel format; other formats must be converted from
loaded pixels by the host or fail visibly. Original image URLs never enter the
response. Paths are exact structural paths and identity must also match; stale,
duplicate and unused records fail instead of applying to a different component.
Content/children aliases retain their exact path, including inside tabs; two
competing child arrays or non-array wrappers are refused. Capture only the visible
subtree when a native pane has not mounted its hidden children.

Control-only components listed in `omitted_components` are omitted just as the
web finalizer excludes controls. Other unsupported types fail visibly. Client
provenance metadata is not attested or rendered as a server provenance claim.
The representation deliberately contains no executable source or action payload.
Chart pixels must come from the current ready chart through its existing isolated
Plotly.toImage path, preserving zoom, pan and legend selection. Raw chart specs
are never replayed in the export document. A missing or
failed chart/image cannot silently become a successful blank export.
Nonempty authored `css` or `style` is explicitly unsupported: the existing
canonical primitive renderer does not consume those fields. Its own validated
layout/style output remains intact; the export never silently drops an authored
appearance override or invents a new CSS interpreter.

The bundled private document uses the authoritative renderer markup, CSS,
Tailwind palette mapping and fonts. Its fixed bootstrap applies
the presentation as inert data and runs the same `canvas-export.js` finalizer as
web. Both rebuild output nodes/attributes and embed fonts and current chart/image PNG, and
return a self-contained document with script-none/network-none CSP. Native
WebView/WKWebView must additionally deny network/navigation and persistence and
must not expose identity or an action bridge. Cancel/stale completion destroys
the document and private temporary files. The saved output has no executable
code, dispatch metadata, credentials, URLs or claim of server-side attestation.

Existing `/api/share` snapshots, PHI checks, approval/owner boundaries and legacy
static HTML exports are unchanged. Merely rendering this representation never
mints, publishes, shares, dispatches, saves, or authorizes an effect.

The actual canvas width may be narrower than the window: width accepts 64–4096
logical pixels. Keep original component/tab indices when omitting unmounted
content; leave hidden child arrays empty rather than reindexing selected panes.

`viewport` has exactly `width`, `height`, `window_width`, `window_height`. The
first pair is the mounted canvas box, the second pair is the source window used
by CSS media queries. Window width is 64–16384; both heights are 32–16384. Canvas
width cannot exceed window width. Size the isolated browser to window dimensions;
set only the inner canvas width. Full canvas content must grow naturally with no
viewport-height clipping. A mismatched host window fails visibly.

Captured grids carry the measured effective column count as an integer from 1
to 64. The strict renderer preserves that count at every window breakpoint; it
never adapts a native layout again. Canonical SVG icon subtrees are omitted as
in the shared web finalizer, while their adjacent alert/rating text remains.

An image component may include paired finite numeric `width`/`height`, each
strictly positive and no larger than 16384 logical pixels, measured from its
loaded native image box. Native capture must remove authored size fields.
Omitting both keeps the existing intrinsic image behavior. A `caption` is
rendered only when it is actual visible native text; `alt` is accessibility text
and does not imply a visible caption. These are component presentation fields;
the exact three-field `images` pixel record remains unchanged.
