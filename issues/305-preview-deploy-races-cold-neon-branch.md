# Issue #305: Preview deploy races a suspended, freshly-created Neon branch

## Summary
`deploy-stack.sh` creates the preview Neon branch and then immediately runs the release command
(migrations) against it. A newly created branch starts **suspended**, so the migration races its cold
start and can die on a pool timeout, aborting the whole deploy. Warm the branch before the release
command.

## User Stories
None — deploy reliability. It blocks every story that needs a preview to be driven.

## Goal
A preview deploy does not fail because its database was still waking up.

## Scope Check
- >3 controllers? None — one shell script.
- >2 endpoints? None.
- >300 LOC? No; a warm-up step and a retry.
- Unrelated concerns? No.

## Wiring
Router wiring: implementation-only — deploy tooling.

## Technical Requirements

**Observed 2026-07-29**, deploy of `feat/staff-engineer`:

```
[error] Could not create schema migrations table. …
** (DBConnection.ConnectionError) [Elixir.Core.Repo] connection not available and request was
   dropped from queue after 5974ms
Error: release command failed - aborting deployment.
FAIL deploy: core failed twice; aborting
```

The script's own retry hit the same cold compute and gave up. Immediately afterwards, a single
trivial query against the branch (via the Neon API) returned in under a second, and the **next
deploy passed every gate first time** — including migrations. So the failure correlates with the
compute being cold, not with the migrations themselves.

**Fix:** after `Neon branch created`, issue one cheap query (e.g. `SELECT 1`) against the new branch
and wait for it to answer before `fly deploy` runs the release command. Add a bounded retry so a
slow wake-up delays rather than fails the deploy.

⚠️ **This is a strong candidate root for the #171/#177 preview-deploy flakes** already recorded in
`plans/staff-campaign-2026-07-27.md`, which were attributed to `fly … exec … EOF`. Check them against
this before closing either — if it is the same cause, say so and close them together rather than
leaving two folklore explanations for one bug.

## ⚠️ Redeploying onto a live stack is the unreliable path — tear down first

Owner observation 2026-07-29, and the session's own record backs it exactly. Every clean deploy
followed a **full teardown**; every failure was an incremental redeploy onto a running stack:

| Deploy | Teardown first? | Outcome |
|---|---|---|
| 10 | **yes** | passed every gate first time |
| 15 | **yes** | (this issue's verification) |
| 6 | no | died mid image-push |
| 7 | no | release command raced a cold Neon branch → aborted |
| 13 | no | **half-succeeded** — see below |

**deploy13 is the case that matters, because it looked healthy.** It created the Neon branch, deployed
the app, and served `GET /api/admin/sources` → **200 with zero rows**. It never ran migrations or the
seed. It worked *because* a preview branch is copy-on-write from `staging`: the schema and 18 staging
users were already there, so a stack missing every fixture answered requests perfectly.

⛔ **That is worse than a failed deploy.** A failure is obvious; this one invites you to debug the
application. It cost a false lead — "0 Approve buttons" read as a broken status fix, when the real
cause was an unseeded database. What caught it was treating a zero row count as a finding to explain
(check the deploy log for the seed line, then query the branch) rather than as an absence.

So the **DoD below is insufficient as written**: "passes migrations first attempt" does not capture a
deploy that skips migrations entirely and still serves 200s. Add an assertion that the *fixtures*
exist, not merely that the health check passed.

**Recommended fix, in order of value:**
1. `scripts/deploy-preview.sh` should **tear down first by default** (or refuse to proceed against an
   existing stack without an explicit `--reuse`). The canonical path should be the reliable one.
2. Warm the new branch before the release command (the original subject of this issue).
3. **Fail loudly on a partial deploy**: if migrations or the seed did not run, exit non-zero. A
   preview that serves 200s with no fixtures must not report success.

## Reviewer Context
- The preview Neon branch is **deleted and recreated from `staging` on every deploy**
  (`Deleting stale branch preview/<branch>…`), so it is cold on *every* deploy, not just the first.
  Anything seeded into a preview survives exactly one deploy.
- Teardown order is load-bearing (#170 D): machines stop **before** the Neon branch is deleted, so
  the Postgrex pool drains instead of spraying "endpoint could not be found". Do not reorder.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Deploy tooling | yes | ❌ nothing exercises the cold-branch path |
| 1–13 (app/US layers) | no | n/a — no application behaviour changes |

Punch list:
1. The honest test is a real deploy against a freshly created branch — assert the release command
   succeeds on the first attempt. A unit test of a shell script would prove nothing here.
2. Log the wake-up wait when it happens, so a slow branch is visible rather than silent.

Verdict: ❌ — deploy-path timing has no coverage; item 1 is the exit criterion.

## Definition of Done
- [ ] The branch is warmed before the release command — evidence: the committed diff
- [ ] A deploy against a fresh branch passes migrations first attempt — evidence: captured deploy log
- [ ] A partial deploy (branch created, migrations/seed skipped) **exits non-zero** rather than
      serving 200s with no fixtures — evidence: named check + a deliberately-interrupted deploy shown
      failing it
- [ ] The canonical script tears down first by default, or refuses an existing stack without an
      explicit opt-in — evidence: the committed diff + a captured run
- [ ] The wake-up wait is logged when non-trivial — evidence: log excerpt
- [ ] #171/#177 checked against this cause and either closed or distinguished — evidence: the note
      recorded on those issues
- [ ] `just verify` passes — evidence: command → captured output

## Progress Notes
- 2026-07-29: Hit during Wave 0 execution. Worked around by warming the branch by hand and
  redeploying; a full teardown + clean deploy then passed every gate. Filing rather than fixing
  in-flight, since it is deploy tooling and not in Wave 0's scope.
