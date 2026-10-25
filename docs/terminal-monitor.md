# Read-only terminal monitor

The terminal monitor is a server-owned chrome surface for observing an existing,
owner-authorized terminal session without leaving the shared Astral UI. AstralDeep
still owns session discovery, authorization, read dispatch and audit; Projection
supplies the contract, sanitizer, view builder and client dispositions.

The public `build_terminal_monitor_view` API selects this read-only contract for
both list and monitor states. The shared `build_terminal_view` API defaults to
the panel contract; `mode: "monitor"` or the explicit state marker
`contract: "terminal_monitor/v1"` selects the read-only contract. ROTE applies
the same marker before deciding whether desktop controls are permitted.

## Contract

`contracts/ui_protocol.json` → `presentation_contracts.terminal_monitor` owns
`surface: "terminal"` with two read modes:

- `mode: "list"` lists the current owner's open sessions and offers an explicit
  **Open monitor** action for each bounded opaque session id.
- `mode: "monitor"` shows the target, directory, state, dimensions, retained
  output byte range and a sanitized output window.

Requests use the existing `chrome_open` action and carry a fresh canonical UUID4
`request_generation`. Responses use the existing correlated `chrome_surface` and
`chrome_render` replacement envelopes. No terminal push type, component type,
client-local action or interactive terminal action is added.

The only controls are list/refresh reads and monitor closure through
`chrome_open` and `chrome_close`. There is no create, input, resize, interrupt,
session close, link, clipboard or other effect action. Closing the monitor does
not close the terminal session. Copying uses the platform's text selection or
clipboard UI over literal output; the server never honors OSC 52 or issues a
clipboard command.

## Output safety

`backend/webrender/terminal.py` removes ANSI CSI, OSC (including clipboard and
hyperlink controls), DCS/SOS/PM/APC, C0/C1 controls, bidi controls and other
format characters before the view builder receives text. Invalid UTF-8 is
replaced with U+FFFD. The remaining text is literal, escaped by the renderer and
never converted into a link.

Output is bounded to 32 KiB and 2,000 lines by retaining the newest complete
Unicode scalars. Host-reported truncation and end-of-output remain visible as
alerts. `src/astralprojection/chrome/terminal.py` shows list, monitor, closed,
truncated, loading, unavailable, stale, wrong-owner, disconnected and
account-change states. Failure states never echo private snapshot data.

## Client dispositions

| client | disposition |
| --- | --- |
| web | read-only monitor |
| Windows | read-only monitor |
| Android | read-only monitor |
| iOS | read-only monitor |
| macOS | read-only monitor |
| watchOS | content-free state metadata plus phone/desktop handoff |
| voice | omitted by the server |

Web and native clients use the same generic chrome surface and existing
request/connection/owner correlation. The Android code primitive uses a
selection container; the Windows read-only text editor, Apple selectable code
view and web `<pre><code>` output provide native copy selection. ROTE validates
the complete read-only tree before dispatch and removes code formatting only for
a profile that cannot render code, retaining the literal text.

## Fixture and tests

`contracts/fixtures/terminal/monitor_surface.json` contains the request,
successful list and monitor frames, web render, watch handoff, malicious escape
sample, truncation and every denial/recovery state. These checks exercise it:

```bash
python -m pytest -q -p no:cacheprovider tests/test_terminal_protocol.py tests/rote/test_terminal_monitor.py
```

Client drift guards live in `windows-client/tests/test_terminal_monitor.py`,
`android-client/core/src/test/kotlin/com/personalailabs/astraldeep/core/protocol/TerminalMonitorTest.kt`
and `apple-clients/AstralCore/Tests/AstralCoreTests/TerminalMonitorTests.swift`.
The web correlation loop is part of
`tooling/web-ci/tests/work-reads-088.spec.js`.

Deterministic local tests qualify the contract and sanitizer. The real-dispatch,
staging backend and device/emulator acceptance remains in the required PR CI
lanes; a local unit check does not substitute for that live verification.
