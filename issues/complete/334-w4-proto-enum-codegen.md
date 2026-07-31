# Issue #334: W4 child — Proto enums as closed Elixir types, with a coverage gate

## Summary
Child of epic #314. `proto/` enums are generated as a **closed custom type for Elm** but as a bare `String.t()` for Elixir, so every Elixir consumer matches on string literals behind a mandatory catch-all — and a missed clause is invisible to the compiler, to `mix proto.sync --check`, and to the test suite. That is exactly how commit `f28c032e` added `SCRAPE_OUTCOME_RATE_LIMITED` to proto + Rust + two Elixir files, missed `trigger_price_scrape_job.ex`, and left `price_snapshots` at **zero rows for three campaigns** while every gate stayed green. Wave 0 patched that one clause; this issue makes the class a build failure.

## User Stories
None directly — a contract-layer guarantee protecting US-2.2.1 (prices) and every future enum consumer.

## Goal
Adding a value to a proto enum, or forgetting a clause in a consumer, fails the build rather than degrading silently at runtime. The event registry stops claiming a completeness it does not have.

## Scope Check
Codegen + one lint script + one consumer fix + registry truth. No product behaviour change.

## Wiring
Router wiring: n/a.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements
1. **Generate an Elixir module per proto enum.** Alongside the existing Ecto/wire generation (`scripts/gen-ecto-proto.sh`, `scripts/gen-elixir-proto.sh`), emit for each enum a module exposing at minimum `values/0` (the full list) and `cast/1` returning `{:ok, atom} | :error`. Follow the repo's codegen conventions — generated files live under `apps/core/lib/stacks/gen/` and are gitignored; `mix proto.sync --check` must stay green.
2. **Consumer-coverage check in `scripts/lint-proto.sh`.** For each hand-written consumer that matches on an enum's string values, assert its matched set ⊇ `values/0` minus an explicit, documented ignore-list. The check must **fail the build** when a value is unhandled. Design the ignore-list mechanism so a deliberate omission is a visible, reviewable declaration — not a silent gap.
3. **Fix the second drifted consumer as the proof.** `match_store_catalogue_job.ex:124` handles only `PRICED` and lets everything else fall through — the same defect class as the RATE_LIMITED miss. Fixing it should be *forced* by the new check; demonstrate that (i.e. show the check failing before the fix).
4. **Event registry truth.** `apps/core/lib/stacks/events/registry.ex` lists 22 of the ~55 emitted event types while its moduledoc claims to be "the complete catalog … surfaced by `all_event_types/0` for replay/diagnostics". Either complete it or add an explicit, documented ignore-list for audit-only events — and correct the moduledoc either way. Two clusters deserve a real decision rather than a blanket ignore: the `image.*` upload lifecycle (`submitted`/`rejected`/`resolved`/`expired` — the pipeline's own events, currently unobserved) and `listing.sold`/`removed`/`expired` (whose sibling `listing.activated` *is* wired to a handler).

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w4-314` FIRST (shared refs, no fetch). Copy `.env`; regenerate gen artifacts before compiling. `just run` for mix; `caffeinate -i` for long suites.
- ⚠️ **FIVE proto codegen targets, not two.** `mix proto.sync` and `scripts/gen-elixir-proto.sh` are *different* targets; run `bash scripts/lint-proto.sh` to check all five at once. An Ecto-only regen leaves the wire structs adrift — this has bitten the project twice.
- Field numbers are forever; additive changes only. This issue should not need to touch a `.proto` file at all — if you think it does, that is a scope surprise: stop and report.
- The Elm side already generates closed types (`proto/gen/elm/Stacks/Internal/V1/Scraper.elm:214-244`) — mirror its semantics, not its syntax.
- Commit: agent commits are DENIED. Stage everything, write a ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-334.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Contracts | yes | ❌ **the acceptance probe**: delete a match clause from a consumer → `lint-proto.sh` fails (today it passes); restore → passes |
| Codegen | yes | ❌ `mix proto.sync --check` green; all five targets checked via `lint-proto.sh` |
| Event flow | yes | ❌ registry completeness test (or documented-ignore test) + moduledoc matches reality |
| Others | no | n/a |

## Definition of Done
- [ ] Enum modules generated with `values/0` + `cast/1` — evidence: sample generated module + `proto.sync --check` green
- [ ] Coverage check in `lint-proto.sh` fails on a missing clause — evidence: probe transcript (fail → fix → pass)
- [ ] `match_store_catalogue_job.ex` fixed, and the check is what forced it — evidence: before/after check output
- [ ] Registry completed or explicitly-ignore-listed; moduledoc corrected; `image.*` and `listing.*` decisions stated — evidence: diff + rationale
- [ ] Suites green under `caffeinate`; `bash scripts/lint-proto.sh` green — evidence: counts/outputs
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #314. Level 1 — parallel with #333 (disjoint). Retires the interim clause Wave 0 added in `trigger_price_scrape_job.ex` (#311 0d) by making the class structural.

## Agent Assignment
elixir-agent (codegen-leaning).

## Progress Notes
Filed 2026-07-30 (Wave 4 kickoff approved).
Built in worktree; commit 335fc400; merged into `feat/campaign-w4-314`.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 335fc400). Praise: (a) the coverage gate **discovers consumers rather than requiring registration** — any file under `apps/core/lib` quoting an enum value is covered the day it is written, which is what makes the guarantee survive people who have never heard of it; (b) the ignore mechanism **fails closed** — probed with no reason, prose in the value slot, a stale directive, a value not in the enum, and an ignore for a handled value; a malformed excuse leaves the gap undeclared rather than silently excused; (c) it declined to register all 32 unheard event types with `[]`, on the grounds that this "makes the dispatch table lie the other way" — correct, and it produced `@unsubscribed` with per-cluster rationale instead; (d) the `image.*` and `listing.*` decisions are *reasoned from evidence* (already observed via `:telemetry` + SSE PubSub; both warehouse consumers are **views**, so there is no refresh to trigger; `listing.activated` is opt-in where its inverses are not) rather than blanket-ignored; (e) the completeness test carries a **guard-the-guard** assertion that the emit-site scan finds 50+ sites, so it cannot pass vacuously; (f) it fixed `match_store_catalogue_job.ex` but deliberately did **not** add backoff flow control, having read #308 and found that per-caller halting is the design #308 explicitly rejects — scope-lock held by reading the neighbouring decision, not by asking.
**Lead independent probe (beyond the child's):** the child probed the literal `f28c032e` defect. I probed the durability claim instead — wrote a **brand-new consumer file** (`probe_new_consumer.ex`), registered nowhere, matching on `ScrapeOutcome` and omitting `RATE_LIMITED`. Gate output: `FAIL: …/probe_new_consumer.ex matches on ScrapeOutcome but does not handle: SCRAPE_OUTCOME_RATE_LIMITED`, **exit 1**. Removed the file → **exit 0**, `git status` clean. Discovery, not registration, is real.
**Follow-up filed:** the child's `enrichment.reviews_scraped` finding → **#336**, independently confirmed by the lead (`git log -S` identifies Wave 2's `45ddcc44` as the commit that deleted the sole emitter while leaving the registry handler, the payload contract, the `DbtRefreshHandler` mapping and **both dbt models** in place — the mirror image of "built but not wired"). Also noted: the worktree bootstrap is cyclic (`mix proto.sync` lives inside `core`, which cannot compile without the schemas it generates) — worth a `just` target.
