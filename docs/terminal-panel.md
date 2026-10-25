# Terminal panel

The shared terminal panel renders owner-authorized terminal sessions through the
server-owned UI contract. `contracts/ui_protocol.json` declares the
`terminal_panel` presentation contract (`surface_key: "terminal"`, contract
`terminal_panel/v1`), its closed action vocabulary, and every client disposition;
`contracts/fixtures/terminal/panel_surface.json` is the shared fixture that native
drift guards and web checks consume.

## Ownership

- `src/astralprojection/chrome/terminal.py` builds the list and panel views from
  host-authorized session and output snapshots. Clients never supply a target,
  path, credential or session identity; session metadata is host-owned literal
  display data with declared not-reported placeholders.
- `backend/webrender/terminal.py` sanitizes streamed output before any renderer
  sees it: ANSI CSI, OSC (including clipboard and hyperlink controls),
  DCS/SOS/PM/APC, C0/C1 controls, and bidi/format characters are removed, invalid
  UTF-8 becomes U+FFFD, and output is bounded to the newest 2000 lines /
  32768 bytes with a visible truncation warning.
- `backend/rote/terminal.py` validates the closed component tree per device and
  `backend/rote/adapter.py` adapts it (`ComponentAdapter.adapt_terminal_surface`),
  including the declared code-to-text fallback for profiles without code support.
- The web renderer emits the panel through the shared escaped chrome renderer
  (`render_html`); output is literal selectable text and never becomes a link.

## Actions

Navigation uses the existing `chrome_open` (`params.mode` of `list` or `panel`,
opaque `session_id`, optional `offset`) and `chrome_close`. The interactive
operations submitted to the governed terminal contract are:

| Action | Payload fields |
| --- | --- |
| `chrome_terminal_input` | `surface`, `session_id`, `fields.data` (≤ 512 characters, no control characters) |
| `chrome_terminal_resize` | `surface`, `session_id`, `fields.cols` (2–1000), `fields.rows` (2–300) |
| `chrome_terminal_interrupt` | `surface`, `session_id` |
| `chrome_terminal_close` | `surface`, `session_id` |

The host rechecks owner, connection, session and delivery authority for every
read and submitted operation; requests are never queued or replayed across
connections, accounts, sessions or revoked authority. Copy uses the platform
selection or clipboard UI only; OSC 52 and hidden clipboard writes are ignored.

## Dispositions

| Client / ROTE device | Disposition |
| --- | --- |
| browser, windows | `interactive_panel` (complete panel with the governed operations) |
| android, ios, macos, tablet, mobile, tv | `read_only_monitor` (complete list and output reads, platform-selection copy, never a partial command form) |
| watch / watchos | `phone_desktop_handoff` (content-free state metadata only) |
| voice | `omitted_by_server` |

TV additionally degrades buttons through its declared ROTE profile and renders
the read-only session summary. When the host reports the terminal capability
unavailable or refused, every client renders the declared unavailable or denied
state with recovery guidance; the omission is server-declared and never hidden
independently in a client.

## Verification

- `tests/test_terminal_protocol.py` binds the contract, fixture, sanitizer and
  dispositions, including the deterministic malicious-sequence vector.
- `tests/rote/test_terminal_panel.py` covers adaptation, refusals and bounds.
- `tests/chrome/test_terminal_views.py` covers builder golden paths, failure
  statuses, the watch handoff and accessible escaped web rendering.
- `windows-client/tests/test_terminal_panel.py` covers the Windows surface
  correlation, literal output rendering and retirement fences.
- Android `TerminalPanelTest`, Apple `TerminalPanelTests` and
  `TerminalPanelAppTests`, and the web `work-reads-088.spec.js` terminal loop
  verify their clients against the shared fixture.
