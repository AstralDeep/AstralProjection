# Feature 088 — the per-client disposition matrix

`contracts/ui_protocol.json` → `presentation_contracts.disposition_matrix_088` (version 1)
is the one server-owned table that says, for **every feature-088 destination** and
**every client**, what the host actually delivers. It answers FR-023 ("no incomplete
review execution") and FR-024 ("explicit server-declared dispositions") in one place
instead of leaving the answer implicit in eleven contract blocks.

It adds no vocabulary: no push type, component type, `accept_action` or
`client_local_action`. Every capability, action, operation and fixture it names already
exists, and every older presentation contract is retained unchanged.

## Dispositions (closed set)

| value | meaning |
| --- | --- |
| `supported` | the client receives the complete server-built view with every declared control; adaptation drops nothing |
| `read_only_handoff` | the client receives the readable content without its controls, plus a server-declared `handoff` sentence; it never renders a partial command form |
| `omitted_by_server` | the host never delivers this destination to this client — no control, URL, token or snapshot is created, and the omission is declared here rather than inferred |
| `version_required` | the destination exists but the host withholds it until the client advertises the row contract's `client_capability` in `register_ui.capabilities` |

A row marked `effect_review` (the Save review, note Forget, skill Delete, and the agent
Activate/Archive/Delete reviews) may **never** be `read_only_handoff`: an authorization
step is delivered complete or not at all.

## Clients

`web`, `windows`, `android`, `ios`, `macos`, `watch`, `voice`. Each has a
`client_profiles` entry naming its ROTE `device_type`, its registration source file and
the 088 capabilities that source really advertises today:

| client | advertises today |
| --- | --- |
| web | `guidance_notes_v1`, `guidance_selection_v1` — and it is the authoritative `chrome_render` channel, so every row is `supported` |
| windows | `work_read_v1` |
| android / ios / macos / watch | `work_read_v1`, `guidance_notes_v1` |
| voice | none — it is a ROTE rendering profile of an already registered client, not a registration |

`work_save_v1`, `guidance_skills_v1`, `guidance_agents_v1`,
`recurring_work_v1`, `saved_results_v1` and `connections_v1` are advertised by **no**
client yet, and `guidance_selection_v1` only by web, which is why those rows read
`version_required` on the native clients
(`connections_088` reaches the wrist as `omitted_by_server`: its own `watch.surface`
clause says the surface is not delivered there).

`capability_family` is exactly the set of `client_capability` values declared by the
manifest's presentation contracts, and every capability-gated contract must own at least
one row — a new 088 destination therefore cannot ship without a declared disposition.

## How a cell is justified

Every cell carries a `basis` from a closed set, and `contract_declared` cells carry a
`contract_path` that must resolve to a non-empty value inside this same manifest:

- `web_render_channel`, `advertised_capability`, `missing_capability`
- `contract_declared` (+ `contract_path`), `shared_chrome_menu`
- `watch_menu_projection` — `project_watch_menu_model` does not project the control
- `owner_exclusion_T059` — the Windows redesign exclusion
- `rote_voice_profile` — the voice profile has `supports_interactivity = False`

## Windows

Per the owner's 2026-09-11 decision (T059) Windows is excluded from the 088 redesign, so
a Windows cell may only be `read_only_handoff` or `omitted_by_server`. The three Work
read rows are `read_only_handoff`: the existing "Recent work" dialog renders the same
complete read (the adapter demonstrably returns the components untouched for the
`windows` profile) — the handoff is an owner exclusion, not a rendering limit.

## What the test proves

`tests/test_disposition_matrix_088.py` (75 cases) refuses drift instead of describing it:

- the table is closed and resolvable — unknown surface, action, command, operation,
  contract, contract path, fixture state, client or disposition is rejected;
- `advertised_088_capabilities` is compared against the literal capability strings in
  `client.js`, `protocol.py`, `Wire.kt` and `Frames.swift`;
- Work rows are adapted through `ComponentAdapter.adapt_work_surface` for each client's
  `DeviceProfile` and must match the row (`supported` ⇒ byte-identical; the voice
  `read_only_handoff` ⇒ every action gone, every text preserved);
- private-notes rows are adapted through `ComponentAdapter.adapt_guidance_surface` from
  the committed `guidance_088/notes_surface.json` states and must equal the fixture's
  own native frames, while the voice profile must raise `guidance_surface_unavailable`;
- `project_watch_menu_model` must project exactly the Work and Private-notes controls
  and never canvas Export/Share, pinning every `watch` cell;
- no Windows cell is `supported`, and no `effect_review` row (Save review, note Forget,
  skill Delete, agent Activate/Archive/Delete, connection Issue/Revoke) is a handoff
  anywhere;
- every capability-gated presentation contract is covered by a row, and
  `capability_family` equals the manifest's own set of `client_capability` values.

Run it with:

```bash
cd components/AstralProjection
PYTHONUTF8=1 ../../.venv/Scripts/python.exe -m pytest -q -p no:cacheprovider \
  tests/test_disposition_matrix_088.py tests/test_protocol.py tests/rote
```

## Changing the matrix

Editing `contracts/ui_protocol.json` changes its bytes, so
`provenance/transformations.json` must carry the new `resultSha256` for that path in the
same change or `tests/test_protocol.py::test_transformation_record_binds_imported_sources_to_current_bytes`
fails. The ledger entry's `task` field already lists `T054`.
