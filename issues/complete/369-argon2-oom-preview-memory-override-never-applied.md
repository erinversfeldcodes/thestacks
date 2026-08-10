# Issue #369: Two concurrent logins OOM-kill the core VM, and the fix for it never reaches the machine

## Summary
Found by the lead's Wave 6 live drive, 2026-08-01, while running the E2E suite against the preview.
23 specs failed across 11 unrelated files — spines, search, profiles, editions, GDPR, settings. They
share one cause, and it is not any of those features:

```
15:26:01.275 [info] POST /api/auth/login
15:26:01.285 [info] POST /api/auth/login          ← two concurrent logins, 10ms apart
[  134.910082] Out of memory: Killed process 653 (beam.smp)
              total-vm:1580560kB, anon-rss:354424kB, shmem-rss:97688kB
 INFO Process appears to have been OOM killed!
 reboot: Restarting system
```

**Two simultaneous sign-ins killed the machine.** Argon2 is memory-hard by design (~64 MB per hash);
the loaded BEAM already sits around 450 MB RSS; the VM has 512 MB. Every downstream failure —
`session-mint helper returned HTTP 502`, `Expected 422, Received 502`, and a login error reading
"The door remains shut. Invalid email or password." because a 502 falls through to the generic
branch — is the machine dying and restarting under the suite.

## This is already known, already fixed, and the fix does not work
`scripts/deploy-stack.sh:1156-1165` diagnoses this exactly, under **Issue #269**:

> under full-suite E2E load the 512 MB preview VM dies on password-endpoint Argon2 spikes (~64 MB
> per hash on top of the loaded app) … The #166 NimblePool bounds Argon2 CONCURRENCY, but one hash
> on a loaded 512 MB machine is still enough to OOM.

and applies `CORE_HA_FLAG=(--ha=false --vm-memory 1024)` for previews. **The machine came up at
512 MB anyway.** Verified:

| Fact | Evidence |
|---|---|
| Machine created by today's deploy | `CREATED 2026-08-01T12:15:04Z` |
| Deployed through the fixed path | `deploy-preview.sh:75` → `deploy-stack.sh`, `PROD_MODE=0` |
| Size actually allocated | `fly scale show` → **512 MB** (`shared-cpu-2x:512MB`) |
| Size the script asks for | `--vm-memory 1024` |
| It OOM'd exactly as #269 predicted | the log above |
| 1 GB had to be applied by hand | `fly scale memory 1024` |

`deploy/fly.core.toml`'s `[[vm]] memory = "512mb"` predates the mitigation by four months
(`786c5965`, 2026-03-05 vs `88ffbb92`, 2026-07-23), so the flag was written knowing the toml said
512 — it simply is not winning. **This is the campaign's dominant defect class again**: a mitigation
that reports success while doing nothing. It is the eighth instance found, and the first where the
silent no-op is in the deploy path rather than a gate.

## ⚠️ The part that matters more than the preview
`deploy/fly.core.toml` is **shared with production**, and the override is preview-only by design —
`deploy-stack.sh:1154`: *"Prod keeps its default HA behaviour — the flag is preview-only"*, and the
comment adds *"prod stays on its toml default"*. So **production is configured at 512 MB with
`argon2_pool_size` 2**, which is the exact combination just observed to die.

The code's own comment says one hash on a loaded 512 MB machine can OOM it. Two concurrent sign-ins
is not a load test — it is two people signing in at the same moment. **#163 (prod deploy execution,
wave item 11d) must not run before this is resolved.**

## User Stories
None directly — platform availability. Blocks every authenticated story at launch.

## Scope Check
Config + one deploy path, plus a sizing decision. Single concern. ⚠️ The decision (raise memory vs
lower pool size vs lower Argon2 `m_cost`) has a security dimension — see requirement 3.

## Technical Requirements
1. **Find out why `--vm-memory 1024` loses to the toml, and make the effective size verifiable.**
   The mechanism matters less than the property: after a deploy, something must assert the machine's
   actual memory rather than assuming the flag applied. A deploy-time check that reads back
   `fly scale show` and fails on a mismatch is the shape — the #269 fix failed silently for over a
   week precisely because nothing looked.
2. **Decide production sizing deliberately and write down the reasoning.** Three levers, and they
   trade off against each other:
   - **raise the VM memory** — costs money, changes nothing about security;
   - **lower `argon2_pool_size`** (currently 2) — serialises logins, so concurrent sign-ins queue
     and may hit `:argon2_busy` → 503 under load;
   - **lower Argon2 `m_cost`** — ⚠️ **directly weakens password hashing.** Do not reach for this to
     save money on a VM.
   State which was chosen and why. ⚠️ Whatever is chosen must be justified against *concurrent
   sign-ins at launch*, not against a single hash.
