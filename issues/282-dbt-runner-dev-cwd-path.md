# Issue #282: DbtRunner's default dbt_dir breaks when Phoenix runs from the repo root

## Summary
`Stacks.Workers.DbtRunner` resolves the dbt project directory as
`Application.get_env(:core, :dbt_dir, Path.join(File.cwd!(), "../../dbt"))`
(`apps/core/lib/stacks/workers/dbt_runner.ex:15`), which assumes the BEAM's cwd is `apps/core`.
Running `mix phx.server`/`just dev` from the **repo root** (the normal dev flow) yields
`<repo>/../../dbt` — a nonexistent path — so every event-triggered `DbtRefreshJob` in dev fails with
`spawn: Could not cd to /Users/…/../../dbt` and
`[error] DbtRefreshJob: selective refresh failed for [...]`. Observed repeatedly during the #116
live drives (any placement event triggers it); it pollutes dev logs (Completion Bar §4 "logs clean
under the live drive") and means dev never exercises the real event→dbt refresh path. Releases are
unaffected (prod sets `:dbt_dir` / different layout — verify at pickup).

## User Stories
None — dev-environment defect (same class as #278).

## Goal
`DbtRefreshJob` resolves the dbt directory correctly regardless of the cwd Phoenix was started
from; dev logs stay clean under live drives; a guard prevents regression.

## Scope Check
One path expression + a guard/test. <50 LOC. ✅

## Feature-Completeness Pre-Check
n/a — dev tooling defect.

## Technical Requirements
- Anchor the default to the application/umbrella root rather than `File.cwd!()` — e.g.
  `Application.app_dir(:core)`-relative resolution, or a config default computed like #278's
  watcher fix (`Path.expand` against `__DIR__` in config). Confirm the release path stays correct.
- Guard: a `just doctor` check or test asserting the resolved `dbt_dir` exists in dev (mirror
  `Core.DevWatcherConfigTest`, #278).
- Evidence: a placement event in a repo-root `just dev` session runs the refresh without
  `Could not cd` (or cleanly no-ops if dbt is deliberately absent).

## Reviewer Context
- Discovered pre-#116 (2026-07-22 live drives); the `dbt_runner.ex` default dates to the original
  DbtRefreshJob commit (716827b0). #116's Phase 6 wired MORE events to dbt refresh
  (`placement.removed`), so the dev noise is now more frequent — another reason to fix.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Config/path correctness | yes | ❌ → ✅ — guard test asserting the resolved dir exists (dev) |
| Background jobs (L5) | yes | ❌ → ✅ — a dev-env refresh run without the cd failure (live-drive evidence) |
| others | no | n/a |

## Definition of Done
- [ ] dbt_dir resolves correctly from any cwd — evidence: live-drive log without `Could not cd`
- [ ] Regression guard — evidence: test/doctor check
- [ ] `just verify` passes

## Dependencies
None. Sibling of #278 (same defect class).

## Agent Assignment
`elixir-agent` or `platform-agent`.

## Progress Notes
Filed 2026-07-23 during the #116 completion audit (log-cleanliness sweep).
