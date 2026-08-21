# Release workflow activation gate

All copied workflows are intentionally inactive. There is no
`.github/workflows/` directory in this repository; every copied job is under
`workflows-disabled/` and has an unconditional `${{ false }}` job gate. This
document records the preconditions for a later, separately reviewed activation
commit. It does not authorize that commit or any publication.

## Current status

| Gate | Status | Evidence or closure |
|---|---|---|
| Workflow location and job fences | Satisfied for inactivity | Nine YAML files under `workflows-disabled/`; all 19 jobs carry `if: ${{ false }}` |
| Feature-074 final local qualification | Pending | AstralDeep tasks T221-T237, including platform-specific unavailable checks, must be recorded honestly |
| Exact Projection revision/composition | Pending | Pin the qualified Projection commit in the Deep composition manifest and verify a clean recursive checkout |
| Release environments and reviewers | Pending | Create and re-query the exact environments in `release-environment-inventory.md` |
| Secret/variable names and protected values | Pending | Configure the inventory without logging values; re-query names and environment placement |
| Windows bridge decision | Pending | Select a strictly newer bridge at an authorized release-planning event; populate and verify `contracts/windows-release-trust.json` |
| Windows import-only bridge job | Pending | Review a job that imports the exact legacy artifact, verifies it, forbids rebuild/repackage, signs identical bytes, and runs `scripts/verify_windows_bridge.py` |
| Android store continuity | Pending | Confirm Play maximum and upload certificate; choose a greater version code; verify a signed local bundle |
| Apple store continuity | Pending | Confirm App Store maximum; reserve a greater Projection base; verify certificates, profiles, identifiers, archives, and unsigned platform tests |
| Private component/runner boundary | Pending | Keep runner, cache, artifact, and publication paths private; never expose private component bytes to forks or public caches |
| Branch/tag/environment protection | Pending | Verify protected default branch, exact tag namespaces, required reviewers, prevent-self-review, and no bypass |
| Rollback rehearsal | Pending | Rehearse normal-commit workflow deactivation and client trust rollback without deleting published refs or downgrading store identities |

## Required activation sequence

1. Finish narrow implementation checks, then the feature's late local
   qualification matrix. Record exact commands, platforms, revisions, and
   unavailable gates; do not translate an unavailable macOS/store check into a
   pass.
2. Update the release-environment inventory from read-only provider queries.
   Configure external state through an approved operator session and re-query
   names, approval rules, branch/tag restrictions, and store counters without
   logging values.
3. Select the Windows bridge only after live legacy release state is refreshed.
   The selected version must be strictly newer than the installed legacy line.
   Set both channel bounds to that version and bind the executable and both
   bundle digests in `contracts/windows-release-trust.json`.
4. Add a dedicated import-only bridge workflow. It must download one exact
   legacy release ID/tag/asset ID set, verify the legacy Sigstore identity and
   expected digest, refuse redirects/name ambiguity/rebuild/repackage, sign the
   same executable under the exact Projection tag identity, and prove both
   downloaded channel assets are byte-identical with the offline harness.
5. Review every copied workflow against its new repository identity. Replace
   blank credential placeholders only with explicit `${{ secrets.NAME }}` or
   `${{ vars.NAME }}` references from the inventory. Keep candidate jobs
   read-only and signing/publication authority confined to approved
   environments with the built-in short-lived token.
6. In one dedicated activation commit, move only reviewed files into
   `.github/workflows/` and remove their unconditional false gates. Before
   pushing, re-run workflow-policy checks and re-query provider state. Keep any
   workflow whose prerequisites remain incomplete disabled.
7. Open a draft/non-mergeable checkpoint and run read-only/rehearsal paths
   first. Publication, tag creation, GitHub Releases, Play upload, App Store
   upload, and submission require separate explicit release authorization.

## Invariants after activation

- Windows trusts only the exact legacy and Projection repository/workflow/tag
  identities permitted by the bounded source policy; redirects and
  organization membership do not count.
- The bridge executable is built once. Its two Sigstore bundles may differ;
  its executable bytes and SHA-256 may not.
- Legacy Windows authority cannot sign a version above the bridge maximum, and
  Projection cannot sign below the bridge. Update selection remains strictly
  newer than the installed client.
- Android application ID, upload certificate, OIDC redirect, and monotonic Play
  version code stay continuous.
- Apple bundle IDs, Universal Purchase record, profiles, certificates, and
  monotonic build number stay continuous.
- Candidate and normalization jobs remain secret-free/read-only. Release
  publication keeps least-privilege job permissions and environment approval.
- No workflow uses `pull_request_target` to expose credentials or private
  component bytes, and no shared public cache contains private source.

To deactivate, use an ordinary reviewed commit that restores unconditional
false job gates or moves the affected files back to `workflows-disabled/`.
Never delete or rewrite release tags as a rollback mechanism.