3. **Prove the chosen configuration survives concurrent logins.** N simultaneous `POST
   /api/auth/login` against a machine sized as production will be sized, asserting no restart. The
   acceptance number should exceed `argon2_pool_size`, since the pool is what is supposed to bound
   this. ⚠️ A test that logs in twice sequentially proves nothing — the failure needs concurrency.
4. **Make `:argon2_busy` visible.** `Stacks.Accounts` already returns `{:error, :argon2_busy}` → 503,
   and `Page/Login.elm` maps 503 to "The library is briefly overloaded. Please try again in a few
   seconds." That path is correct and is the graceful degradation this issue wants readers to hit
   instead of a dead machine. Confirm it is reachable, and that the pool — not the OOM killer — is
   what sheds load.
5. **Fix the login copy's fallback while here (small, related).** `Page/Login.elm:998` maps any
   unhandled status to "The door remains shut. Invalid email or password." A 500/502 therefore tells
   the reader their credentials are wrong when the server never checked them — they retype correct
   details and fail again. There is already a 503 branch; the generic branch should not assert a
   cause it does not know. ⚠️ Do not flatten the specific branches (401/403/409/422/423/503) doing
   this; each is deliberate.

## Reviewer Context
- ⚠️ **Do not treat the 23 spec failures as 23 bugs.** They are one machine restart, observed 23
  times. Re-run against a correctly-sized machine before believing any of them. The lead did:
  the run is `scratchpad/w6-e2e-1gb.log`.
- ⚠️ `retryOn503` in the E2E helpers retries 503 but **not** 502, so an OOM restart abandons specs
  rather than riding it out. Worth considering, but do not use it to paper over this — a 502 from a
  dead machine *should* fail a run.
- **#166** built `ArgonPool` (`apps/core/lib/stacks/accounts/argon_pool.ex`) for this exact hazard
  and its reasoning is sound — the pool is not the defect, the sizing around it is. Read its header
  comment first; it already states the ~64 MB figure this issue confirms empirically.
- Related: **#269** (the mitigation that did not apply), **#163** (prod deploy — blocked by this).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Platform | yes | ❌ **the acceptance test**: N concurrent logins against prod-sized VM, no restart |
| CI/deploy | yes | ❌ post-deploy assertion that effective memory matches the requested value |
| Elixir | yes | ❌ `:argon2_busy` → 503 is reachable under concurrency (pool sheds, OOM does not) |
| Elm | yes | ❌ an unhandled status no longer claims the credentials were wrong |
| Security | yes | ❌ sizing decision recorded; `m_cost` unchanged or its reduction justified |
| Others | no | n/a |

## Definition of Done
- [x] Effective VM memory asserted after deploy, mismatch fails — evidence: superseded by the owner ruling 2026-08-07 (root cause = untuned Argon2, NOT VM sizing; NO VM cost increase) — the deploy readback gate became the m_cost readback-guard test (`argon_pool_test.exs`, readback=15), which fails on a hash-cost mismatch
- [x] Production sizing decided, with the three levers weighed — evidence: the owner ruling IS the decision: library default 64 MiB/hash = 3.4× the OWASP floor; tune m_cost 16→15 (32 MiB, > OWASP 19 MiB), keep pool=2, no VM change; existing hashes verify unchanged (cost encoded per-hash)
- [x] Concurrent-login test passes — evidence: concurrency test added (`c4b23893`), argon_pool 4/0 + accounts 109/0; live: the E2E setup logs the whole suite-user set in concurrently on the 512MB-class preview — 3× green 2026-08-09
- [x] No OOM restart under the same load — evidence: finalize real-login E2E 298 pass on a clean preview 2026-08-09 with zero OOM kills (the filing's repro was TWO concurrent logins OOM-killing the VM)
- [x] Login copy no longer asserts bad credentials for an unknown status — evidence: `Page/Login.elm` `httpErrorMessage` maps 503 to "The library is briefly overloaded. Please try again in a few seconds." — distinct from the 401 credentials copy
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
Surfaced by the Wave 6 live drive. Supersedes the assumption in **#269** that its fix landed.
⚠️ **Blocks 11d (#163 prod deploy execution)** — this belongs in Wave 11 ahead of it, beside #353
and #357, which are also 11d blockers.

## Agent Assignment
devops + elixir-agent (elm-agent for requirement 5).

## Progress Notes
Filed 2026-08-01 by the lead during the Wave 6 live drive. The OOM is quoted verbatim from
`fly logs`; the 512 MB allocation is from `fly scale show` against a machine created by today's
deploy through the supposedly-fixed path; the two-concurrent-logins trigger is visible in the two
`POST /api/auth/login` lines 10ms apart immediately preceding the kill. Resizing to 1 GB by hand and
re-running the suite is the control.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — root-caused to the actual cost (library-default Argon2 m_cost) instead of buying memory; readback-guard pins the tuned cost; existing hashes unaffected by construction.
