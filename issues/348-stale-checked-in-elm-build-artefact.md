# Issue #348: `frontend/index.html` is a stale, tracked Elm build artefact

## Summary
Found by #343. `frontend/index.html` is **39,680 lines of checked-in Elm build output**, tracked in git, and already stale: it still contains the `lookupByIsbn` function that #343 deleted from the source. It is the only remaining grep hit for that symbol in the repo.

It is **not served** — the app loads `app.js` produced by esbuild (`apps/core/priv/static/assets/` is build output; `frontend/css/main.css` is the only CSS source). So this is dead output under version control.

## Why it is worth an issue rather than a quiet delete
A stale build artefact that contains deleted code poisons every future `grep`. This campaign has repeatedly used repo-wide greps as evidence — "the DIY flow is gone: 0 matches", "no module under `lib/` matches `Mock*`" — and a 39k-line stale copy of the frontend is exactly the thing that turns a clean grep into a false positive or a false alarm. It also inflates every diff that touches it and every secret-scanner run.

## User Stories
None — repository hygiene.

## Goal
Build output is not tracked. A grep over the repo reflects the code that exists.

## Scope Check
One file plus a `.gitignore` entry. Trivial — but verify before deleting (see requirements).

## Wiring
Router wiring: none.

## Feature-Completeness Pre-Check
n/a.

## Technical Requirements
1. **Verify it is genuinely unserved before deleting.** Confirm nothing references `frontend/index.html` — the Phoenix static pipeline, `esbuild` config, any script in `scripts/`, the Dockerfiles, or a deploy step. The memory note says the browser loads `app.js` from esbuild and that `apps/core/assets/index.html` is the served template, but **verify rather than trust it**: a deploy that 404s its own index page is a bad way to find out.
2. **Delete it and add the path to `.gitignore`** if unserved. If some path *does* consume it, then it is generated output being consumed as a source — say so, and the fix is to generate it at build time instead.
3. **Check for siblings.** Look for other tracked build output under `frontend/` and `apps/core/priv/static/` and report what you find. `git ls-files` is the authority here, not the filesystem — this project has been bitten before by assuming a generated file's tracked status (see the "verify gitignore claims" convention).
4. **Re-run the campaign's grep-based claims** afterwards if the file went away, so their counts stay true.

## Reviewer Context
- ⚠️ **Verify tracked-vs-ignored with `git ls-files`**, not by looking at `.gitignore` — agents get this wrong and it fails silently. (`frontend/index.html` was confirmed tracked this way.)
- Deleting checked-in output can break a build that quietly depended on it; run `bash scripts/build-assets.sh` (or the project's equivalent) and a preview deploy before declaring done.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Build | yes | ❌ asset build green after removal; the app still serves its index |
| Deploy | yes | ❌ a preview deploy serves the SPA — the real check |
| Repo hygiene | yes | ❌ `git ls-files` shows no tracked build output under the surveyed paths |
| Others | no | n/a |

## Definition of Done
- [ ] Confirmed unserved, with the evidence that proves it — evidence: the greps/config checked
- [ ] Deleted and gitignored (or the consuming path named and fixed) — evidence: diff
- [ ] Sibling tracked-build-output survey reported — evidence: `git ls-files` output
- [ ] Preview deploy serves the SPA — evidence: deploy log + a loaded page
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#343**. Independent; needs an owner wave assignment. Fits naturally beside the Wave 2 deletion work in spirit.

## Agent Assignment
elm-agent / devops.

## Progress Notes
Filed 2026-07-31 by the lead from #343's finding 4. Independently confirmed: `git ls-files --error-unmatch frontend/index.html` succeeds (tracked), `wc -l` → 39,680, and `grep -c lookupByIsbn` → 2 after the symbol was deleted from all source.
