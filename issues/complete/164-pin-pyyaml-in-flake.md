# Issue #164: Pin `pyyaml` in `flake.nix` dev shell

## Summary
The bash test suites (`test/platform/*_test.sh`) parse YAML via Python
+ PyYAML. PyYAML isn't currently in the Nix dev shell, so the tests
fall back to a `.venv-tools/bin/python3` (provisioned by `setup.sh`).
On a fresh clone, before `setup.sh` runs, the platform tests fail
with `ModuleNotFoundError: No module named 'yaml'`. Pinning
`python312Packages.pyyaml` in `flake.nix` would remove this implicit
ordering dependency.

## User Stories
N/A (developer experience / onboarding).

## Goal
Fresh clones can run platform tests via `nix develop` (or `flox
activate` if applicable) without first running `setup.sh`. The
`.venv-tools` fallback continues to exist as defence-in-depth, but the
happy path no longer requires it.

## Scope Check
- One Nix file change.
- One-line addition to `buildInputs`. Well under 300 LOC.
- Single concern: Python YAML availability in the dev shell. No
  bundled scope.

## Wiring
- [x] Implementation only. Wired by this issue (Nix shell rebuild
      picks it up automatically).

## Technical Requirements

### Edit `flake.nix`

Add `python312Packages.pyyaml` to the same `buildInputs` block that
currently lists `python312Packages.pip` and `python312Packages.mypy`
(around line 44–46).

Resulting block (illustrative):

```nix
python312
python312Packages.pip
python312Packages.mypy
python312Packages.pyyaml  # <- new
```

### Verify all four bash test suites still pass

The probe order in the test suites already prefers system `python3`;
adding `pyyaml` to the system Python should make the `.venv-tools`
fallback unnecessary on systems entering the shell via Nix.

Run the existing suites end-to-end:

```bash
nix develop --command bash test/platform/run_all.sh
```

Expected: all suites pass without `setup.sh` having been run first
(specifically the suites that parse YAML —
`deploy_production_workflow_test.sh` and
`rollback_action_composite_test.sh`).

### `actionlint` should still pass

No workflow changes — `actionlint` should be unaffected. Run as a
sanity check.

## Reviewer Context

- The `python312` / `python312Packages.*` namespace must match the
  Python version pinned at line 44 of `flake.nix`. If that line is
  ever bumped (e.g. `python313`), this addition must move with it.
- `pyyaml` is a small, pure-Python package; pinning it does not
  noticeably grow the Nix shell closure.
- The `.venv-tools` provisioning in `setup.sh` is left in place as a
  fallback — useful for contributors who don't use Nix (e.g. running
  the tests under a system Python directly). Removing it is out of
  scope for this issue.

## Definition of Done
- [ ] `flake.nix`'s `buildInputs` includes `python312Packages.pyyaml`.
- [ ] `nix develop --command bash test/platform/run_all.sh` passes
      from a fresh clone (no `.venv-tools` directory present).
- [ ] `actionlint` still passes.
- [ ] `just verify` passes.

## Dependencies
None.

## Agent Assignment
platform-agent.

## Progress Notes
2026-04-29: Filed as a follow-up to Phase 6 of #137. The platform
tests added in #137 (specifically `deploy_production_workflow_test.sh`
and `rollback_action_composite_test.sh`) parse YAML via Python and
expose the existing `pyyaml`-not-in-shell gap. The fix is small enough
to ship as its own micro-PR rather than be folded into a larger
refactor.
